//
//  LocalStore.swift
//  schreibwerkstatt-focuseditor
//
//  Lokaler Spiegel der Seiten — das Fundament des Offline-Kerns.
//  Jeder Save geht ZUERST hierher (local-first), erst danach in die Outbox
//  und bei Konnektivität an den Server (siehe Sync/, noch nicht implementiert).
//
//  HINWEIS: Dies ist ein Platzhalter VOR GRDB. Persistenz läuft vorerst über
//  einen JSON-Snapshot im Application-Support-Verzeichnis. Das `LocalStore`-
//  Protokoll ist die Kopplungsschicht — die GRDB/SQLite-Implementierung (laut
//  CLAUDE.md) ersetzt später `InMemoryLocalStore`, ohne dass Bridge oder Shell
//  angefasst werden müssen.
//

import Foundation
import OSLog

/// Eine Seite im lokalen Spiegel. `updatedAt` ist ein Epoch-Millis-Zeitstempel
/// (Double) — passt 1:1 zu `Date.now()` in der WebView und zur Sync-Basis.
nonisolated struct StoredPage: Codable, Equatable, Identifiable {
    var id: String
    var html: String
    /// Aus dem HTML abgeleiteter Anzeige-Fallback (erste Textzeile).
    var title: String?
    /// Server-seitiger Seitenname (autoritativ für die Anzeige im Picker).
    var pageName: String?
    /// Zugehöriges Buch — steuert Filterung im Picker und den buch-skopierten Pull.
    var bookId: Int?
    /// Zugehöriges Kapitel (für Gruppierung im Picker). Optional.
    var chapterId: Int?
    /// Letzte lokale Änderung (Epoch ms).
    var updatedAt: Double
    /// Server-Basis für den nächsten Push (`expected_updated_at`). `nil`, solange
    /// die Seite noch nie synchronisiert wurde. Wird beim Pull/erfolgreichen Push
    /// auf den Server-Stand gesetzt.
    var baseUpdatedAt: Double?
}

/// Eintrag der Schreib-Queue. Jeder lokale Save erzeugt (oder aktualisiert) einen
/// Outbox-Eintrag; die SyncEngine arbeitet ihn bei Konnektivität ab.
nonisolated struct OutboxEntry: Codable, Equatable {
    var pageId: String
    var html: String
    /// Server-Basis, gegen die gepusht wird (`expected_updated_at`).
    var baseUpdatedAt: Double?
    /// Wann der Eintrag lokal angelegt wurde (Epoch ms).
    var queuedAt: Double
}

/// Kopplungsschicht zum lokalen Speicher. Bridge und Shell sprechen nur dieses
/// Protokoll — die konkrete Engine (vorerst In-Memory/JSON, später GRDB) ist
/// austauschbar.
@MainActor
protocol LocalStore: AnyObject {
    /// Liefert eine Seite, oder `nil` wenn unbekannt.
    func page(id: String) async throws -> StoredPage?
    /// Seitenliste (ohne HTML-Body — schlanke Übersicht). `bookId == nil`
    /// liefert alle Seiten, sonst nur die des gewählten Buchs (Picker-Filter).
    func list(bookId: Int?) async throws -> [PageSummary]
    /// Volltextsuche über den lokal gespiegelten Seiten-INHALT (nicht nur den
    /// Namen) — speist die Inhaltstreffer des Pickers. Liefert die IDs passender
    /// Seiten nach Relevanz; `bookId` skopiert auf ein Buch. Nur lokal vorhandener
    /// Inhalt ist durchsuchbar (offline-first) — Seiten, deren Body noch nie
    /// gepullt wurde, sind (noch) nicht auffindbar. Leere/triviale Query → `[]`.
    func searchContent(query: String, bookId: Int?) async throws -> [String]
    /// Zählwerte (Zeichen/Wörter) der gespiegelten Seiten, `bookId` skopiert auf
    /// ein Buch. Schlüssel ist die Seiten-ID; enthalten sind NUR Seiten, deren
    /// Inhalt lokal vorliegt — eine nie gepullte Seite fehlt bewusst (der Picker
    /// zeigt dafür „—" statt einer erfundenen 0). Gerechnet wird beim Schreiben
    /// (s. `PageMetrics`), nicht beim Lesen: der Picker fragt das für ALLE Seiten
    /// des Buchs auf einmal ab.
    func pageStats(bookId: Int?) async throws -> [String: PageStats]

    /// Schreibt eine Seite lokal UND legt einen Outbox-Eintrag an (local-first).
    /// Liefert die gespeicherte Seite mit neuem `updatedAt` zurück.
    func save(id: String, html: String, baseUpdatedAt: Double?) async throws -> StoredPage
    /// Noch nicht gepushte Outbox-Einträge (für die spätere SyncEngine).
    func pendingOutbox() async throws -> [OutboxEntry]

    /// Quittiert einen erfolgreichen Push: entfernt den Outbox-Eintrag und setzt
    /// die lokale Server-Basis der Seite auf `serverUpdatedAtMillis` — aber nur,
    /// wenn der Eintrag seit `queuedAt` nicht erneut geändert wurde. Beides
    /// (Match-Prüfung + Löschen + Basis-Update) läuft in EINER Transaktion.
    /// Rückgabe: `true`, wenn tatsächlich quittiert wurde; `false`, wenn
    /// zwischenzeitlich ein neuerer Eintrag entstand (oder keiner vorlag) — dann
    /// bleibt Basis UND Eintrag unangetastet, der Aufrufer darf die Server-Basis
    /// NICHT vorrücken (Datenverlust-Schutz: die neuere lokale Änderung trägt eine
    /// andere Basis und muss separat gepusht werden).
    @discardableResult
    func markPushed(id: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws -> Bool

    /// Schreibt eine vom Server gezogene Seite in den Spiegel, OHNE einen
    /// Outbox-Eintrag zu erzeugen (Pull ist keine lokale Änderung). Setzt
    /// `updatedAt` und `baseUpdatedAt` auf den Server-Stand.
    func applyServerPage(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) async throws

    /// Wie `applyServerPage`, aber datenverlust-sicher gegen ein TOCTOU-Rennen:
    /// schreibt den Server-Stand NUR, wenn KEIN Outbox-Eintrag für die Seite
    /// vorliegt (also keine lokal ungepushte Änderung). Outbox-Check und Write
    /// laufen in DERSELBEN Transaktion — schliesst das Fenster, in dem zwischen
    /// dem Lesen der Outbox-Liste und diesem Write ein lokaler Save einging.
    /// Rückgabe: `true` = Server-Stand übernommen; `false` = wegen vorliegender
    /// Outbox übersprungen (der Push/409-Merge löst die Divergenz auf).
    @discardableResult
    func applyServerPageIfClean(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) async throws -> Bool

    /// Übernimmt das Ergebnis eines erfolgreich gepushten Auto-Merges: schreibt
    /// `html` als Server-Stand in den Spiegel UND quittiert den Outbox-Eintrag —
    /// beides nur, wenn der Eintrag seit `queuedAt` unverändert ist, in EINER
    /// Transaktion. `false` = inzwischen ein neuerer lokaler Save: dann bleiben
    /// Seitenzeile und Eintrag unangetastet (der neuere Stand darf nicht vom
    /// Merge-Ergebnis überschrieben werden, das seine jüngsten Zeichen nicht kennt).
    @discardableResult
    func applyMergedPush(id: String, html: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws -> Bool

    /// Löscht die Seite (wie `deletePage`), aber nur, wenn KEIN Outbox-Eintrag
    /// vorliegt — Prüfung und Löschen in EINER Transaktion. `false` = lokale
    /// ungepushte Änderung vorhanden, nichts gelöscht.
    @discardableResult
    func deletePageIfClean(id: String) async throws -> Bool

    /// Merge-Ancestor der Seite: das Server-HTML der letzten bekannten Basis, also
    /// der gemeinsame Vorfahr für den 3-Wege-Block-Merge bei 409. `nil`, solange
    /// keiner bekannt ist (dann ist kein 3-Wege-Merge möglich → Konflikt-UI).
    func serverBaseHtml(id: String) async throws -> String?

    /// Setzt (oder löscht mit `nil`) den Merge-Ancestor der Seite. No-op, wenn die
    /// Seite nicht im Spiegel liegt — der Ancestor hängt an der gespiegelten Seite
    /// und wird mit ihr gelöscht.
    ///
    /// Bewusst ein EIGENER, schmaler Write: der Ancestor lag früher als
    /// `serverBaseHtml`-Dictionary im `SyncState`-JSON. Dort kodierte JEDE Mutation
    /// (auch das Zurückschreiben eines unveränderten Pull-Cursors, ~1× pro Buch pro
    /// Tick) den kompletten Snapshot neu — gemessen 20 MB alle ~5 s bei 3096 Seiten.
    func setServerBaseHtml(_ html: String?, id: String) async throws

    /// Entfernt eine Seite aus dem Spiegel (serverseitig gelöscht, Delete-Reconcile).
    /// Räumt einen evtl. vorhandenen Outbox-Eintrag mit weg. Der Aufrufer stellt
    /// sicher, dass keine ungepushte/ungespeicherte Änderung verloren geht.
    func deletePage(id: String) async throws

    /// IDs aller Seiten ohne Buch-Zuordnung (`bookId == nil`). So eine Seite
    /// entsteht z. B. übers Einzelseiten-Nachladen der Bridge (`/content/pages/:id`
    /// liefert kein book_id, anders als der Sync-Pull) und wäre ohne Buch für den
    /// buch-skopierten Pull/Picker unsichtbar. Der Delete-Reconcile gleicht sie
    /// gegen die Buch-Trees ab und trägt das Buch via `assignBook` nach.
    func pageIdsWithoutBook() async throws -> [String]

    /// Trägt einer bereits gespiegelten Seite ihr Buch (+ optional Kapitel) nach —
    /// reine Metadaten-Korrektur: HTML, `updatedAt` und `baseUpdatedAt` bleiben
    /// unangetastet (datenverlust-sicher, auch bei dirty/ungepushten Seiten).
    /// No-op, wenn die Seite (noch) nicht im Spiegel liegt.
    func assignBook(pageId: String, bookId: Int, chapterId: Int?) async throws

    /// Wechselt den persistenten Spiegel auf den aktuell konfigurierten Server
    /// (Per-Server-Namespace). In-Place: die Objekt-Identität bleibt erhalten,
    /// nur die zugrundeliegende Datei wechselt — bestehende Referenzen (z. B. die
    /// Bridge) bleiben gültig. So pollt der Sync nach einem Server-Wechsel nicht
    /// mehr die Buch-IDs des alten Servers.
    func switchToCurrentServer() async throws
}

/// Fallbacks für Spiegel ohne eigene Transaktion (Test-Fakes): dieselbe
/// Semantik aus den Einzel-Operationen zusammengesetzt. Die echten Stores
/// (`GRDBLocalStore`, `InMemoryLocalStore`) überschreiben beide atomar.
extension LocalStore {
    @discardableResult
    func applyMergedPush(id: String, html: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws -> Bool {
        guard let entry = try await pendingOutbox().first(where: { $0.pageId == id }),
              entry.queuedAt == queuedAt else { return false }
        try await applyServerPage(id: id, html: html, pageName: nil, bookId: nil, chapterId: nil,
                                  serverUpdatedAtMillis: serverUpdatedAtMillis)
        return try await markPushed(id: id, queuedAt: queuedAt, serverUpdatedAtMillis: serverUpdatedAtMillis)
    }

    @discardableResult
    func deletePageIfClean(id: String) async throws -> Bool {
        if try await pendingOutbox().contains(where: { $0.pageId == id }) { return false }
        try await deletePage(id: id)
        return true
    }
}

/// Titel-Ableitung aus dem HTML — von allen LocalStore-Implementierungen
/// geteilt, damit In-Memory- und GRDB-Spiegel denselben Anzeigenamen erzeugen.
/// `nonisolated`, weil GRDB die Ableitung im DB-Writer-Thread aufruft.
nonisolated enum PageTitle {
    /// Grobe Titel-Ableitung: erste nicht-leere Textzeile des HTML (max. 80 Zeichen).
    static func derive(from html: String) -> String? {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        let firstLine = stripped.split(whereSeparator: \.isNewline).first.map(String.init) ?? stripped
        return String(firstLine.prefix(80))
    }
}

/// Klartext-Quelle für den Volltext-Index (Picker-Suche). Anders als
/// `PageTitle.derive` OHNE Zeilen-/Längenbegrenzung — der ganze Seitentext plus
/// der Seitenname werden indiziert. `nonisolated`, weil GRDB die Ableitung im
/// DB-Writer-Thread aufruft. Geteilt zwischen In-Memory- und GRDB-Spiegel, damit
/// beide denselben durchsuchbaren Text erzeugen.
nonisolated enum PageText {
    static func plain(html: String, pageName: String?) -> String {
        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // Seitenname mit indizieren, damit eine reine Inhaltssuche auch den Namen
        // abdeckt (der Picker kombiniert es ohnehin, aber so bleibt die FTS allein
        // schon vollständig).
        return (pageName ?? "") + " " + stripped
    }
}

/// Schlanke Listenzeile (kein HTML-Body).
nonisolated struct PageSummary: Codable, Equatable, Identifiable {
    var id: String
    var title: String?
    var pageName: String?
    var bookId: Int?
    var chapterId: Int?
    var updatedAt: Double

    /// Bevorzugter Anzeigename: Server-Seitenname, sonst HTML-Ableitung.
    var displayName: String { pageName ?? title ?? "Ohne Titel" }
}

// MARK: - Platzhalter-Implementierung (In-Memory + JSON-Snapshot)

/// Vorläufige Implementierung bis GRDB integriert ist. Hält alles im Speicher und
/// schreibt nach jeder Mutation einen JSON-Snapshot. Bewusst simpel — definiert
/// das Verhalten, nicht die endgültige Persistenz.
@MainActor
final class InMemoryLocalStore: LocalStore {
    private var pages: [String: StoredPage] = [:]
    private var outbox: [OutboxEntry] = []
    /// Merge-Ancestor je Seite. Bewusst NUR im Speicher: dieser Store ist der
    /// Platzhalter, produktiv läuft `GRDBLocalStore` (dort hängt der Ancestor als
    /// Spalte an der Seite). Verlust bei Neustart heisst nur, dass ein 409 in der
    /// Konflikt-UI landet statt still zu mergen — kein Datenverlust.
    private var ancestors: [String: String] = [:]

    private var snapshotURL: URL

    init() {
        AppSupport.migrateLegacyFileIfNeeded(named: "localstore.json")
        self.snapshotURL = AppSupport.serverDir().appendingPathComponent("localstore.json")
        loadSnapshot()
    }

    /// Server-Wechsel: in-place auf den Namespace des aktuellen Servers
    /// umschalten (Speicher leeren + Snapshot des neuen Servers laden).
    func switchToCurrentServer() async throws {
        AppSupport.migrateLegacyFileIfNeeded(named: "localstore.json")
        snapshotURL = AppSupport.serverDir().appendingPathComponent("localstore.json")
        pages = [:]
        outbox = []
        ancestors = [:]
        loadSnapshot()
    }

    func page(id: String) async throws -> StoredPage? {
        pages[id]
    }

    func list(bookId: Int?) async throws -> [PageSummary] {
        pages.values
            .filter { bookId == nil || $0.bookId == bookId }
            .map { PageSummary(id: $0.id,
                               title: $0.title,
                               pageName: $0.pageName,
                               bookId: $0.bookId,
                               chapterId: $0.chapterId,
                               updatedAt: $0.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(id: String, html: String, baseUpdatedAt: Double?) async throws -> StoredPage {
        let now = nowMillis()
        // Basis übernehmen: explizit übergebene Basis gewinnt, sonst bisherige behalten.
        let base = baseUpdatedAt ?? pages[id]?.baseUpdatedAt
        let title = PageTitle.derive(from: html) ?? pages[id]?.title
        // Buch-Zuordnung bleibt erhalten (lokaler Save ändert nur Inhalt).
        let existing = pages[id]
        let page = StoredPage(id: id,
                              html: html,
                              title: title,
                              pageName: existing?.pageName,
                              bookId: existing?.bookId,
                              chapterId: existing?.chapterId,
                              updatedAt: now,
                              baseUpdatedAt: base)
        pages[id] = page

        // Outbox: einen Eintrag pro Seite vorhalten (jüngster Stand gewinnt).
        outbox.removeAll { $0.pageId == id }
        outbox.append(OutboxEntry(pageId: id, html: html, baseUpdatedAt: base, queuedAt: now))

        persistSnapshot()
        return page
    }

    func searchContent(query: String, bookId: Int?) async throws -> [String] {
        // Einfache UND-Substring-Suche über den Klartext — der In-Memory-Spiegel
        // ist der Platzhalter; die echte FTS lebt im GRDB-Spiegel.
        let terms = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return [] }
        return pages.values
            .filter { bookId == nil || $0.bookId == bookId }
            .filter { page in
                let hay = PageText.plain(html: page.html, pageName: page.pageName).lowercased()
                return terms.allSatisfy { hay.contains($0) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.id)
    }

    func pageStats(bookId: Int?) async throws -> [String: PageStats] {
        // Platzhalter-Spiegel → beim Lesen rechnen. Der GRDB-Spiegel hält die
        // Zählwerte als Spalten (beim Schreiben gepflegt), weil dort Tausende
        // Seiten liegen können.
        var out: [String: PageStats] = [:]
        for page in pages.values where bookId == nil || page.bookId == bookId {
            out[page.id] = PageMetrics.counts(html: page.html)
        }
        return out
    }

    func pendingOutbox() async throws -> [OutboxEntry] {
        outbox
    }

    @discardableResult
    func markPushed(id: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws -> Bool {
        // Nur quittieren, wenn der Outbox-Eintrag unverändert seit dem Push ist.
        guard let idx = outbox.firstIndex(where: { $0.pageId == id }),
              outbox[idx].queuedAt == queuedAt else {
            // Kein passender Eintrag mehr → Basis NICHT vorrücken (s. Protokoll).
            return false
        }
        outbox.remove(at: idx)
        // Server-Basis übernehmen (Inhalt/updatedAt bleiben unangetastet).
        if var page = pages[id] {
            page.baseUpdatedAt = serverUpdatedAtMillis
            pages[id] = page
        }
        persistSnapshot()
        return true
    }

    func applyServerPage(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) async throws {
        applyServerPageInternal(id: id, html: html, pageName: pageName,
                                bookId: bookId, chapterId: chapterId,
                                serverUpdatedAtMillis: serverUpdatedAtMillis)
        persistSnapshot()
    }

    @discardableResult
    func applyServerPageIfClean(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) async throws -> Bool {
        // Lokal ungepushte Änderung → nicht überschreiben (Datenverlust-Schutz).
        guard !outbox.contains(where: { $0.pageId == id }) else { return false }
        applyServerPageInternal(id: id, html: html, pageName: pageName,
                                bookId: bookId, chapterId: chapterId,
                                serverUpdatedAtMillis: serverUpdatedAtMillis)
        persistSnapshot()
        return true
    }

    @discardableResult
    func applyMergedPush(id: String, html: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws -> Bool {
        guard let idx = outbox.firstIndex(where: { $0.pageId == id }),
              outbox[idx].queuedAt == queuedAt else { return false }
        outbox.remove(at: idx)
        applyServerPageInternal(id: id, html: html, pageName: nil, bookId: nil, chapterId: nil,
                                serverUpdatedAtMillis: serverUpdatedAtMillis)
        persistSnapshot()
        return true
    }

    @discardableResult
    func deletePageIfClean(id: String) async throws -> Bool {
        guard !outbox.contains(where: { $0.pageId == id }) else { return false }
        try await deletePage(id: id)
        return true
    }

    private func applyServerPageInternal(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) {
        let derived = PageTitle.derive(from: html) ?? pages[id]?.title
        pages[id] = StoredPage(id: id,
                               html: html,
                               title: derived,
                               pageName: pageName ?? pages[id]?.pageName,
                               bookId: bookId ?? pages[id]?.bookId,
                               chapterId: chapterId ?? pages[id]?.chapterId,
                               updatedAt: serverUpdatedAtMillis,
                               baseUpdatedAt: serverUpdatedAtMillis)
    }

    func serverBaseHtml(id: String) async throws -> String? {
        ancestors[id]
    }

    func setServerBaseHtml(_ html: String?, id: String) async throws {
        guard pages[id] != nil else { return }
        ancestors[id] = html
    }

    func deletePage(id: String) async throws {
        pages.removeValue(forKey: id)
        outbox.removeAll { $0.pageId == id }
        ancestors.removeValue(forKey: id)
        persistSnapshot()
    }

    func pageIdsWithoutBook() async throws -> [String] {
        pages.values.filter { $0.bookId == nil }.map(\.id)
    }

    func assignBook(pageId: String, bookId: Int, chapterId: Int?) async throws {
        guard var page = pages[pageId] else { return }
        page.bookId = bookId
        if let chapterId { page.chapterId = chapterId }
        pages[pageId] = page
        persistSnapshot()
    }

    // MARK: Hilfen

    /// Epoch-Millisekunden — gleiche Einheit wie `Date.now()` in der WebView.
    private func nowMillis() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    // MARK: JSON-Snapshot (Platzhalter-Persistenz)

    private struct Snapshot: Codable {
        var pages: [StoredPage]
        var outbox: [OutboxEntry]
    }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        pages = Dictionary(uniqueKeysWithValues: snap.pages.map { ($0.id, $0) })
        outbox = snap.outbox
    }

    private func persistSnapshot() {
        let snap = Snapshot(pages: Array(pages.values), outbox: outbox)
        do {
            let data = try JSONEncoder().encode(snap)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            // Datenverlust-Schutz: einen fehlgeschlagenen Snapshot-Write NICHT
            // verschlucken (Platte voll/Permissions) — der local-first-Save hätte
            // sonst „Erfolg" gemeldet, ohne dass etwas persistiert wurde.
            AppLog.store
                .error("Snapshot-Persistenz fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }
}
