//
//  GRDBLocalStoreTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Tests des persistenten Spiegels (SQLite/GRDB) auf einer temporären DB-Datei:
//  Migrationen, Outbox-Semantik (ein Eintrag je Seite, FIFO, `markPushed`-Match),
//  Datenverlust-Schutz beim Server-Write (`applyServerPageIfClean`), Löschen und
//  die FTS5-Inhaltssuche.
//
//  Genau die Semantik, auf die sich die SyncEngine verlässt — hier ohne Netz und
//  ohne Engine geprüft. Jede Testinstanz bekommt eine eigene Datei (`init(url:)`),
//  der App-Support-Standardort wird nie angefasst.
//
//  Stil-Hinweis: `await`-Ergebnisse werden in Konstanten gehoben, weil die
//  XCTAssert-Makros ihre Argumente als (nicht-asynchrone) Autoclosures nehmen.
//

import XCTest
import GRDB

@MainActor
final class GRDBLocalStoreTests: XCTestCase {

    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grdb-store-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + suffix))
        }
        super.tearDown()
    }

    private func makeStore() throws -> GRDBLocalStore {
        try GRDBLocalStore(url: dbURL)
    }

    // MARK: - Migration / Persistenz

    func testMigrationsRunAndDataSurvivesReopen() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>Hallo</p>", baseUpdatedAt: nil)

        // Zweites Öffnen derselben Datei: Migrator muss idempotent durchlaufen.
        let reopened = try makeStore()
        let page = try await reopened.page(id: "1")
        XCTAssertEqual(page?.html, "<p>Hallo</p>")
        let outbox = try await reopened.pendingOutbox()
        XCTAssertEqual(outbox.count, 1, "die Outbox überlebt den Neustart")
    }

    func testServerPagesAreListedPerBook() async throws {
        let store = try makeStore()
        try await store.applyServerPage(id: "1", html: "<h1>Erstes</h1>", pageName: "Kapitel 1",
                                        bookId: 7, chapterId: 3, serverUpdatedAtMillis: 1_000)
        try await store.applyServerPage(id: "2", html: "<h1>Zweites</h1>", pageName: "Kapitel 2",
                                        bookId: 9, chapterId: nil, serverUpdatedAtMillis: 2_000)

        let book7 = try await store.list(bookId: 7)
        XCTAssertEqual(book7.map(\.id), ["1"])
        XCTAssertEqual(book7.first?.pageName, "Kapitel 1")
        XCTAssertEqual(book7.first?.chapterId, 3)
        let all = try await store.list(bookId: nil)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.map(\.id), ["2", "1"], "Liste ist nach updatedAt absteigend sortiert")
    }

    // MARK: - Outbox

    func testSaveQueuesExactlyOneOutboxEntryPerPage() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>A</p>", baseUpdatedAt: 500)
        _ = try await store.save(id: "1", html: "<p>B</p>", baseUpdatedAt: nil)

        let outbox = try await store.pendingOutbox()
        XCTAssertEqual(outbox.count, 1, "pro Seite genau ein Eintrag (jüngster Stand gewinnt)")
        XCTAssertEqual(outbox.first?.html, "<p>B</p>")
        XCTAssertEqual(outbox.first?.baseUpdatedAt, 500, "die Basis bleibt erhalten, wenn keine neue kommt")
    }

    // (d) Save-Kennungen: Ersetzen vergibt eine neue `saveId` und erbt die
    // gesendete; beides überlebt einen Neustart.
    func testSaveIdsSurviveReopenAndAreInheritedOnReplace() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>A</p>", baseUpdatedAt: 500)
        let first = try await store.pendingOutbox()[0]
        XCTAssertFalse(first.saveId.isEmpty)
        XCTAssertEqual(first.sentUnconfirmedIds, [], "noch nicht gesendet")
        let sent = try await store.markSaveIdSent(pageId: "1", queuedAt: first.queuedAt)
        XCTAssertEqual(sent?.sentUnconfirmedIds, [first.saveId])

        _ = try await store.save(id: "1", html: "<p>B</p>", baseUpdatedAt: nil)
        let replaced = try await store.pendingOutbox()[0]
        XCTAssertNotEqual(replaced.saveId, first.saveId, "neuer Text → neue Kennung")
        XCTAssertEqual(replaced.sentUnconfirmedIds, [first.saveId], "die gesendete wird geerbt")
        let stale = try await store.markSaveIdSent(pageId: "1", queuedAt: first.queuedAt)
        XCTAssertNil(stale, "ein ersetzter Eintrag wird nicht mehr als gesendet vermerkt")

        let reopened = try makeStore()
        let afterRestart = try await reopened.pendingOutbox()[0]
        XCTAssertEqual(afterRestart.saveId, replaced.saveId)
        XCTAssertEqual(afterRestart.sentUnconfirmedIds, [first.saveId])

        try await reopened.forgetSaveIds([first.saveId], pageId: "1")
        let forgotten = try await reopened.pendingOutbox()[0]
        XCTAssertEqual(forgotten.sentUnconfirmedIds, [])
        XCTAssertEqual(forgotten.saveId, replaced.saveId)
    }

    func testOwnSaveIdsAreCappedOldestFirst() {
        var entry = OutboxEntry(pageId: "1", html: "", baseUpdatedAt: nil, queuedAt: 0)
        for _ in 0..<20 {
            entry = OutboxEntry.queued(pageId: "1", html: "", baseUpdatedAt: nil, queuedAt: 0,
                                       replacing: entry.markingSent())
        }
        let sent = entry.markingSent()
        XCTAssertEqual(sent.sentUnconfirmedIds.count, OutboxEntry.maxOwnSaveIds + 1)
        XCTAssertEqual(sent.sentUnconfirmedIds.last, sent.saveId, "jüngste zuletzt")
        XCTAssertEqual(sent.ownSaveIdsForPush.count, OutboxEntry.maxOwnSaveIds)
        XCTAssertFalse(sent.ownSaveIdsForPush.contains(sent.saveId), "eigene Kennung geht als save_id")
    }

    /// Ein Eintrag von vor den Save-Kennungen (JSON-Snapshot des Platzhalter-
    /// Spiegels) lädt weiter und bekommt eine frische Kennung.
    func testLegacyOutboxEntryDecodesWithFreshSaveId() throws {
        let json = #"{"pageId":"1","html":"<p>A</p>","baseUpdatedAt":500,"queuedAt":1}"#
        let entry = try JSONDecoder().decode(OutboxEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.html, "<p>A</p>")
        XCTAssertEqual(UUID(uuidString: entry.saveId)?.uuidString.lowercased(), entry.saveId)
        XCTAssertEqual(entry.sentUnconfirmedIds, [])
    }

    func testIdenticalHtmlDoesNotQueueAgain() async throws {
        let store = try makeStore()
        let first = try await store.save(id: "1", html: "<p>A</p>", baseUpdatedAt: nil)
        let entry = try await store.pendingOutbox()[0]
        _ = try await store.markPushed(id: "1", queuedAt: entry.queuedAt, serverUpdatedAtMillis: 9_000)
        let afterPush = try await store.pendingOutbox()
        XCTAssertTrue(afterPush.isEmpty)

        // Autosave ohne echte Änderung → kein neuer Push, kein neuer Stempel.
        let again = try await store.save(id: "1", html: "<p>A</p>", baseUpdatedAt: nil)
        let outbox = try await store.pendingOutbox()
        XCTAssertTrue(outbox.isEmpty, "inhaltsgleicher Save darf nichts einreihen")
        XCTAssertEqual(again.updatedAt, first.updatedAt, "updatedAt darf nicht grundlos vorrücken")
    }

    func testPendingOutboxIsFifo() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>A</p>", baseUpdatedAt: nil)
        try await Task.sleep(for: .milliseconds(5))
        _ = try await store.save(id: "2", html: "<p>B</p>", baseUpdatedAt: nil)
        try await Task.sleep(for: .milliseconds(5))
        _ = try await store.save(id: "3", html: "<p>C</p>", baseUpdatedAt: nil)

        let outbox = try await store.pendingOutbox()
        XCTAssertEqual(outbox.map(\.pageId), ["1", "2", "3"])
    }

    func testMarkPushedAcknowledgesOnlyTheEntryThatWasPushed() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>A</p>", baseUpdatedAt: 100)
        let pushed = try await store.pendingOutbox()[0]

        // Während der Push läuft, tippt der Nutzer weiter → neuer Eintrag.
        try await Task.sleep(for: .milliseconds(5))
        _ = try await store.save(id: "1", html: "<p>A+</p>", baseUpdatedAt: nil)

        let ack = try await store.markPushed(id: "1", queuedAt: pushed.queuedAt, serverUpdatedAtMillis: 9_000)
        XCTAssertFalse(ack, "der Eintrag hat sich seit dem Push geändert → nicht quittieren")
        let stillQueued = try await store.pendingOutbox()
        XCTAssertEqual(stillQueued.count, 1, "die neuere Änderung bleibt in der Queue")
        let unchanged = try await store.page(id: "1")
        XCTAssertEqual(unchanged?.baseUpdatedAt, 100, "die Basis darf nicht vorrücken")

        // Der aktuelle Eintrag lässt sich sehr wohl quittieren.
        let current = try await store.pendingOutbox()[0]
        let ack2 = try await store.markPushed(id: "1", queuedAt: current.queuedAt, serverUpdatedAtMillis: 9_500)
        XCTAssertTrue(ack2)
        let drained = try await store.pendingOutbox()
        XCTAssertTrue(drained.isEmpty)
        let page = try await store.page(id: "1")
        XCTAssertEqual(page?.baseUpdatedAt, 9_500)
        XCTAssertEqual(page?.html, "<p>A+</p>", "Quittieren ändert den Inhalt nicht")
    }

    // MARK: - Server-Writes (Datenverlust-Schutz)

    func testApplyServerPageSetsBaseAndCreatesNoOutboxEntry() async throws {
        let store = try makeStore()
        try await store.applyServerPage(id: "1", html: "<p>Server</p>", pageName: "S",
                                        bookId: 7, chapterId: nil, serverUpdatedAtMillis: 4_200)
        let page = try await store.page(id: "1")
        XCTAssertEqual(page?.updatedAt, 4_200)
        XCTAssertEqual(page?.baseUpdatedAt, 4_200)
        let outbox = try await store.pendingOutbox()
        XCTAssertTrue(outbox.isEmpty, "ein Pull erzeugt keinen Push")
    }

    func testApplyServerPageIfCleanRefusesToOverwriteLocalEdit() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>Lokal</p>", baseUpdatedAt: 100)

        let applied = try await store.applyServerPageIfClean(id: "1", html: "<p>Server</p>", pageName: nil,
                                                             bookId: nil, chapterId: nil,
                                                             serverUpdatedAtMillis: 5_000)
        XCTAssertFalse(applied)
        let kept = try await store.page(id: "1")
        XCTAssertEqual(kept?.html, "<p>Lokal</p>", "ungepushte Änderung bleibt stehen")

        // Nach dem Quittieren ist die Seite sauber → Server-Stand darf greifen.
        let entry = try await store.pendingOutbox()[0]
        _ = try await store.markPushed(id: "1", queuedAt: entry.queuedAt, serverUpdatedAtMillis: 4_000)
        let applied2 = try await store.applyServerPageIfClean(id: "1", html: "<p>Server</p>", pageName: nil,
                                                              bookId: nil, chapterId: nil,
                                                              serverUpdatedAtMillis: 5_000)
        XCTAssertTrue(applied2)
        let updated = try await store.page(id: "1")
        XCTAssertEqual(updated?.html, "<p>Server</p>")
    }

    func testServerWriteKeepsExistingBookAssignmentWhenNil() async throws {
        let store = try makeStore()
        try await store.applyServerPage(id: "1", html: "<p>A</p>", pageName: "Name",
                                        bookId: 7, chapterId: 3, serverUpdatedAtMillis: 1_000)
        // `GET /content/pages/:id` liefert kein book_id → nil darf nichts löschen.
        try await store.applyServerPage(id: "1", html: "<p>B</p>", pageName: nil,
                                        bookId: nil, chapterId: nil, serverUpdatedAtMillis: 2_000)
        let page = try await store.page(id: "1")
        XCTAssertEqual(page?.bookId, 7)
        XCTAssertEqual(page?.chapterId, 3)
        XCTAssertEqual(page?.pageName, "Name")
    }

    func testOrphanBackfill() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>Waise</p>", baseUpdatedAt: nil)
        let orphans = try await store.pageIdsWithoutBook()
        XCTAssertEqual(orphans, ["1"])

        try await store.assignBook(pageId: "1", bookId: 7, chapterId: 3)
        let rest = try await store.pageIdsWithoutBook()
        XCTAssertTrue(rest.isEmpty)
        let page = try await store.page(id: "1")
        XCTAssertEqual(page?.bookId, 7)
        XCTAssertEqual(page?.html, "<p>Waise</p>", "der Backfill fasst den Inhalt nicht an")
    }

    // MARK: - Löschen

    func testDeleteRemovesPageOutboxAndSearchIndex() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>Leuchtturm</p>", baseUpdatedAt: nil)
        let before = try await store.searchContent(query: "leuchtturm", bookId: nil)
        XCTAssertEqual(before, ["1"])

        try await store.deletePage(id: "1")
        let page = try await store.page(id: "1")
        XCTAssertNil(page)
        let outbox = try await store.pendingOutbox()
        XCTAssertTrue(outbox.isEmpty)
        let after = try await store.searchContent(query: "leuchtturm", bookId: nil)
        XCTAssertTrue(after.isEmpty, "der Volltext-Index darf keine Leiche behalten")
    }

    // MARK: - Volltextsuche (FTS5)

    func testSearchIsPrefixAndDiacriticsInsensitive() async throws {
        let store = try makeStore()
        try await store.applyServerPage(id: "1", html: "<p>Im Café am Hafen</p>", pageName: "Ankunft",
                                        bookId: 7, chapterId: nil, serverUpdatedAtMillis: 1_000)

        let accent = try await store.searchContent(query: "cafe", bookId: nil)
        XCTAssertEqual(accent, ["1"], "Akzente ignorieren")
        let prefix = try await store.searchContent(query: "haf", bookId: nil)
        XCTAssertEqual(prefix, ["1"], "Präfix-Treffer")
        let byName = try await store.searchContent(query: "ankunft", bookId: nil)
        XCTAssertEqual(byName, ["1"], "der Seitenname zählt mit")
        let conjunction = try await store.searchContent(query: "hafen wüste", bookId: nil)
        XCTAssertTrue(conjunction.isEmpty, "mehrere Wörter sind UND-verknüpft")
    }

    func testSearchIsBookScopedAndSurvivesSpecialCharacters() async throws {
        let store = try makeStore()
        try await store.applyServerPage(id: "1", html: "<p>Nebel</p>", pageName: nil,
                                        bookId: 7, chapterId: nil, serverUpdatedAtMillis: 1_000)
        try await store.applyServerPage(id: "2", html: "<p>Nebel</p>", pageName: nil,
                                        bookId: 9, chapterId: nil, serverUpdatedAtMillis: 1_000)

        let inSeven = try await store.searchContent(query: "nebel", bookId: 7)
        XCTAssertEqual(inSeven, ["1"])
        let inNine = try await store.searchContent(query: "nebel", bookId: 9)
        XCTAssertEqual(inNine, ["2"])
        let global = try await store.searchContent(query: "nebel", bookId: nil)
        XCTAssertEqual(global.sorted(), ["1", "2"])

        // Anführungszeichen/Operatoren dürfen die FTS-Syntax nicht sprengen.
        let weird = try await store.searchContent(query: #""ne" OR *"#, bookId: nil)
        XCTAssertNotNil(weird)
        let blank = try await store.searchContent(query: "   ", bookId: nil)
        XCTAssertTrue(blank.isEmpty)
    }

    func testSearchFollowsEdits() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>Anfangs stand hier Nebel</p>", baseUpdatedAt: nil)
        let before = try await store.searchContent(query: "nebel", bookId: nil)
        XCTAssertEqual(before, ["1"])

        _ = try await store.save(id: "1", html: "<p>Jetzt steht hier Sonne</p>", baseUpdatedAt: nil)
        let stale = try await store.searchContent(query: "nebel", bookId: nil)
        XCTAssertTrue(stale.isEmpty, "der Index muss dem Inhalt folgen")
        let fresh = try await store.searchContent(query: "sonne", bookId: nil)
        XCTAssertEqual(fresh, ["1"])
    }

    // MARK: - Zählwerte (Seiten-Picker)

    /// Der Server-Write pflegt die Zählwerte mit, buch-skopiert abfragbar.
    func testPageStatsFollowServerWritesPerBook() async throws {
        let store = try makeStore()
        try await store.applyServerPage(id: "1", html: "<p>Ein kurzer Satz</p>", pageName: "A",
                                        bookId: 7, chapterId: nil, serverUpdatedAtMillis: 1_000)
        try await store.applyServerPage(id: "2", html: "<p>Andere Seite</p>", pageName: "B",
                                        bookId: 9, chapterId: nil, serverUpdatedAtMillis: 1_000)

        let inSeven = try await store.pageStats(bookId: 7)
        XCTAssertEqual(inSeven.keys.sorted(), ["1"])
        XCTAssertEqual(inSeven["1"], PageMetrics.counts(html: "<p>Ein kurzer Satz</p>"))
        XCTAssertEqual(inSeven["1"]?.words, 3)

        let global = try await store.pageStats(bookId: nil)
        XCTAssertEqual(global.keys.sorted(), ["1", "2"])
    }

    /// Ein lokaler Save aktualisiert die Zahlen — sonst zeigte der Picker den
    /// Umfang von gestern.
    func testPageStatsFollowLocalEdits() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>drei kleine Wörter</p>", baseUpdatedAt: nil)
        let before = try await store.pageStats(bookId: nil)
        XCTAssertEqual(before["1"]?.words, 3)

        _ = try await store.save(id: "1", html: "<p>eins</p>", baseUpdatedAt: nil)
        let after = try await store.pageStats(bookId: nil)
        XCTAssertEqual(after["1"]?.words, 1)
        XCTAssertEqual(after["1"]?.chars, 4)
    }

    /// Alt-Bestand ohne gerechnete Zählwerte (Spalten NULL, wie direkt nach der
    /// Migration) wird beim Öffnen der DB nachgetragen.
    func testPageStatsBackfillOnOpen() async throws {
        let store = try makeStore()
        try await store.applyServerPage(id: "1", html: "<p>Hallo Welt</p>", pageName: "A",
                                        bookId: 7, chapterId: nil, serverUpdatedAtMillis: 1_000)
        // Zustand direkt nach der Migration nachstellen: Spalten auf NULL, an der
        // DB vorbei (der Store selbst hat dafür bewusst keine API).
        let raw = try DatabaseQueue(path: dbURL.path)
        try await raw.write { db in
            try db.execute(sql: "UPDATE page SET charCount = NULL, wordCount = NULL")
        }
        let cleared = try await store.pageStats(bookId: nil)
        XCTAssertTrue(cleared.isEmpty, "ohne Zählwerte liefert der Store nichts (Picker zeigt „—“)")

        let reopened = try makeStore()
        let filled = try await reopened.pageStats(bookId: nil)
        XCTAssertEqual(filled["1"]?.words, 2)
    }

    /// Eine gelöschte Seite verschwindet mitsamt ihren Zählwerten.
    func testPageStatsDropWithDeletedPage() async throws {
        let store = try makeStore()
        _ = try await store.save(id: "1", html: "<p>weg damit</p>", baseUpdatedAt: nil)
        try await store.deletePage(id: "1")
        let stats = try await store.pageStats(bookId: nil)
        XCTAssertTrue(stats.isEmpty)
    }
}
