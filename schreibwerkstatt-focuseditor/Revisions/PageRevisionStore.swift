//
//  PageRevisionStore.swift
//  schreibwerkstatt-focuseditor
//
//  Frühere Fassungen der offenen Seite: Liste, Vorschau, Wiederherstellen
//  (`GET /content/pages/:id/revisions[/:rev]`, `POST …/:rev/restore`).
//
//  Warum das in diesen Client gehört, obwohl „nur der Schreibmodus": es ist der
//  Notausgang aus dem einen Datenverlust-Pfad, den die App nicht selbst
//  beherrscht. WebKits Undo-Stack fasst alles seit dem letzten Mausklick zu
//  EINEM Schritt zusammen (gemessen, s. CLAUDE.md) — ein versehentliches ⌘Z
//  nimmt unter Umständen einen ganzen Abschnitt weg, ⌘⇧Z holt ihn nur zurück,
//  solange nichts Neues getippt wurde, und der Autosave persistiert die Lücke
//  derweil still. Der `HistoryNoticeBanner` warnt davor; ohne die Revisionen
//  endete der Hinweis aber bei „öffne die Web-App".
//
//  Jeder erfolgreiche Save legt serverseitig eine Revision an (`page_revisions`,
//  Schreib-Hook in der content-store-Facade) — der Client legt keine an und
//  löscht keine; er liest und stellt wieder her.
//
//  ONLINE-ONLY, und das ist ehrlich so: die Revisionen liegen am Server, der
//  lokale Spiegel führt nur den aktuellen Stand. Offline zeigt die Ansicht
//  einen Hinweis statt einer leeren Liste.
//
//  Kein Bridge-Op — direkter Swift→Server-Call wie Lektorat und Schreibzeit.
//  Das Wiederherstellen geht über den Server (der schreibt die alte Fassung als
//  neue Revision zurück); der Client zieht danach den frischen Stand und lässt
//  die WebView neu laden.
//

import Foundation
import Combine
import os

// MARK: - Modelle

/// Eine Revision, wie die Liste sie liefert (ohne Body).
struct PageRevision: Identifiable, Decodable, Equatable {
    let id: Int
    let page_id: Int
    let chars: Int?
    let words: Int?
    /// Woher die Fassung stammt (`main`, `lektorat`, …) — nur zur Einordnung.
    let source: String?
    let user_email: String?
    /// Gerät/Client, das gespeichert hat (Server-Label).
    let client: String?
    let created_at: String?
    let summary: String?

    var createdAt: Date? {
        guard let created_at else { return nil }
        return ISOTime.date(created_at)
    }
}

private struct RevisionListResponse: Decodable {
    let revisions: [PageRevision]
}

private struct RevisionDetail: Decodable {
    let id: Int
    let body_html: String?
}

private struct RevisionDetailResponse: Decodable {
    let revision: RevisionDetail
}

// MARK: - Store

@MainActor
final class PageRevisionStore: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var revisions: [PageRevision] = []
    /// Seite, zu der die geladene Liste gehört — verhindert, dass eine spät
    /// eintreffende Antwort die Liste einer inzwischen anderen Seite überschreibt.
    @Published private(set) var pageId: Int?
    /// Vorschautext der ausgewählten Revision (Klartext, keine Formatierung).
    @Published private(set) var previewText: String?
    @Published private(set) var previewRevisionId: Int?
    @Published private(set) var isRestoring = false

    private let api: APIClient
    /// Vorlauf vor dem Wiederherstellen: offenen Draft sichern + pushen (in
    /// `AppCore` auf `bridge.flushDraftSave()` + `sync.syncNow(manual:)`
    /// verdrahtet). Damit liegt der Stand, den die Wiederherstellung ersetzt,
    /// selbst als Revision am Server — und keine ungepushte lokale Änderung
    /// kann die Wiederherstellung danach per Merge wieder zurückdrehen.
    private let prepare: () async -> Void
    private let log = AppLog.revisions

    init(api: APIClient, prepare: @escaping () async -> Void = {}) {
        self.api = api
        self.prepare = prepare
    }

    // MARK: - Liste

    func load(pageId: Int) async {
        self.pageId = pageId
        previewText = nil
        previewRevisionId = nil
        phase = .loading
        do {
            let response = try await api.send("/content/pages/\(pageId)/revisions?limit=100",
                                              decode: RevisionListResponse.self)
            // Antwort einer inzwischen geschlossenen/gewechselten Seite verwerfen.
            guard self.pageId == pageId else { return }
            revisions = response.revisions
            phase = .loaded
        } catch {
            guard self.pageId == pageId else { return }
            revisions = []
            phase = .failed(Self.message(for: error))
            log.error("Revisionen laden fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Vorschau

    /// Holt den Body einer Revision und zeigt ihn als Klartext. Bewusst kein
    /// gerendertes HTML: die Vorschau soll beim Wiedererkennen helfen („war das
    /// der Absatz?"), nicht ein zweiter Editor sein.
    func loadPreview(revisionId: Int) async {
        guard let pageId else { return }
        previewRevisionId = revisionId
        previewText = nil
        do {
            let response = try await api.send("/content/pages/\(pageId)/revisions/\(revisionId)",
                                              decode: RevisionDetailResponse.self)
            guard previewRevisionId == revisionId else { return }   // inzwischen weitergeklickt
            let html = response.revision.body_html ?? ""
            // Klartext wie der Volltext-Index ihn baut — Leerraum-Läufe
            // kollabieren, damit die Vorschau lesbar bleibt.
            previewText = PageText.plain(html: html, pageName: nil)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard previewRevisionId == revisionId else { return }
            previewText = t("revisions.previewFailed")
            log.error("Revisions-Vorschau fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Wiederherstellen

    /// Stellt die Revision serverseitig wieder her. Liefert `true` bei Erfolg —
    /// der Aufrufer zieht danach den frischen Stand (Sync) und lädt die offene
    /// Seite neu.
    ///
    /// Der Server schreibt die alte Fassung als NEUE Revision zurück; nichts
    /// geht dabei verloren, auch der überschriebene Stand bleibt als Revision
    /// erhalten. Wiederherstellen ist damit selbst widerrufbar.
    func restore(revisionId: Int) async -> Bool {
        guard let pageId, !isRestoring else { return false }
        isRestoring = true
        defer { isRestoring = false }
        await prepare()
        do {
            try await api.sendVoid("/content/pages/\(pageId)/revisions/\(revisionId)/restore",
                                   method: .POST)
            log.info("Revision \(revisionId, privacy: .public) für Seite \(pageId, privacy: .public) wiederhergestellt")
            return true
        } catch {
            phase = .failed(Self.message(for: error))
            log.error("Wiederherstellen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Beim Schliessen des Sheets — die nächste Öffnung soll frisch laden.
    func reset() {
        phase = .idle
        revisions = []
        pageId = nil
        previewText = nil
        previewRevisionId = nil
    }

    // MARK: - Fehlertexte

    static func message(for error: Error) -> String {
        if case AuthError.server(let status, _, _) = error {
            switch status {
            case 403: return t("revisions.error.forbidden")
            case 404: return t("revisions.error.notFound")
            case 423: return t("pageadmin.error.locked")
            default: break
            }
        }
        if case AuthError.network = error { return t("revisions.error.offline") }
        if case AuthError.unauthorized = error { return t("revisions.error.forbidden") }
        return t("revisions.error.generic")
    }
}
