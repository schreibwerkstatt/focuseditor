//
//  BookExportController.swift
//  schreibwerkstatt-focuseditor
//
//  Ablage ▸ „Buch exportieren …": schreibt das aktive Buch als EINE
//  Markdown-Datei via Server-Endpunkt (`GET /export/book/:id/md`).
//
//  Warum Server-Export: dieselben Export-Builder wie die Web-App (Kapitel-
//  struktur, Fussnoten, Bibliografie) statt eines zweiten Konverters im Client.
//  Preis: online-only, und der Server kennt nur, was gepusht ist. Darum läuft
//  vorher `prepare` (Draft flushen + Sync-Durchlauf, ⌘S-Semantik wie beim
//  Lektorat), und was danach NOCH in der Outbox liegt (409-Konflikt,
//  Lektorats-Lock), weist das Banner aus — ein Export mit stillen Lücken sähe
//  aus wie ein vollständiges Backup.
//
//  Sandbox: `NSSavePanel` erteilt dem Prozess das Schreibrecht für genau die
//  gewählte Datei (`files.user-selected` steht in beiden Entitlement-Wegen —
//  DMG-Datei wie MAS-Synthese). Es wird nirgendwo sonst hin geschrieben.
//

import AppKit
import Combine
import os
import UniformTypeIdentifiers

@MainActor
final class BookExportController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case exporting
        /// Fertig — Datei geschrieben; `unsynced` = Seiten des Buchs, deren
        /// lokaler Stand den Server (noch) nicht erreicht hat.
        case done(url: URL, unsynced: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let api: APIClient
    private let store: any LocalStore
    private let library: LibraryStore
    /// Vorlauf vor dem Server-Export: offenen Draft sichern + pushen.
    private let prepare: () async -> Void
    private let log = AppLog.export

    init(api: APIClient, store: any LocalStore, library: LibraryStore,
         prepare: @escaping () async -> Void) {
        self.api = api
        self.store = store
        self.library = library
        self.prepare = prepare
    }

    /// Kann exportiert werden? (aktives Buch mit mindestens einer Seite)
    var canExport: Bool {
        library.activeBookId != nil && !library.pages.isEmpty && phase != .exporting
    }

    /// Exportiert das aktive Buch via Server. Reihenfolge zählt: erst sichern +
    /// pushen (sonst fehlt der eben getippte Satz), dann holen, erst DANN nach
    /// dem Ziel fragen — offline soll niemand erst eine Datei wählen und
    /// hinterher den Fehler sehen.
    func exportActiveBook() {
        guard phase != .exporting, let bookId = library.activeBookId else { return }
        let title = library.activeBookName ?? t("library.bookFallback", ["id": "\(bookId)"])
        let pageIds = Set(library.pages.map { String($0.id) })
        phase = .exporting

        Task {
            await prepare()

            let data: Data
            do {
                data = try await api.getRaw("/export/book/\(bookId)/md").data
            } catch {
                phase = .failed(Self.message(for: error))
                log.error("Export fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                return
            }

            // Was nach dem Sync noch wartet, steht im Export im alten Stand.
            let pending = (try? await store.pendingOutbox()) ?? []
            let unsynced = Set(pending.map(\.pageId)).intersection(pageIds).count

            guard let url = await Self.askForDestination(suggested: suggestedFilename(bookTitle: title)) else {
                phase = .idle   // abgebrochen — kein Fehler
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                phase = .done(url: url, unsynced: unsynced)
                log.info("Buch exportiert via Server: \(data.count, privacy: .public) Bytes, \(unsynced, privacy: .public) Seiten ungesynct")
            } catch {
                phase = .failed(t("export.error.write"))
                log.error("Export-Datei nicht geschrieben: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Server-/Netzfehler auf verständliche Sätze abbilden — eine rohe
    /// Statuszeile („400 BOOK_EMPTY") hilft dem Schreibenden nicht.
    static func message(for error: Error) -> String {
        switch error {
        case AuthError.network:
            return t("export.error.offline")
        case AuthError.unauthorized, AuthError.server(status: 403, _, _):
            return t("export.error.forbidden")
        case AuthError.server(status: 400, code: "BOOK_EMPTY", _):
            return t("export.error.empty")
        case AuthError.server(status: 404, _, _):
            return t("export.error.notFound")
        default:
            return t("export.error.generic")
        }
    }

    /// Dateiname-Vorschlag: Buchtitel, entschärft für das Dateisystem.
    private func suggestedFilename(bookTitle: String) -> String {
        var name = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\n", "\r", "\t"] {
            name = name.replacingOccurrences(of: bad, with: "-")
        }
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Export" : name
    }

    /// Zeigt das Speichern-Panel. `nil` = abgebrochen.
    private static func askForDestination(suggested: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggested + ".md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = t("export.panelTitle")
            panel.prompt = t("export.panelPrompt")
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    /// Ergebnis wegklicken (Banner-Schliessen).
    func dismiss() { phase = .idle }

    /// Exportierte Datei im Finder zeigen.
    func revealInFinder() {
        guard case .done(let url, _) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
