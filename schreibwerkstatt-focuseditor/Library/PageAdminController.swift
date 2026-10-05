//
//  PageAdminController.swift
//  schreibwerkstatt-focuseditor
//
//  Seiten anlegen, umbenennen, löschen — die drei Schritte, für die man bisher
//  in die Web-App wechseln musste.
//
//  Warum das nicht über den Sync läuft: der Push kennt nur `PUT
//  /content/pages/:id` und der ist UPDATE-ONLY (404, wenn die Seite nicht
//  existiert). Eine neue Seite entsteht ausschliesslich über `POST
//  /content/pages` — und damit ONLINE. Das ist eine bewusste Grenze und keine
//  Bequemlichkeit: eine offline angelegte Seite hätte keine echte ID, müsste
//  mit einer Platzhalter-ID durch Outbox, Recents, `lastOpenPage` und den
//  Editor-Glue wandern und beim ersten Sync überall umgeschrieben werden. Diese
//  ID-Umschreibung ist genau die Sorte Zustand, in der Datenverlust entsteht.
//  Also: neue Seiten brauchen Netz, SCHREIBEN nie.
//
//  Nach jedem Server-Erfolg wird der lokale Spiegel sofort nachgezogen
//  (`applyServerPage` / `deletePage`), damit Picker und Editor nicht bis zum
//  nächsten Poll-Tick hinterherhinken.
//
//  Umbenennen ist ein `PUT` mit `{ name }` OHNE `expected_updated_at`: der
//  Server behandelt reine Renames getrennt vom Body (der letzte Text-Autor
//  bleibt stehen), und ein Concurrency-Guard auf einen Namen wäre eine
//  Konfliktquelle ohne Nutzen. Die Antwort trägt das neue `updated_at` — es
//  wird als Push-Basis übernommen (`onServerBase` → `SyncEngine.adoptServerBase`,
//  dort die ISO-Basis, die der Push als `expected_updated_at` schickt), sonst
//  liefe der nächste Body-Push in einen 409.
//

import Foundation
import Combine
import os

@MainActor
final class PageAdminController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case working
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let api: APIClient
    private let store: any LocalStore
    private let library: LibraryStore
    /// Übernimmt eine vom Server gemeldete Basis (`pageId`, exakte ISO,
    /// Server-HTML falls geliefert) in den Sync-Zustand. Die Epoch-Basis im Store
    /// allein genügt nicht: der Push schickt die ISO aus dem Sync-Zustand.
    private let onServerBase: (String, String, String?) async -> Void
    private let log = AppLog.pageAdmin

    init(api: APIClient, store: any LocalStore, library: LibraryStore,
         onServerBase: @escaping (String, String, String?) async -> Void) {
        self.api = api
        self.store = store
        self.library = library
        self.onServerBase = onServerBase
    }

    func dismissError() { phase = .idle }

    // MARK: - Anlegen

    /// Legt im aktiven Buch eine Seite an und öffnet sie. `chapterId` hängt sie
    /// in ein Kapitel; ohne landet sie auf Buchebene.
    ///
    /// Der Server hängt sie ans Ende des Buchs (`position = MAX + 1`) — dieselbe
    /// Stelle wie in der Web-App, kein eigenes Sortier-Modell im Client.
    func createPage(named name: String, chapterId: Int? = nil) async {
        guard let bookId = library.activeBookId else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        phase = .working
        do {
            let created = try await api.send("/content/pages",
                                             method: .POST,
                                             body: CreatePageBody(book_id: bookId,
                                                                  chapter_id: chapterId,
                                                                  name: trimmed),
                                             decode: PushResponse.self)
            // Sofort in den Spiegel — mit Server-Basis, damit der erste Save der
            // neuen Seite regulär pusht statt in „ohne Basis, nicht pushbar" zu
            // laufen.
            let createdAt = ISOTime.millis(created.updated_at) ?? Date().timeIntervalSince1970 * 1000
            try await store.applyServerPage(id: String(created.id),
                                            html: created.html ?? "<p><br></p>",
                                            pageName: created.name ?? trimmed,
                                            bookId: created.book_id ?? bookId,
                                            chapterId: created.chapter_id ?? chapterId,
                                            serverUpdatedAtMillis: createdAt)
            await onServerBase(String(created.id), created.updated_at, created.html ?? "<p><br></p>")
            phase = .idle
            await library.refreshPages()
            // Erst nach dem Refresh öffnen: `openPage` erwartet die Zeile in der
            // aktuellen Seitenliste (Titel + Kapitelname der Toolbar hängen dran).
            if let row = library.pages.first(where: { $0.id == created.id }) {
                library.openPage(row)
            }
            log.info("Seite angelegt: \(created.id, privacy: .public)")
        } catch {
            phase = .failed(Self.message(for: error, fallbackKey: "pageadmin.error.create"))
            log.error("Seite anlegen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Umbenennen

    func renamePage(id: Int, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        phase = .working
        do {
            let updated = try await api.send("/content/pages/\(id)",
                                             method: .PUT,
                                             body: RenamePageBody(name: trimmed),
                                             decode: PushResponse.self)
            // Der Rename hat `updated_at` bewegt → die lokale Basis mitziehen,
            // sonst kollidiert der nächste Body-Push (409) an einer Änderung,
            // die der Nutzer selbst ausgelöst hat.
            if let existing = try await store.page(id: String(id)),
               let renamedAt = ISOTime.millis(updated.updated_at) {
                try await store.applyServerPage(id: String(id),
                                                html: existing.html,
                                                pageName: trimmed,
                                                bookId: existing.bookId,
                                                chapterId: existing.chapterId,
                                                serverUpdatedAtMillis: renamedAt)
            }
            await onServerBase(String(id), updated.updated_at, updated.html)
            phase = .idle
            await library.refreshPages()
            log.info("Seite umbenannt: \(id, privacy: .public)")
        } catch {
            phase = .failed(Self.message(for: error, fallbackKey: "pageadmin.error.rename"))
            log.error("Umbenennen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Löschen

    /// Löscht die Seite am Server (Papierkorb) und danach lokal. Reihenfolge
    /// zählt: schlägt der Server fehl, bleibt der lokale Stand unangetastet —
    /// „Datenverlust-Schutz vor allem". Umgekehrt wäre der Text weg, während
    /// die Seite serverseitig weiterlebt.
    func deletePage(id: Int) async {
        phase = .working
        do {
            try await api.sendVoid("/content/pages/\(id)", method: .DELETE)
            // Späte Saves (Close-Handler des Editors) verwerfen, BEVOR lokal
            // gelöscht wird — sonst entstünde die Seite danach neu.
            library.forgetDeletedPage(id: id)
            try await store.deletePage(id: String(id))
            phase = .idle
            await library.refreshPages()
            log.info("Seite gelöscht: \(id, privacy: .public)")
        } catch {
            phase = .failed(Self.message(for: error, fallbackKey: "pageadmin.error.delete"))
            log.error("Löschen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Fehlertexte

    /// Server-Fehlercodes auf verständliche Sätze abbilden. Alles Unbekannte
    /// bekommt den generischen Text der Aktion — eine rohe Statuszeile hilft
    /// dem Schreibenden nicht.
    static func message(for error: Error, fallbackKey: String) -> String {
        if case AuthError.server(let status, _, _) = error {
            switch status {
            case 403: return t("pageadmin.error.forbidden")
            case 404: return t("pageadmin.error.notFound")
            case 423: return t("pageadmin.error.locked")
            default: break
            }
        }
        if case AuthError.unauthorized = error { return t("pageadmin.error.forbidden") }
        return t(fallbackKey)
    }
}

// MARK: - Request-Bodies

private struct CreatePageBody: Encodable {
    let book_id: Int
    let chapter_id: Int?
    let name: String
}

private struct RenamePageBody: Encodable {
    let name: String
}
