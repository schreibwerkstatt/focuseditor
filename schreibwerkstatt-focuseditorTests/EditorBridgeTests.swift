//
//  EditorBridgeTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Unit-Tests der Bridge-Dispatch (`EditorBridge.route`) — die EINZIGE
//  Kopplungsschicht WebView ⇄ Swift-Kern. Treibt die Ops direkt (ohne WebView/
//  `WKScriptMessage`/Netz) gegen einen reinen In-Memory-`FakeLocalStore`.
//
//  Non-hosted Logic-Bundle: EditorBridge + Abhängigkeiten (LocalStore,
//  EditorCoordinating, TypographyController, FocusController) sind direkt Mitglied
//  dieses Targets (kein @testable import). Der Store hier ist BEWUSST nicht
//  `InMemoryLocalStore` — der schriebe einen JSON-Snapshot nach Application
//  Support (Pfad der echten App) und wäre damit weder deterministisch noch
//  nebenwirkungsfrei. `FakeLocalStore` hält alles im Speicher.
//

import XCTest

/// Reiner In-Memory-Spiegel für die Tests — kein Disk-I/O, kein AppSupport.
@MainActor
private final class FakeLocalStore: LocalStore {
    var pages: [String: StoredPage] = [:]
    var outbox: [String: OutboxEntry] = [:]
    /// Merge-Ancestor je Seite (früher `SyncState.serverBaseHtml`).
    var ancestors: [String: String] = [:]
    /// Monoton hochgezählter „Server-Stempel“ (Epoch-ms-Ersatz) für deterministische
    /// `updatedAt`-Werte ohne Uhr.
    private var clock: Double = 1000

    private func tick() -> Double { clock += 1; return clock }

    func page(id: String) async throws -> StoredPage? { pages[id] }

    func list(bookId: Int?) async throws -> [PageSummary] {
        pages.values
            .filter { bookId == nil || $0.bookId == bookId }
            .map { PageSummary(id: $0.id, title: $0.title, pageName: $0.pageName,
                               bookId: $0.bookId, chapterId: $0.chapterId, updatedAt: $0.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(id: String, html: String, baseUpdatedAt: Double?) async throws -> StoredPage {
        // No-op-Guard wie die echten Stores: inhaltsgleicher Save erzeugt keinen
        // neuen Outbox-Eintrag.
        if let existing = pages[id], existing.html == html { return existing }
        let now = tick()
        let page = StoredPage(id: id, html: html, title: PageTitle.derive(from: html),
                              pageName: pages[id]?.pageName, bookId: pages[id]?.bookId,
                              chapterId: pages[id]?.chapterId, updatedAt: now,
                              baseUpdatedAt: baseUpdatedAt ?? pages[id]?.baseUpdatedAt)
        pages[id] = page
        outbox[id] = OutboxEntry(pageId: id, html: html, baseUpdatedAt: page.baseUpdatedAt, queuedAt: now)
        return page
    }

    func searchContent(query: String, bookId: Int?) async throws -> [String] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return pages.values
            .filter { bookId == nil || $0.bookId == bookId }
            .filter { p in
                let hay = PageText.plain(html: p.html, pageName: p.pageName).lowercased()
                return terms.allSatisfy { hay.contains($0) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.id)
    }

    func pageStats(bookId: Int?) async throws -> [String: PageStats] {
        var out: [String: PageStats] = [:]
        for page in pages.values where bookId == nil || page.bookId == bookId {
            out[page.id] = PageMetrics.counts(html: page.html)
        }
        return out
    }

    func pendingOutbox() async throws -> [OutboxEntry] {
        outbox.values.sorted { $0.queuedAt < $1.queuedAt }
    }

    @discardableResult
    func markPushed(id: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws -> Bool {
        guard let e = outbox[id], e.queuedAt == queuedAt else { return false }
        outbox[id] = nil
        pages[id]?.baseUpdatedAt = serverUpdatedAtMillis
        return true
    }

    func applyServerPage(id: String, html: String, pageName: String?, bookId: Int?,
                         chapterId: Int?, serverUpdatedAtMillis: Double) async throws {
        pages[id] = StoredPage(id: id, html: html, title: PageTitle.derive(from: html),
                               pageName: pageName, bookId: bookId, chapterId: chapterId,
                               updatedAt: serverUpdatedAtMillis, baseUpdatedAt: serverUpdatedAtMillis)
    }

    @discardableResult
    func applyServerPageIfClean(id: String, html: String, pageName: String?, bookId: Int?,
                                chapterId: Int?, serverUpdatedAtMillis: Double) async throws -> Bool {
        if outbox[id] != nil { return false }
        try await applyServerPage(id: id, html: html, pageName: pageName, bookId: bookId,
                                  chapterId: chapterId, serverUpdatedAtMillis: serverUpdatedAtMillis)
        return true
    }

    func serverBaseHtml(id: String) async throws -> String? { ancestors[id] }

    func setServerBaseHtml(_ html: String?, id: String) async throws {
        guard pages[id] != nil else { return }
        ancestors[id] = html
    }

    func deletePage(id: String) async throws { pages[id] = nil; outbox[id] = nil; ancestors[id] = nil }

    func pageIdsWithoutBook() async throws -> [String] {
        pages.values.filter { $0.bookId == nil }.map(\.id)
    }

    func assignBook(pageId: String, bookId: Int, chapterId: Int?) async throws {
        guard pages[pageId] != nil else { return }
        pages[pageId]?.bookId = bookId
        if let chapterId { pages[pageId]?.chapterId = chapterId }
    }

    func switchToCurrentServer() async throws {}
}

@MainActor
final class EditorBridgeTests: XCTestCase {

    private func makeBridge() -> (EditorBridge, FakeLocalStore) {
        let store = FakeLocalStore()
        // Ohne APIClient: die Spellcheck-/Nachlade-Pfade laufen offline-still,
        // die hier getesteten lokalen Ops brauchen kein Netz.
        let bridge = EditorBridge(store: store)
        return (bridge, store)
    }

    // MARK: save → LocalStore + Outbox

    func testSaveCreatesPageAndOutboxEntry() async throws {
        let (bridge, store) = makeBridge()
        let result = try await bridge.route(op: "save",
                                            params: ["pageId": "p1", "html": "<p>Hallo</p>"])
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["id"] as? String, "p1")

        XCTAssertEqual(store.pages["p1"]?.html, "<p>Hallo</p>", "Save muss local-first spiegeln")
        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.map(\.pageId), ["p1"], "Save muss genau einen Outbox-Eintrag anlegen")
    }

    func testSaveIdenticalHtmlIsNoOp() async throws {
        let (bridge, store) = makeBridge()
        _ = try await bridge.route(op: "save", params: ["pageId": "p1", "html": "<p>x</p>"])
        // Ersten (echten) Eintrag quittieren, dann inhaltsgleich erneut speichern.
        let pendingBefore = try await store.pendingOutbox()
        let first = try XCTUnwrap(pendingBefore.first)
        try await store.markPushed(id: "p1", queuedAt: first.queuedAt, serverUpdatedAtMillis: 9999)
        _ = try await bridge.route(op: "save", params: ["pageId": "p1", "html": "<p>x</p>"])
        let afterPending = try await store.pendingOutbox()
        XCTAssertTrue(afterPending.isEmpty,
                      "Inhaltsgleicher Save darf keinen neuen Outbox-Eintrag erzeugen")
    }

    func testSaveMissingHtmlThrows() async throws {
        let (bridge, _) = makeBridge()
        await assertThrowsBridgeError(missingParam: "html") {
            _ = try await bridge.route(op: "save", params: ["pageId": "p1"])
        }
    }

    // MARK: load → local-first

    func testLoadReturnsMirroredPage() async throws {
        let (bridge, store) = makeBridge()
        try await store.applyServerPage(id: "p7", html: "<p>Server</p>", pageName: "S7",
                                        bookId: 3, chapterId: nil, serverUpdatedAtMillis: 42)
        let result = try await bridge.route(op: "load", params: ["pageId": "p7"])
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["id"] as? String, "p7")
        XCTAssertEqual(dict["html"] as? String, "<p>Server</p>")
    }

    func testLoadUnknownWithoutApiReturnsNil() async throws {
        let (bridge, _) = makeBridge()
        // Kein lokaler Spiegel, kein APIClient → still nil (kein Fehler).
        let result = try await bridge.route(op: "load", params: ["pageId": "ghost"])
        XCTAssertNil(result)
    }

    func testLoadMissingPageIdThrows() async throws {
        let (bridge, _) = makeBridge()
        await assertThrowsBridgeError(missingParam: "pageId") {
            _ = try await bridge.route(op: "load", params: [:])
        }
    }

    // MARK: list → Buch-Filter

    func testListFiltersByBook() async throws {
        let (bridge, store) = makeBridge()
        try await store.applyServerPage(id: "a", html: "<p>a</p>", pageName: nil, bookId: 1, chapterId: nil, serverUpdatedAtMillis: 1)
        try await store.applyServerPage(id: "b", html: "<p>b</p>", pageName: nil, bookId: 2, chapterId: nil, serverUpdatedAtMillis: 2)

        let allResult = try await bridge.route(op: "list", params: [:])
        let all = try XCTUnwrap(allResult as? [[String: Any]])
        XCTAssertEqual(all.count, 2)

        let book1Result = try await bridge.route(op: "list", params: ["bookId": 1])
        let book1 = try XCTUnwrap(book1Result as? [[String: Any]])
        XCTAssertEqual(book1.map { $0["id"] as? String }, ["a"])
    }

    // MARK: editorState → Dirty-Tracking + openPageId

    func testEditorStateTracksDirtyAndOpenPage() async throws {
        let (bridge, _) = makeBridge()
        _ = try await bridge.route(op: "editorState", params: ["pageId": "p1", "dirty": true])
        XCTAssertEqual(bridge.openPageId, "p1")
        XCTAssertTrue(bridge.isDirty("p1"), "dirty=true muss die Seite als dirty markieren")

        _ = try await bridge.route(op: "editorState", params: ["pageId": "p1", "dirty": false])
        XCTAssertFalse(bridge.isDirty("p1"), "dirty=false muss das Flag löschen")
    }

    func testEditorStateNotifiesDirtyChange() async throws {
        let (bridge, _) = makeBridge()
        var received: [Bool] = []
        bridge.onOpenDirtyChange = { received.append($0) }
        _ = try await bridge.route(op: "editorState", params: ["pageId": "p1", "dirty": true])
        _ = try await bridge.route(op: "editorState", params: ["pageId": "p1", "dirty": false])
        XCTAssertEqual(received, [true, false], "Save-Indikator muss bei echten Wechseln feuern")
    }

    // MARK: reportStats → Callback

    func testReportStatsForwardsToCallback() async throws {
        let (bridge, _) = makeBridge()
        var seen: (String?, Int, Int)?
        bridge.onStats = { seen = ($0, $1, $2); _ = $3 }
        _ = try await bridge.route(op: "reportStats",
                                   params: ["pageId": "p1", "words": 12, "chars": 80])
        XCTAssertEqual(seen?.0, "p1")
        XCTAssertEqual(seen?.1, 12)
        XCTAssertEqual(seen?.2, 80)
    }

    // MARK: Boot-Pull-Ops

    func testFocusGranularityIsReturned() async throws {
        let (bridge, _) = makeBridge()
        let result = try await bridge.route(op: "focusGranularity", params: [:])
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertNotNil(dict["granularity"] as? String)
    }

    // MARK: Verzögerter Spellcheck-Nachzug (Offline-Boot-Lücke)

    /// Ohne verbundene WebView ist der Swift→JS-Kanal nicht verfügbar → die
    /// Methode ist no-op. Wichtig: `spellcheckDeferredDone` bleibt false
    /// (die Fn wurde ja nicht gerufen), damit der nächste Sync-Tick erneut
    /// probiert. Verhindert, dass ein Boot-Race (WebView/Boot-Modul noch
    /// nicht bereit) das Nachziehen permanent verpasst.
    func testPushDeferredSpellcheckInitNoOpWithoutWebView() async throws {
        let (bridge, _) = makeBridge()
        XCTAssertFalse(bridge.spellcheckDeferredDone, "Flag Default false")
        await bridge.pushDeferredSpellcheckInit()
        XCTAssertFalse(bridge.spellcheckDeferredDone,
                       "ohne WebView darf das Flag nicht gesetzt werden (nächster Tick retry)")
    }

    /// Server-Wechsel gibt den Sitzungs-Versuch wieder frei — Boot-Config
    /// des alten Servers könnte `enabled:false` geliefert haben; der neue
    /// Server bekommt einen frischen Versuch. Manuell-True setzen → reset →
    /// wieder frei.
    func testResetSpellcheckDeferredClearsFlag() async {
        let (bridge, _) = makeBridge()
        bridge.spellcheckDeferredDone = true
        bridge.resetSpellcheckDeferred()
        XCTAssertFalse(bridge.spellcheckDeferredDone,
                       "resetSpellcheckDelayed muss das Flag wieder freigeben")
    }

    // MARK: Härtung — Eingangs-Validierung (params kommt aus der WebView)

    /// Seiten-IDs landen im URL-Pfad des Server-Nachladens, in UserDefaults-Keys
    /// und im Log → Pfadtrenner/Traversal/Steuerzeichen müssen abgewiesen werden.
    func testLoadRejectsMalformedPageId() async throws {
        let (bridge, _) = makeBridge()
        for bad in ["../secret", "a/b", "", String(repeating: "9", count: 200), "p 1", "p\n1"] {
            await assertThrowsBridgeError(invalidOrMissing: "pageId") {
                _ = try await bridge.route(op: "load", params: ["pageId": bad])
            }
        }
    }

    /// Absurd grosse Bodies werden abgelehnt, statt den Spiegel aufzublasen.
    /// Kein Datenverlust: der Text bleibt im DOM, der Editor sieht den Fehler.
    func testSaveRejectsOversizedHtml() async throws {
        let (bridge, store) = makeBridge()
        let huge = String(repeating: "x", count: EditorBridge.maxHtmlLength + 1)
        await assertThrowsBridgeError(invalidOrMissing: "html") {
            _ = try await bridge.route(op: "save", params: ["pageId": "p1", "html": huge])
        }
        XCTAssertNil(store.pages["p1"], "abgewiesener Save darf nichts spiegeln")
    }

    /// Leeres HTML ist ein legitimer Zustand (Seite geleert) — der Deckel darf
    /// das nicht mitverbieten.
    func testSaveAcceptsEmptyHtml() async throws {
        let (bridge, store) = makeBridge()
        _ = try await bridge.route(op: "save", params: ["pageId": "p1", "html": ""])
        XCTAssertEqual(store.pages["p1"]?.html, "")
    }

    /// Ein NaN/negativer `baseUpdatedAt` würde jeden Konflikt-Vergleich des Syncs
    /// verbiegen → wird verworfen (Save läuft ohne Basis weiter).
    func testSaveDropsNonFiniteBaseUpdatedAt() async throws {
        let (bridge, store) = makeBridge()
        _ = try await bridge.route(op: "save",
                                   params: ["pageId": "p1", "html": "<p>x</p>",
                                            "baseUpdatedAt": Double.nan])
        XCTAssertNil(store.pages["p1"]?.baseUpdatedAt, "NaN-Basis darf nicht in den Store")

        _ = try await bridge.route(op: "save",
                                   params: ["pageId": "p2", "html": "<p>y</p>",
                                            "baseUpdatedAt": 4242.0])
        XCTAssertEqual(store.pages["p2"]?.baseUpdatedAt, 4242.0, "gültige Basis muss durchgehen")
    }

    /// Unsinnige Zahlen aus der WebView dürfen die Schreibstatistik nicht vergiften.
    func testReportStatsClampsJunkNumbers() async throws {
        let (bridge, _) = makeBridge()
        var seen: (String?, Int, Int)?
        bridge.onStats = { seen = ($0, $1, $2); _ = $3 }
        _ = try await bridge.route(op: "reportStats",
                                   params: ["words": Double.nan, "chars": -5])
        XCTAssertEqual(seen?.1, 0)
        XCTAssertEqual(seen?.2, 0)
    }

    /// Eine kaputte ID gilt als „keine Seite offen" — sie darf nicht in den
    /// Boot-Restore-Merker geraten (sonst öffnete der Start dauerhaft Unsinn).
    func testEditorStateIgnoresMalformedPageId() async throws {
        let (bridge, _) = makeBridge()
        _ = try await bridge.route(op: "editorState",
                                   params: ["pageId": "../evil", "dirty": true])
        XCTAssertNil(bridge.openPageId)
        XCTAssertFalse(bridge.isDirty("../evil"))
    }

    /// Der Editor hält immer genau EINE Seite offen: das Dirty-Flag der vorher
    /// offenen Seite darf nicht stehenbleiben, sonst blockierte es deren stillen
    /// Server-Reload dauerhaft.
    func testEditorStateDropsDirtyFlagOfPreviousPage() async throws {
        let (bridge, _) = makeBridge()
        _ = try await bridge.route(op: "editorState", params: ["pageId": "p1", "dirty": true])
        _ = try await bridge.route(op: "editorState", params: ["pageId": "p2", "dirty": false])
        XCTAssertFalse(bridge.isDirty("p1"), "Flag der nicht mehr offenen Seite muss fallen")
        XCTAssertEqual(bridge.openPageId, "p2")
    }

    /// Unsinnige Buch-IDs (0, negativ, Bruch, Text) bedeuten „kein Filter" —
    /// nie ein wild interpretierter Wert.
    func testListIgnoresInvalidBookId() async throws {
        let (bridge, store) = makeBridge()
        try await store.applyServerPage(id: "a", html: "<p>a</p>", pageName: nil, bookId: 1,
                                        chapterId: nil, serverUpdatedAtMillis: 1)
        for bad: Any in [0, -3, 1.5, "keins"] {
            let result = try await bridge.route(op: "list", params: ["bookId": bad])
            let rows = try XCTUnwrap(result as? [[String: Any]])
            XCTAssertEqual(rows.count, 1, "ungültige bookId darf nicht filtern (\(bad))")
        }
    }

    /// Die MRU-Historie kommt aus UserDefaults (ältere Version, Absturz, Handarbeit)
    /// → verbogene Einträge und Dubletten werden beim Lesen ausgesiebt.
    func testRecentPageIdsSkipsCorruptEntries() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bridge.recents.test"))
        defaults.removePersistentDomain(forName: "bridge.recents.test")
        defaults.set(["7": ["p1", "p1", "../evil", "", "p2"]],
                     forKey: EditorBridge.recentPagesByBookKey)
        XCTAssertEqual(EditorBridge.recentPageIds(forBook: 7, defaults: defaults), ["p1", "p2"])

        EditorBridge.pushRecentPageId("a/b", forBook: 7, defaults: defaults)
        XCTAssertEqual(EditorBridge.recentPageIds(forBook: 7, defaults: defaults), ["p1", "p2"],
                       "ungültige ID darf nicht in die Historie wandern")
        defaults.removePersistentDomain(forName: "bridge.recents.test")
    }

    // MARK: Unbekannte Op

    func testUnknownOpThrows() async throws {
        let (bridge, _) = makeBridge()
        do {
            _ = try await bridge.route(op: "doesNotExist", params: [:])
            XCTFail("unbekannte Op muss werfen")
        } catch let BridgeError.unknownOp(op) {
            XCTAssertEqual(op, "doesNotExist")
        }
    }

    // MARK: Hilfe

    /// Erwartet `BridgeError.missingParam(key)` aus dem `body`.
    private func assertThrowsBridgeError(missingParam key: String,
                                         _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("erwarteter BridgeError.missingParam(\(key)) blieb aus")
        } catch let BridgeError.missingParam(k) {
            XCTAssertEqual(k, key)
        } catch {
            XCTFail("falscher Fehler: \(error)")
        }
    }

    /// Erwartet `BridgeError.missingParam(key)` ODER `.invalidParam(key, …)` —
    /// für die Härtungs-Tests, wo je nach Eingabe das eine oder andere greift
    /// (fehlender vs. formal kaputter Wert).
    private func assertThrowsBridgeError(invalidOrMissing key: String,
                                        _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("erwarteter BridgeError für '\(key)' blieb aus")
        } catch let BridgeError.invalidParam(k, _) {
            XCTAssertEqual(k, key)
        } catch let BridgeError.missingParam(k) {
            XCTAssertEqual(k, key)
        } catch {
            XCTFail("falscher Fehler: \(error)")
        }
    }
}
