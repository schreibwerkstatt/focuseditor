//
//  GRDBLocalStore.swift
//  schreibwerkstatt-focuseditor
//
//  GRDB/SQLite-Implementierung des `LocalStore` (CLAUDE.md Roadmap 4) — ersetzt
//  den `InMemoryLocalStore`-Platzhalter als app-weiter, persistenter Spiegel.
//  Verhalten ist bewusst 1:1 zum Platzhalter (gleiche Outbox-/Basis-Semantik),
//  nur die Persistenz wechselt von JSON-Snapshot auf eine echte DB.
//
//  DB-I/O läuft über die async-APIs der `DatabaseQueue` (eigener Writer-Thread);
//  die @MainActor-Methoden suspendieren nur und blockieren den Main-Thread nicht.
//

import Foundation
import GRDB

@MainActor
final class GRDBLocalStore: LocalStore {
    /// `var`, weil ein Server-Wechsel die zugrundeliegende DB in-place tauscht
    /// (Objekt-Identität bleibt erhalten → die Bridge-Referenz bleibt gültig).
    private var dbQueue: DatabaseQueue
    /// Fester Pfad-Override (Tests). `nil` → Per-Server-Standardort.
    private let fixedURL: URL?

    /// Öffnet (oder legt an) die SQLite-Datei und führt die Migrationen aus.
    /// `url == nil` → Per-Server-Standardort im Application-Support-Verzeichnis.
    init(url: URL? = nil) throws {
        self.fixedURL = url
        let dbURL = try url ?? Self.defaultURL()
        dbQueue = try DatabaseQueue(path: dbURL.path)
        try Self.migrator.migrate(dbQueue)
        try Self.rebuildSearchIndexIfNeeded(dbQueue)
        try Self.backfillPageStatsIfNeeded(dbQueue)
    }

    /// Wechselt den Spiegel auf den aktuell konfigurierten Server (Per-Server-
    /// Namespace). In-Place: die alte `DatabaseQueue` wird ersetzt (und beim
    /// Freigeben geschlossen), die Objekt-Identität bleibt erhalten. Bei festem
    /// Pfad-Override (Tests) ein No-op.
    func switchToCurrentServer() async throws {
        guard fixedURL == nil else { return }
        let dbURL = try Self.defaultURL()
        let newQueue = try DatabaseQueue(path: dbURL.path)
        try Self.migrator.migrate(newQueue)
        try Self.rebuildSearchIndexIfNeeded(newQueue)
        try Self.backfillPageStatsIfNeeded(newQueue)
        dbQueue = newQueue
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_pages_outbox") { db in
            // Spiegel der Seiten. Spaltennamen == StoredPage-Properties
            // (GRDB-Codable-Record mappt direkt darauf).
            try db.create(table: "page") { t in
                t.primaryKey("id", .text)
                t.column("html", .text).notNull().defaults(to: "")
                t.column("title", .text)
                t.column("pageName", .text)
                t.column("bookId", .integer)
                t.column("chapterId", .integer)
                t.column("updatedAt", .double).notNull().defaults(to: 0)
                t.column("baseUpdatedAt", .double)
            }
            // Schreib-Queue: genau ein Eintrag pro Seite (jüngster Stand gewinnt)
            // → pageId ist Primärschlüssel.
            try db.create(table: "outbox") { t in
                t.primaryKey("pageId", .text)
                t.column("html", .text).notNull().defaults(to: "")
                t.column("baseUpdatedAt", .double)
                t.column("queuedAt", .double).notNull().defaults(to: 0)
            }
            // Picker-Filter + Pull sind buch-skopiert.
            try db.create(index: "page_on_bookId", on: "page", columns: ["bookId"])
        }
        m.registerMigration("v2_outbox_queuedAt_index") { db in
            // `pendingOutbox()` liest die Queue in `queuedAt`-Reihenfolge (FIFO-Push).
            // Ohne Index ist das ein Full-Table-Scan + Sortierung — bei normalerweise
            // winziger Outbox unkritisch, aber bei einem grossen Offline-Rückstau
            // (lange offline, viele Seiten editiert) würde der Read den Push-Tick
            // bremsen. Index hält die geordnete Lese-Operation auch dann flott.
            try db.create(index: "outbox_on_queuedAt", on: "outbox", columns: ["queuedAt"])
        }
        m.registerMigration("v3_page_fts") { db in
            // Volltext-Index über den Seiteninhalt (Picker-Inhaltssuche). Standalone-
            // FTS5 (KEIN external-content): der durchsuchbare Klartext muss erst aus
            // dem HTML gezogen werden (SQL kann keine Tags strippen), darum pflegt
            // der Swift-Code den Index bei jedem Write (s. `upsertSearchIndex`) statt
            // per Trigger. `unicode61 remove_diacritics 2` → akzentunabhängige Suche
            // („cafe" findet „café"); `id UNINDEXED` hält nur die Verknüpfung, ohne
            // die ID selbst zu tokenisieren.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE page_fts USING fts5(
                    id UNINDEXED,
                    content,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """)
        }
        m.registerMigration("v4_page_serverBaseHtml") { db in
            // Merge-Ancestor (Server-HTML der letzten Basis) je Seite. Lag früher als
            // `serverBaseHtml`-Dictionary im `SyncState`-JSON — dort kodierte jede
            // Mutation den GANZEN Snapshot neu (gemessen: 20 MB alle ~5 s, weil der
            // Poll-Tick pro Buch den Cursor zurückschreibt). Als Spalte an der Seite
            // ist es ein Row-Update statt eines Voll-Rewrites.
            //
            // BEWUSST NICHT in `StoredPage` aufgenommen: der Record schreibt per
            // `save`/`update` nur seine eigenen Spalten, diese bleibt dabei
            // unangetastet — sonst würde jeder Pull-/Save-Write den Ancestor
            // mitschleppen (und beim Pull mit dem neuen Server-HTML überschreiben,
            // bevor der Merge ihn braucht).
            try db.alter(table: "page") { t in
                t.add(column: "serverBaseHtml", .text)
            }
        }
        m.registerMigration("v5_page_counts") { db in
            // Zählwerte je Seite (Zeichen/Wörter) für den Seiten-Picker. Als
            // Spalten, weil sie sonst bei JEDEM Öffnen des Pickers aus dem HTML
            // ALLER Seiten des Buchs neu gerechnet werden müssten (bei einem
            // grossen Buch mehrere Tausend Seiten × mehrere KB).
            //
            // NULL = noch nicht gerechnet (Alt-Bestand) — `backfillPageStatsIfNeeded`
            // trägt sie nach dem Öffnen der DB nach, in Häppchen statt in einer
            // Riesen-Transaktion. Bewusst NICHT in der Migration selbst: die läuft
            // beim Start, und ein Voll-Rechnen mit allen HTML-Bodies im Speicher
            // wäre genau dort am unpassendsten.
            //
            // BEWUSST NICHT in `StoredPage` (wie `serverBaseHtml`): der Record
            // schreibt nur seine eigenen Spalten, die Zählwerte pflegt
            // `upsertDerived` in derselben Transaktion.
            try db.alter(table: "page") { t in
                t.add(column: "charCount", .integer)
                t.add(column: "wordCount", .integer)
            }
        }
        return m
    }

    // MARK: - Abgeleitete Werte (Volltext-Index + Zählwerte)

    /// Führt ALLES nach, was sich aus dem HTML einer Seite ableitet: den
    /// FTS-Eintrag (Picker-Inhaltssuche) und die Zählwerte (Zeichen/Wörter für die
    /// Picker-Zeile). EIN Aufruf pro Write, damit die beiden nie auseinanderdriften.
    /// `nonisolated`, da im DB-Writer-Thread aufgerufen.
    nonisolated private static func upsertDerived(_ db: Database, id: String, html: String, pageName: String?) throws {
        try upsertSearchIndex(db, id: id, html: html, pageName: pageName)
        try writePageStats(db, id: id, html: html)
    }

    /// Schreibt die Zählwerte einer Seite. Reines Spalten-Update — Inhalt,
    /// Stempel und Outbox der Seite bleiben unberührt.
    nonisolated private static func writePageStats(_ db: Database, id: String, html: String) throws {
        let stats = PageMetrics.counts(html: html)
        try db.execute(sql: "UPDATE page SET charCount = ?, wordCount = ? WHERE id = ?",
                       arguments: [stats.chars, stats.words, id])
    }

    /// Trägt fehlende Zählwerte nach (Alt-Bestand nach der Migration; theoretisch
    /// auch ein Drift). In Häppchen von 200 Seiten, jedes in eigener Transaktion:
    /// so liegen nie alle HTML-Bodies eines grossen Buchs gleichzeitig im Speicher
    /// und der Start bleibt unterbrechbar. Ist nichts offen, kostet es EINE
    /// indexlose Zählabfrage.
    nonisolated private static func backfillPageStatsIfNeeded(_ queue: DatabaseQueue) throws {
        while true {
            let done = try queue.write { db -> Bool in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, html FROM page WHERE charCount IS NULL LIMIT 200
                    """)
                guard !rows.isEmpty else { return true }
                for row in rows {
                    try writePageStats(db, id: row["id"], html: row["html"] ?? "")
                }
                return false
            }
            if done { return }
        }
    }

    /// Schreibt/aktualisiert den FTS-Eintrag einer Seite (löschen + neu einfügen —
    /// ein Eintrag pro ID). `nonisolated`, da im DB-Writer-Thread aufgerufen.
    nonisolated private static func upsertSearchIndex(_ db: Database, id: String, html: String, pageName: String?) throws {
        try db.execute(sql: "DELETE FROM page_fts WHERE id = ?", arguments: [id])
        let text = PageText.plain(html: html, pageName: pageName)
        try db.execute(sql: "INSERT INTO page_fts (id, content) VALUES (?, ?)", arguments: [id, text])
    }

    /// Baut den FTS-Index aus dem `page`-Tisch neu auf, wenn er nicht zum Bestand
    /// passt (Anzahl FTS-Einträge ≠ Anzahl Seiten) — greift einmalig nach der
    /// Erst-Migration mit bereits vorhandenen Seiten (oder falls der Index je
    /// driftet). Danach hält jeder Write den Index synchron, sodass die beiden
    /// Counts gleich bleiben und der teure Rebuild ausbleibt.
    nonisolated private static func rebuildSearchIndexIfNeeded(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            let pageCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page") ?? 0
            let ftsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_fts") ?? 0
            guard pageCount != ftsCount else { return }
            try db.execute(sql: "DELETE FROM page_fts")
            let rows = try Row.fetchAll(db, sql: "SELECT id, html, pageName FROM page")
            for row in rows {
                try upsertSearchIndex(db, id: row["id"], html: row["html"], pageName: row["pageName"])
            }
        }
    }

    /// Baut aus freier Nutzereingabe eine sichere FTS5-MATCH-Query: jedes Token
    /// als quotiertes Präfix (`"wort"*`), per implizitem AND verknüpft. Das Quoting
    /// (innere `"` verdoppelt) schützt vor FTS5-Syntaxfehlern bei Sonderzeichen;
    /// `nil`, wenn nichts Sinnvolles übrig bleibt.
    nonisolated private static func ftsQuery(_ raw: String) -> String? {
        let tokens = raw
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - Lesen

    func page(id: String) async throws -> StoredPage? {
        try await dbQueue.read { db in
            try StoredPage.fetchOne(db, key: id)
        }
    }

    func list(bookId: Int?) async throws -> [PageSummary] {
        // Schlanke Übersicht ohne HTML-Body → nur die Picker-Spalten selektieren.
        let columns = "id, title, pageName, bookId, chapterId, updatedAt"
        return try await dbQueue.read { db in
            if let bookId {
                return try PageSummary.fetchAll(
                    db,
                    sql: "SELECT \(columns) FROM page WHERE bookId = ? ORDER BY updatedAt DESC",
                    arguments: [bookId])
            }
            return try PageSummary.fetchAll(
                db,
                sql: "SELECT \(columns) FROM page ORDER BY updatedAt DESC")
        }
    }

    func searchContent(query: String, bookId: Int?) async throws -> [String] {
        guard let match = Self.ftsQuery(query) else { return [] }
        return try await dbQueue.read { db in
            // Nach `rank` (FTS5-Relevanz) sortiert, auf den Buch-Spiegel skopiert.
            // LIMIT als defensive Schranke gegen Riesentreffer bei sehr kurzen
            // Präfixen — der Picker zeigt ohnehin eine gefilterte Liste.
            if let bookId {
                return try String.fetchAll(db, sql: """
                    SELECT f.id FROM page_fts f JOIN page p ON p.id = f.id
                    WHERE f.content MATCH ? AND p.bookId = ?
                    ORDER BY rank LIMIT 500
                    """, arguments: [match, bookId])
            }
            return try String.fetchAll(db, sql: """
                SELECT f.id FROM page_fts f
                WHERE f.content MATCH ?
                ORDER BY rank LIMIT 500
                """, arguments: [match])
        }
    }

    func pageStats(bookId: Int?) async throws -> [String: PageStats] {
        try await dbQueue.read { db in
            // Ohne HTML-Body — nur die drei Zahlen-Spalten (der Picker fragt das
            // für ALLE Seiten des Buchs ab). `charCount IS NULL` (noch nicht
            // gerechnet) fällt raus, damit der Picker „—" zeigt statt einer 0,
            // die „Seite ist leer" behaupten würde.
            let rows: [Row]
            if let bookId {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, charCount, wordCount FROM page
                    WHERE bookId = ? AND charCount IS NOT NULL
                    """, arguments: [bookId])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, charCount, wordCount FROM page WHERE charCount IS NOT NULL
                    """)
            }
            var out: [String: PageStats] = [:]
            out.reserveCapacity(rows.count)
            for row in rows {
                let id: String = row["id"]
                out[id] = PageStats(chars: row["charCount"] ?? 0, words: row["wordCount"] ?? 0)
            }
            return out
        }
    }

    func pendingOutbox() async throws -> [OutboxEntry] {
        try await dbQueue.read { db in
            try OutboxEntry
                .order(Column("queuedAt").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Schreiben (local-first)

    func save(id: String, html: String, baseUpdatedAt: Double?) async throws -> StoredPage {
        let now = Self.nowMillis()
        return try await dbQueue.write { db in
            let existing = try StoredPage.fetchOne(db, key: id)
            // No-op-Guard: ist das HTML byte-identisch zum bereits gespeicherten Stand,
            // erzeugt der Save KEINEN Outbox-Eintrag (und bumpt updatedAt nicht). Der
            // Editor-Autosave feuert entprellt auch ohne echte Inhaltsänderung (Timer,
            // Fokuswechsel, Cursor-Bewegung) — ohne diesen Guard ginge dafür jedes Mal
            // ein redundanter Push raus (Server bumpt updated_at → Pull echot zurück).
            // Liegt bereits ein ungepushter Eintrag vor, trägt er per Upsert dasselbe
            // HTML, ist also ebenfalls unberührt. (Datenverlust-Schutz: wir verwerfen
            // nichts, wir überspringen nur einen inhaltsgleichen Schreibvorgang.)
            if let existing, existing.html == html { return existing }
            // Basis übernehmen: explizit übergebene Basis gewinnt, sonst bisherige behalten.
            let base = baseUpdatedAt ?? existing?.baseUpdatedAt
            let title = PageTitle.derive(from: html) ?? existing?.title
            // Buch-/Kapitel-Zuordnung bleibt erhalten (lokaler Save ändert nur Inhalt).
            let page = StoredPage(id: id,
                                  html: html,
                                  title: title,
                                  pageName: existing?.pageName,
                                  bookId: existing?.bookId,
                                  chapterId: existing?.chapterId,
                                  updatedAt: now,
                                  baseUpdatedAt: base)
            try page.save(db)

            // Outbox: einen Eintrag pro Seite (save = upsert auf pageId).
            let entry = OutboxEntry(pageId: id, html: html, baseUpdatedAt: base, queuedAt: now)
            try entry.save(db)
            // Volltext-Index + Zählwerte nachführen (selbe Transaktion → kein Drift).
            try Self.upsertDerived(db, id: id, html: html, pageName: page.pageName)
            return page
        }
    }

    @discardableResult
    func markPushed(id: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws -> Bool {
        try await dbQueue.write { db in
            // Match-Prüfung + Löschen + Basis-Update atomar in EINER Transaktion.
            // Nur quittieren, wenn der Outbox-Eintrag unverändert seit dem Push ist.
            guard let entry = try OutboxEntry.fetchOne(db, key: id), entry.queuedAt == queuedAt else {
                // Inzwischen neuerer Eintrag (oder keiner) → Basis NICHT vorrücken,
                // Eintrag NICHT löschen (s. Protokoll: Datenverlust-Schutz).
                return false
            }
            try entry.delete(db)
            // Server-Basis übernehmen (Inhalt/updatedAt bleiben unangetastet).
            if var page = try StoredPage.fetchOne(db, key: id) {
                page.baseUpdatedAt = serverUpdatedAtMillis
                try page.update(db)
            }
            return true
        }
    }

    func applyServerPage(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) async throws {
        try await dbQueue.write { db in
            try Self.writeServerPage(db, id: id, html: html, pageName: pageName,
                                     bookId: bookId, chapterId: chapterId,
                                     serverUpdatedAtMillis: serverUpdatedAtMillis)
        }
    }

    @discardableResult
    func applyServerPageIfClean(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) async throws -> Bool {
        try await dbQueue.write { db in
            // Outbox-Check + Write atomar: liegt eine lokal ungepushte Änderung
            // vor, NICHT überschreiben (der Push/409-Merge löst die Divergenz auf).
            if try OutboxEntry.fetchOne(db, key: id) != nil { return false }
            try Self.writeServerPage(db, id: id, html: html, pageName: pageName,
                                     bookId: bookId, chapterId: chapterId,
                                     serverUpdatedAtMillis: serverUpdatedAtMillis)
            return true
        }
    }

    @discardableResult
    func applyMergedPush(id: String, html: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws -> Bool {
        try await dbQueue.write { db in
            // Match-Prüfung + Seitenzeile + Outbox-Quittung atomar (s. Protokoll).
            guard let entry = try OutboxEntry.fetchOne(db, key: id), entry.queuedAt == queuedAt else {
                return false
            }
            try entry.delete(db)
            try Self.writeServerPage(db, id: id, html: html, pageName: nil,
                                     bookId: nil, chapterId: nil,
                                     serverUpdatedAtMillis: serverUpdatedAtMillis)
            return true
        }
    }

    @discardableResult
    func deletePageIfClean(id: String) async throws -> Bool {
        try await dbQueue.write { db in
            if try OutboxEntry.fetchOne(db, key: id) != nil { return false }
            _ = try StoredPage.deleteOne(db, key: id)
            try db.execute(sql: "DELETE FROM page_fts WHERE id = ?", arguments: [id])
            return true
        }
    }

    /// Gemeinsamer Server-Stand-Write (Pull erzeugt KEINEN Outbox-Eintrag).
    /// `nonisolated`, weil GRDB die Closure im DB-Writer-Thread ausführt.
    nonisolated private static func writeServerPage(_ db: Database, id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) throws {
        let existing = try StoredPage.fetchOne(db, key: id)
        let derived = PageTitle.derive(from: html) ?? existing?.title
        let page = StoredPage(id: id,
                              html: html,
                              title: derived,
                              pageName: pageName ?? existing?.pageName,
                              bookId: bookId ?? existing?.bookId,
                              chapterId: chapterId ?? existing?.chapterId,
                              updatedAt: serverUpdatedAtMillis,
                              baseUpdatedAt: serverUpdatedAtMillis)
        try page.save(db)
        try upsertDerived(db, id: id, html: html, pageName: page.pageName)
    }

    func serverBaseHtml(id: String) async throws -> String? {
        try await dbQueue.read { db in
            // NULL-Spalte → `fetchOne` liefert nil (kein Ancestor bekannt).
            try String.fetchOne(db, sql: "SELECT serverBaseHtml FROM page WHERE id = ?",
                                arguments: [id])
        }
    }

    func setServerBaseHtml(_ html: String?, id: String) async throws {
        try await dbQueue.write { db in
            // Reines Spalten-Update: HTML/Stempel/Outbox der Seite bleiben unberührt.
            // Unbekannte Seite → 0 Zeilen betroffen (No-op, s. Protokoll).
            try db.execute(sql: "UPDATE page SET serverBaseHtml = ? WHERE id = ?",
                           arguments: [html, id])
        }
    }

    func deletePage(id: String) async throws {
        try await dbQueue.write { db in
            _ = try StoredPage.deleteOne(db, key: id)
            _ = try OutboxEntry.deleteOne(db, key: id)
            try db.execute(sql: "DELETE FROM page_fts WHERE id = ?", arguments: [id])
        }
    }

    func pageIdsWithoutBook() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM page WHERE bookId IS NULL")
        }
    }

    func assignBook(pageId: String, bookId: Int, chapterId: Int?) async throws {
        try await dbQueue.write { db in
            // Nur Metadaten korrigieren — Inhalt/Stempel bleiben unangetastet.
            guard var page = try StoredPage.fetchOne(db, key: pageId) else { return }
            page.bookId = bookId
            if let chapterId { page.chapterId = chapterId }
            try page.update(db)
        }
    }

    // MARK: - Hilfen

    /// Epoch-Millisekunden — gleiche Einheit wie `Date.now()` in der WebView.
    private static func nowMillis() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    /// Standard-DB-Pfad: Application Support / schreibwerkstatt-focuseditor /
    /// servers/<slug>/localstore.sqlite (Per-Server-Namespace). Migriert eine
    /// evtl. noch global abgelegte Alt-DB einmalig in den aktuellen Namespace.
    private static func defaultURL() throws -> URL {
        AppSupport.migrateLegacyFileIfNeeded(named: "localstore.sqlite")
        return AppSupport.serverDir().appendingPathComponent("localstore.sqlite")
    }
}

// MARK: - GRDB-Record-Konformität
//
// Die Domänen-Typen sind bereits Codable; GRDB leitet Fetch/Persist daraus ab.
// Spaltennamen == Property-Namen (siehe Migration oben).

extension StoredPage: nonisolated FetchableRecord, nonisolated PersistableRecord {
    nonisolated static let databaseTableName = "page"
}

extension OutboxEntry: nonisolated FetchableRecord, nonisolated PersistableRecord {
    nonisolated static let databaseTableName = "outbox"
}

extension PageSummary: nonisolated FetchableRecord {}
