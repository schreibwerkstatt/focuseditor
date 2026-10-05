//
//  SyncEngineTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Isolierte Unit-Tests des SyncEngine-Kerns (Push/409-Merge/Pull/Cursor/
//  Delete-Reconcile) — ohne laufenden Server. Der `APIClient` bekommt eine
//  `URLSession` mit `MockURLProtocol`, die HTTP-Antworten deterministisch stubbt
//  (Status + JSON, pro Route eine Sequenz). LocalStore + Editor sind In-Memory-
//  Fakes. So sind genau die datenverlust-kritischen Pfade testbar, die der
//  Live-Integrationstest (SyncIntegrationTests) nur gegen einen echten Server
//  abdeckt.
//
//  Non-hosted Logic-Bundle: die getesteten Quellen (SyncEngine[+Push/+Pull],
//  APIClient, ContentAPI, Reachability, SyncPreferences, SyncModels, SyncState,
//  LocalStore, …) sind direkt Mitglied des Test-Targets (kein @testable import)
//  → `internal` Member wie `pushOutbox()`/`pullDeltas()` sind hier aufrufbar.
//

import XCTest

// MARK: - HTTP-Stub (URLProtocol)

/// Eine gestubbte Antwort: Status + JSON-Body.
private struct Stub {
    let status: Int
    let json: String
}

/// Routet Requests auf vorbereitete Antwort-Sequenzen, gekeyt nach
/// „METHOD path" (Query bleibt aussen vor). Pro Route eine Liste: jeder Aufruf
/// nimmt den nächsten Eintrag; ist die Liste erschöpft, wird der letzte Eintrag
/// wiederholt (so braucht ein wiederholt gepollter Endpoint nur einen Stub).
/// Treibt den projektweit geteilten `MockURLProtocol` (Definition in
/// APIClientTests) über dessen `handler`-Closure.
private final class StubRouter: @unchecked Sendable {
    private var routes: [String: [Stub]] = [:]
    private let lock = NSLock()

    func on(_ method: String, _ path: String, _ stubs: [Stub]) {
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(path)"] = stubs
    }

    func next(method: String, path: String) -> Stub? {
        lock.lock(); defer { lock.unlock() }
        let key = "\(method) \(path)"
        guard var arr = routes[key], !arr.isEmpty else { return nil }
        let s = arr.removeFirst()
        routes[key] = arr.isEmpty ? [s] : arr   // erschöpft → letzten wiederholen
        return s
    }

    /// Verdrahtet diesen Router als `MockURLProtocol.handler`.
    func install() {
        MockURLProtocol.handler = { [weak self] request in
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            guard let stub = self?.next(method: method, path: path), let url = request.url else {
                throw URLError(.unsupportedURL)
            }
            let resp = HTTPURLResponse(url: url, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, Data(stub.json.utf8))
        }
    }
}

// MARK: - In-Memory-Fakes

@MainActor
private final class FakeStore: LocalStore {
    var pages: [String: StoredPage] = [:]
    var outbox: [String: OutboxEntry] = [:]
    /// Merge-Ancestor je Seite (früher `SyncState.serverBaseHtml`).
    var ancestors: [String: String] = [:]
    private var clock: Double = 1000
    private func tick() -> Double { clock += 1; return clock }

    /// Test-Helfer: einen sauberen Server-Stand setzen (kein Outbox-Eintrag).
    func seedServerPage(id: String, html: String, bookId: Int?, updatedAt: Double) {
        pages[id] = StoredPage(id: id, html: html, title: PageTitle.derive(from: html),
                               pageName: nil, bookId: bookId, chapterId: nil,
                               updatedAt: updatedAt, baseUpdatedAt: updatedAt)
    }

    func page(id: String) async throws -> StoredPage? { pages[id] }

    func list(bookId: Int?) async throws -> [PageSummary] {
        pages.values
            .filter { bookId == nil || $0.bookId == bookId }
            .map { PageSummary(id: $0.id, title: $0.title, pageName: $0.pageName,
                               bookId: $0.bookId, chapterId: $0.chapterId, updatedAt: $0.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func searchContent(query: String, bookId: Int?) async throws -> [String] { [] }

    func pageStats(bookId: Int?) async throws -> [String: PageStats] {
        var out: [String: PageStats] = [:]
        for page in pages.values where bookId == nil || page.bookId == bookId {
            out[page.id] = PageMetrics.counts(html: page.html)
        }
        return out
    }

    func save(id: String, html: String, baseUpdatedAt: Double?) async throws -> StoredPage {
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
                               pageName: pageName ?? pages[id]?.pageName,
                               bookId: bookId ?? pages[id]?.bookId,
                               chapterId: chapterId ?? pages[id]?.chapterId,
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
        // Wie die echten Stores: der Ancestor hängt an der gespiegelten Seite.
        guard pages[id] != nil else { return }
        ancestors[id] = html
    }

    func deletePage(id: String) async throws { pages[id] = nil; outbox[id] = nil; ancestors[id] = nil }
    func pageIdsWithoutBook() async throws -> [String] { pages.values.filter { $0.bookId == nil }.map(\.id) }
    func assignBook(pageId: String, bookId: Int, chapterId: Int?) async throws {
        guard var p = pages[pageId] else { return }
        p.bookId = bookId; if let chapterId { p.chapterId = chapterId }; pages[pageId] = p
    }
    func switchToCurrentServer() async throws {}
}

@MainActor
private final class FakeEditor: EditorCoordinating {
    var openPageId: String?
    var dirtyPages: Set<String> = []
    var mergeResult: MergeOutcome?
    var mergeError: Error?
    /// Test-Hook: läuft INNERHALB von `merge3`, bevor das Ergebnis zurückkommt —
    /// simuliert einen lokalen Save, der WÄHREND der Konflikt-Auflösung eintrifft.
    var onMerge: (() async -> Void)?
    private(set) var reloaded: [(pageId: String, html: String)] = []

    func isDirty(_ pageId: String) -> Bool { dirtyPages.contains(pageId) }
    /// Test-Hook: lehnt der Editor den stillen Reload ab (inzwischen getippt)?
    var declineReload = false
    func reloadPage(pageId: String, html: String, baseUpdatedAt: Double, force: Bool) async -> Bool {
        if declineReload && !force { return false }
        reloaded.append((pageId, html))
        return true
    }
    func merge3(base: String?, local: String, server: String) async throws -> MergeOutcome {
        await onMerge?()
        if let mergeError { throw mergeError }
        return mergeResult ?? MergeOutcome(merged: local, conflictCount: 0)
    }
    func flushDraftSave() async {}
}

// MARK: - Tests

@MainActor
final class SyncEngineTests: XCTestCase {

    private let base = "2026-01-01T00:00:00.000Z"
    private let newer = "2026-01-02T00:00:00.000Z"
    private var router = StubRouter()

    override func setUp() {
        super.setUp()
        router = StubRouter()
        router.install()
        // Eigener Server-Namespace → isolierte Persistenz; den Sync-Zustand vorher
        // löschen, damit kein Lauf den Cursor/die Basis eines früheren erbt.
        ServerConfig.baseURLString = "http://synctest.local"
        try? FileManager.default.removeItem(
            at: AppSupport.serverDir().appendingPathComponent("syncstate.json"))
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeEngine(store: FakeStore, editor: EditorCoordinating? = nil) -> SyncEngine {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(tokenProvider: { "swd_test" }, session: URLSession(configuration: cfg))
        let engine = SyncEngine(api: api, content: ContentAPI(api: api), store: store,
                                reachability: nil, shouldSync: { true })
        engine.editor = editor
        // Sync-Zustand frisch (setUp löscht die Datei, aber der Store lädt im init).
        engine.stateStore.mutate { $0 = SyncState() }
        return engine
    }

    /// Wie `makeEngine`, aber OHNE den Sync-Zustand zu leeren — die neue Engine
    /// liest den auf der Platte persistierten Zustand (für den Neustart-Roundtrip,
    /// z. B. Konflikt-Persistenz). Kein Editor/keine Stubs nötig.
    private func makeEngineKeepingState(store: FakeStore) -> SyncEngine {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(tokenProvider: { "swd_test" }, session: URLSession(configuration: cfg))
        return SyncEngine(api: api, content: ContentAPI(api: api), store: store,
                          reachability: nil, shouldSync: { true })
    }

    private func push(_ status: Int, _ json: String) -> Stub { Stub(status: status, json: json) }

    // MARK: Push

    func testPushSuccessAdvancesBaseAndDrainsOutbox() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>local</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)
        engine.stateStore.mutate { $0.serverBaseISO["5"] = base }
        router.on("PUT", "/content/pages/5",
                                  [push(200, #"{"id":5,"updated_at":"\#(newer)"}"#)])

        try await engine.pushOutbox()

        let pending = try await store.pendingOutbox()
        XCTAssertTrue(pending.isEmpty, "Outbox sollte nach 200 geleert sein")
        XCTAssertEqual(engine.stateStore.state.serverBaseISO["5"], newer, "Basis auf Server-ISO vorgerückt")
        let ancestor = try await store.serverBaseHtml(id: "5")
        XCTAssertEqual(ancestor, "<p>local</p>", "Merge-Ancestor = gepushtes HTML (jetzt im Store, nicht im SyncState)")
        XCTAssertTrue(engine.conflicts.isEmpty)
    }

    func testPushWithoutBaseButWithBookIsSkippedSilently() async throws {
        let store = FakeStore()
        store.seedServerPage(id: "5", html: "<p>x</p>", bookId: 1, updatedAt: 1)
        _ = try await store.save(id: "5", html: "<p>local</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)
        // KEINE serverBaseISO → Seite ist nur noch nicht gepullt (hat aber ein Buch).

        try await engine.pushOutbox()

        XCTAssertTrue(engine.conflicts.isEmpty, "Seite mit Buch ohne Basis → still überspringen, kein Konflikt")
        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.map(\.pageId), ["5"], "Outbox bleibt erhalten")
    }

    func testPushOrphanWithoutBaseRecordsConflict() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>local</p>", baseUpdatedAt: nil)  // bookId nil
        let engine = makeEngine(store: store)

        try await engine.pushOutbox()

        XCTAssertEqual(engine.conflicts.map(\.pageId), ["5"], "Waise ohne Buch & Basis → sichtbarer Konflikt")
    }

    func testPush404ClearsBaseAndRecordsConflict() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>local</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)
        engine.stateStore.mutate { $0.serverBaseISO["5"] = base }
        router.on("PUT", "/content/pages/5",
                                  [push(404, #"{"error_code":"PAGE_NOT_FOUND"}"#)])

        try await engine.pushOutbox()

        XCTAssertNil(engine.stateStore.state.serverBaseISO["5"], "404 verwirft die Basis")
        XCTAssertEqual(engine.conflicts.map(\.pageId), ["5"])
    }

    func testPush409WithoutEditorRecordsConflictFromBody() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>local</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)   // kein Editor → nicht auto-mergebar
        engine.stateStore.mutate { $0.serverBaseISO["5"] = base }
        router.on("PUT", "/content/pages/5", [push(409,
            #"{"error_code":"PAGE_CONFLICT","server_updated_at":"\#(newer)","server_editor_name":"Bob"}"#)])

        try await engine.pushOutbox()

        XCTAssertEqual(engine.conflicts.count, 1)
        XCTAssertEqual(engine.conflicts.first?.serverEditorName, "Bob")
        XCTAssertEqual(engine.conflicts.first?.serverUpdatedAt, newer)
    }

    func testPush409CleanMergeRePushesAndClears() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>local</p>", baseUpdatedAt: nil)
        let editor = FakeEditor()
        editor.mergeResult = MergeOutcome(merged: "<p>merged</p>", conflictCount: 0)
        let engine = makeEngine(store: store, editor: editor)
        engine.stateStore.mutate { $0.serverBaseISO["5"] = base }
        store.ancestors["5"] = "<p>ancestor</p>"
        let merged = "2026-01-03T00:00:00.000Z"
        router.on("PUT", "/content/pages/5", [
            push(409, #"{"error_code":"PAGE_CONFLICT","server_updated_at":"\#(newer)"}"#),
            push(200, #"{"id":5,"updated_at":"\#(merged)"}"#),
        ])
        router.on("GET", "/content/pages/5",
                                  [push(200, #"{"id":5,"updated_at":"\#(newer)","html":"<p>server</p>"}"#)])

        try await engine.pushOutbox()

        XCTAssertTrue(engine.conflicts.isEmpty, "Kollisionsfreier Auto-Merge → kein sichtbarer Konflikt")
        let pending = try await store.pendingOutbox()
        XCTAssertTrue(pending.isEmpty, "gemergter Stand wurde gepusht + quittiert")
        XCTAssertEqual(engine.stateStore.state.serverBaseISO["5"], merged, "Basis = ISO des Merge-Pushes")
        XCTAssertEqual(store.pages["5"]?.html, "<p>merged</p>", "lokaler Stand = Merge-Ergebnis")
    }

    func testPush409RealCollisionRecordsConflict() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>local</p>", baseUpdatedAt: nil)
        let editor = FakeEditor()
        editor.mergeResult = MergeOutcome(merged: "<p>x</p>", conflictCount: 2)   // echte Kollision
        let engine = makeEngine(store: store, editor: editor)
        engine.stateStore.mutate { $0.serverBaseISO["5"] = base }
        router.on("PUT", "/content/pages/5",
                                  [push(409, #"{"error_code":"PAGE_CONFLICT","server_updated_at":"\#(newer)"}"#)])
        router.on("GET", "/content/pages/5",
                                  [push(200, #"{"id":5,"updated_at":"\#(newer)","html":"<p>server</p>"}"#)])

        try await engine.pushOutbox()

        XCTAssertEqual(engine.conflicts.map(\.pageId), ["5"], "Block-Kollision → Konflikt-UI nötig")
        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.map(\.pageId), ["5"], "lokaler Stand bleibt (kein Datenverlust)")
    }

    // MARK: Pull

    func testPullAppliesServerPageAndAdvancesCursor() async throws {
        let store = FakeStore()
        let engine = makeEngine(store: store)
        seedBook(engine, ids: [1])
        router.on("GET", "/content/books/1/sync", [push(200, #"""
            {"now":"\#(newer)","has_more":false,"cursor":{"since":"\#(newer)","since_id":7},
             "pages":[{"page_id":7,"page_name":"P7","chapter_id":null,"updated_at":"\#(newer)","html":"<p>server7</p>"}]}
            """#)])

        try await engine.pullDeltas()

        XCTAssertEqual(store.pages["7"]?.html, "<p>server7</p>", "Server-Seite übernommen")
        XCTAssertEqual(store.pages["7"]?.bookId, 1, "Buch-Zuordnung aus dem Pull")
        XCTAssertEqual(engine.stateStore.state.serverBaseISO["7"], newer)
        XCTAssertEqual(engine.stateStore.state.cursors[1], SyncCursorDTO(since: newer, since_id: 7))
    }

    func testPullSkipsEchoOfOwnEdit() async throws {
        let store = FakeStore()
        let engine = makeEngine(store: store)
        seedBook(engine, ids: [1])
        // Basis steht bereits auf genau diesem Server-Stempel → Echo, nicht anwenden.
        engine.stateStore.mutate { $0.serverBaseISO["7"] = newer }
        router.on("GET", "/content/books/1/sync", [push(200, #"""
            {"now":"\#(newer)","has_more":false,"cursor":{"since":"\#(newer)","since_id":7},
             "pages":[{"page_id":7,"page_name":"P7","chapter_id":null,"updated_at":"\#(newer)","html":"<p>echo</p>"}]}
            """#)])

        try await engine.pullDeltas()

        XCTAssertNil(store.pages["7"], "Echo (gleicher Stempel) wird nicht in den Store gemergt")
        XCTAssertEqual(engine.stateStore.state.cursors[1]?.since_id, 7, "Cursor rückt trotzdem vor")
    }

    func testPullDoesNotOverwritePendingLocalChange() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "7", html: "<p>local-unpushed</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)
        seedBook(engine, ids: [1])
        router.on("GET", "/content/books/1/sync", [push(200, #"""
            {"now":"\#(newer)","has_more":false,"cursor":{"since":"\#(newer)","since_id":7},
             "pages":[{"page_id":7,"page_name":"P7","chapter_id":null,"updated_at":"\#(newer)","html":"<p>server</p>"}]}
            """#)])

        try await engine.pullDeltas()

        XCTAssertEqual(store.pages["7"]?.html, "<p>local-unpushed</p>", "ungepushte lokale Änderung bleibt unangetastet")
        XCTAssertNil(engine.stateStore.state.serverBaseISO["7"], "Basis NICHT vorgerückt (Push löst per 409)")
    }

    func testPullPagesThroughCursorUntilExhausted() async throws {
        let store = FakeStore()
        let engine = makeEngine(store: store)
        seedBook(engine, ids: [1])
        let mid = "2026-01-02T12:00:00.000Z"
        router.on("GET", "/content/books/1/sync", [
            push(200, #"""
                {"now":"\#(newer)","has_more":true,"cursor":{"since":"\#(mid)","since_id":7},
                 "pages":[{"page_id":7,"page_name":"P7","chapter_id":null,"updated_at":"\#(mid)","html":"<p>s7</p>"}]}
                """#),
            push(200, #"""
                {"now":"\#(newer)","has_more":false,"cursor":{"since":"\#(newer)","since_id":8},
                 "pages":[{"page_id":8,"page_name":"P8","chapter_id":null,"updated_at":"\#(newer)","html":"<p>s8</p>"}]}
                """#),
        ])

        try await engine.pullDeltas()

        XCTAssertEqual(store.pages["7"]?.html, "<p>s7</p>")
        XCTAssertEqual(store.pages["8"]?.html, "<p>s8</p>", "zweite Seite kam über das Paging")
        XCTAssertEqual(engine.stateStore.state.cursors[1], SyncCursorDTO(since: newer, since_id: 8))
    }

    // MARK: Delete-Reconcile

    func testReconcileDeletesPageMissingFromTree() async throws {
        let store = FakeStore()
        store.seedServerPage(id: "7", html: "<p>7</p>", bookId: 1, updatedAt: 1)
        store.seedServerPage(id: "8", html: "<p>8</p>", bookId: 1, updatedAt: 1)
        let engine = makeEngine(store: store)
        seedBook(engine, ids: [1])
        // Tree kennt nur Seite 7 → 8 ist serverseitig gelöscht.
        router.on("GET", "/content/books/1/tree", [push(200, #"""
            {"chapters":[],"topPages":[{"id":7,"chapter_id":null,"name":"P7","position":0,"updated_at":"\#(newer)"}]}
            """#)])

        await engine.reconcileDeletesIfDue()

        XCTAssertNotNil(store.pages["7"], "im Tree → bleibt")
        XCTAssertNil(store.pages["8"], "nicht im Tree → lokal entfernt")
    }

    func testReconcileKeepsPageWithPendingOutbox() async throws {
        let store = FakeStore()
        store.seedServerPage(id: "7", html: "<p>7</p>", bookId: 1, updatedAt: 1)
        _ = try await store.save(id: "8", html: "<p>8-local</p>", baseUpdatedAt: nil)
        store.pages["8"]?.bookId = 1   // Outbox-Seite gehört zu Buch 1
        let engine = makeEngine(store: store)
        seedBook(engine, ids: [1])
        router.on("GET", "/content/books/1/tree", [push(200, #"""
            {"chapters":[],"topPages":[{"id":7,"chapter_id":null,"name":"P7","position":0,"updated_at":"\#(newer)"}]}
            """#)])

        await engine.reconcileDeletesIfDue()

        XCTAssertNotNil(store.pages["8"], "ungepushte Änderung schützt vor Löschung (Datenverlust-Schutz)")
    }

    func testReconcileSkipsOnEmptyTree() async throws {
        let store = FakeStore()
        store.seedServerPage(id: "7", html: "<p>7</p>", bookId: 1, updatedAt: 1)
        let engine = makeEngine(store: store)
        seedBook(engine, ids: [1])
        router.on("GET", "/content/books/1/tree",
                                  [push(200, #"{"chapters":[],"topPages":[]}"#)])

        await engine.reconcileDeletesIfDue()

        XCTAssertNotNil(store.pages["7"], "leerer Tree ist verdächtig → nichts löschen")
    }

    // MARK: Robustheit / Persistenz

    /// Ein offener 409-Konflikt muss einen App-Neustart überleben (persistiert im
    /// Sync-Zustand) — sonst würde die Seite blind neu gepusht und der Nutzer
    /// verlöre die Konflikt-Spur.
    func testConflictsPersistAcrossEngineRestart() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>local</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)   // kein Editor → 409 wird sichtbarer Konflikt
        engine.stateStore.mutate { $0.serverBaseISO["5"] = base }
        router.on("PUT", "/content/pages/5", [push(409,
            #"{"error_code":"PAGE_CONFLICT","server_updated_at":"\#(newer)","server_editor_name":"Bob"}"#)])

        try await engine.pushOutbox()
        XCTAssertEqual(engine.conflicts.map(\.pageId), ["5"], "Konflikt zunächst erfasst")
        engine.stateStore.flushForTesting()   // Disk-Write abwarten (deterministisch)

        // „Neustart": frische Engine auf demselben (persistenten) Zustand.
        let restarted = makeEngineKeepingState(store: store)
        XCTAssertEqual(restarted.conflicts.map(\.pageId), ["5"], "Konflikt aus dem Zustand wiederhergestellt")
        XCTAssertEqual(restarted.conflicts.first?.serverEditorName, "Bob", "Konflikt-Metadaten erhalten")
    }

    /// Ein erfolgreicher Block-Merge muss den Konflikt auch im persistierten
    /// Zustand löschen — sonst tauchte er nach einem Neustart wieder auf.
    func testClearedConflictDoesNotResurrectAfterRestart() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>local</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)
        engine.stateStore.mutate { $0.serverBaseISO["5"] = base }
        router.on("PUT", "/content/pages/5",
                  [push(409, #"{"error_code":"PAGE_CONFLICT","server_updated_at":"\#(newer)"}"#)])
        try await engine.pushOutbox()
        XCTAssertFalse(engine.conflicts.isEmpty)

        engine.clearConflict(pageId: "5")
        engine.stateStore.flushForTesting()

        let restarted = makeEngineKeepingState(store: store)
        XCTAssertTrue(restarted.conflicts.isEmpty, "aufgelöster Konflikt bleibt nach Neustart weg")
    }

    /// Speichert der Nutzer WÄHREND eines Auto-Merges erneut, darf der jüngste
    /// lokale Stand nicht verloren gehen: der neue Outbox-Eintrag bleibt erhalten
    /// und die Basis wird NICHT auf den (überholten) Merge-Stand vorgerückt.
    func testSaveDuringAutoMergeKeepsLatestLocalEdit() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>local-1</p>", baseUpdatedAt: nil)
        let editor = FakeEditor()
        editor.mergeResult = MergeOutcome(merged: "<p>merged</p>", conflictCount: 0)
        // Während der Merge rechnet, tippt + speichert der Nutzer erneut.
        editor.onMerge = { _ = try? await store.save(id: "5", html: "<p>local-2</p>", baseUpdatedAt: nil) }
        let engine = makeEngine(store: store, editor: editor)
        engine.stateStore.mutate { $0.serverBaseISO["5"] = base }
        store.ancestors["5"] = "<p>anc</p>"
        let merged = "2026-01-03T00:00:00.000Z"
        router.on("PUT", "/content/pages/5", [
            push(409, #"{"error_code":"PAGE_CONFLICT","server_updated_at":"\#(newer)"}"#),
            push(200, #"{"id":5,"updated_at":"\#(merged)"}"#),
        ])
        router.on("GET", "/content/pages/5",
                  [push(200, #"{"id":5,"updated_at":"\#(newer)","html":"<p>server</p>"}"#)])

        try await engine.pushOutbox()

        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.map(\.pageId), ["5"], "der während des Merges gespeicherte Stand bleibt in der Outbox")
        XCTAssertEqual(pending.first?.html, "<p>local-2</p>", "der jüngste lokale Tippstand überlebt")
        XCTAssertNotEqual(engine.stateStore.state.serverBaseISO["5"], merged,
                          "Basis NICHT auf den Merge-Stand vorgerückt (Save kam dazwischen)")
    }

    /// Ein 401 mitten in der Outbox-Schleife bricht den Push ab — bereits
    /// quittierte Einträge bleiben quittiert, der Rest bleibt unangetastet
    /// (keine doppelten Pushes, keine Inkonsistenz beim Re-Sync nach Re-Login).
    func testPush401MidLoopKeepsRemainingOutboxConsistent() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>a</p>", baseUpdatedAt: nil)
        _ = try await store.save(id: "6", html: "<p>b</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)
        engine.stateStore.mutate { $0.serverBaseISO["5"] = base; $0.serverBaseISO["6"] = base }
        router.on("PUT", "/content/pages/5", [push(200, #"{"id":5,"updated_at":"\#(newer)"}"#)])
        router.on("PUT", "/content/pages/6", [push(401, #"{"error_code":"UNAUTHORIZED"}"#)])

        do {
            try await engine.pushOutbox()
            XCTFail("401 sollte den Push abbrechen")
        } catch { /* erwartet: AuthError.unauthorized */ }

        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.map(\.pageId), ["6"], "Seite 5 gepusht; Seite 6 unangetastet in der Outbox")
        XCTAssertEqual(engine.stateStore.state.serverBaseISO["5"], newer, "Basis von 5 vorgerückt")
    }

    /// Meldet der Server endlos `has_more=true` mit demselben Cursor (Server-Bug),
    /// darf der Pull nicht endlos pagen, sondern bricht die Schleife ab.
    func testPullBreaksWhenCursorDoesNotAdvance() async throws {
        let store = FakeStore()
        let engine = makeEngine(store: store)
        seedBook(engine, ids: [1])
        router.on("GET", "/content/books/1/sync", [push(200, #"""
            {"now":"\#(newer)","has_more":true,"cursor":{"since":"\#(newer)","since_id":7},
             "pages":[{"page_id":7,"page_name":"P7","chapter_id":null,"updated_at":"\#(newer)","html":"<p>s7</p>"}]}
            """#)])

        try await engine.pullDeltas()   // terminiert (sonst Endlosschleife)

        XCTAssertEqual(store.pages["7"]?.html, "<p>s7</p>", "erste Seite übernommen, dann abgebrochen")
        XCTAssertEqual(engine.stateStore.state.cursors[1], SyncCursorDTO(since: newer, since_id: 7))
    }

    // MARK: onServerReached-Hook (Spellcheck-Nachzug, Offline-Boot-Lücke)

    /// Jeder erfolgreiche Sync-Tick feuert `onServerReached` — Empfänger
    /// (`AppCore` → `bridge.pushDeferredSpellcheckInit`) sind idempotent, darum
    /// bewusst KEIN one-shot-Guard in der SyncEngine. Erreicht der Server
    /// (HTTP-Antwort aus Push ODER Pull), feuert der Hook.
    func testOnServerReachedFiresOnSuccessfulSyncRun() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>local</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)
        engine.stateStore.mutate { $0.serverBaseISO["5"] = base }
        router.on("PUT", "/content/pages/5", [push(200, #"{"id":5,"updated_at":"\#(newer)"}"#)])
        // pullDeltas: Buch-Liste ist leer → fetcht `/content/books`, empty-Stub.
        router.on("GET", "/content/books", [push(200, "[]")])
        var fires = 0
        engine.onServerReached = { fires += 1 }

        await engine.syncNow(manual: true)
        XCTAssertEqual(fires, 1, "erfolgreicher Tick muss feuern (Push erreicht den Server)")

        await engine.syncNow(manual: true)
        XCTAssertEqual(fires, 2,
                       "jeder erfolgreiche Tick feuert erneut — Empfänger sind idempotent, kein one-shot in der Engine")
    }

    /// Erreicht der Server NIE (Transport-Fehler auf JEDEM Roundtrip), darf
    /// der Hook NICHT feuern — sonst triegl der Spellcheck-Nachzug gegen
    /// einen toten Server.
    func testOnServerReachedDoesNotFireWhenServerUnreachable() async throws {
        let store = FakeStore()
        let engine = makeEngine(store: store)   // leere Outbox → pushOutbox hat nichts zu tun
        // KEINE Stubs → MockURLProtocol wirft URLError → APIClient wandelt in
        // AuthError.network um → reachableSend lässt `serverReachedThisRun` auf false.
        var fires = 0
        engine.onServerReached = { fires += 1 }

        do { try await engine.syncNow(manual: true) } catch { /* erwartet */ }
        XCTAssertEqual(fires, 0, "Server nicht erreicht → Hook nicht feuern")
        XCTAssertEqual(engine.status, .offline,
                       "Status = offline (reachability nie gestartet → isOnline=false)")
    }

    /// `setSyncBase` setzt die Basis nur, wenn noch keine existiert (idempotent).
    /// Verhindert den Deadlock: Seite via `fetchAndMirror` im Store + Outbox-
    /// Eintrag → Pull überspringt → Basis würde nie gesetzt → Push überspringt
    /// ewig.
    func testSetSyncBaseSetsBaseOnlyWhenMissing() async throws {
        let store = FakeStore()
        let engine = makeEngine(store: store)
        let pageId = "123"
        let serverUpdatedAt = "2026-08-25T12:00:00Z"
        let html = "<p data-bid=\"b1\">Test</p>"

        // Seite im Store anlegen (simuliert fetchAndMirror).
        _ = try await store.save(id: pageId, html: html, baseUpdatedAt: nil)

        // Noch keine Basis → setSyncBase muss sie setzen.
        XCTAssertNil(engine.stateStore.state.serverBaseISO[pageId])
        await engine.setSyncBase(pageId: pageId, serverUpdatedAt: serverUpdatedAt, html: html)
        XCTAssertEqual(engine.stateStore.state.serverBaseISO[pageId], serverUpdatedAt)
        let ancestor = try await store.serverBaseHtml(id: pageId)
        XCTAssertEqual(ancestor, html)

        // Basis existiert bereits → setSyncBase darf sie NICHT überschreiben.
        let differentUpdatedAt = "2026-08-25T13:00:00Z"
        let differentHtml = "<p data-bid=\"b1\">Other</p>"
        await engine.setSyncBase(pageId: pageId, serverUpdatedAt: differentUpdatedAt, html: differentHtml)
        XCTAssertEqual(engine.stateStore.state.serverBaseISO[pageId], serverUpdatedAt,
                       "vorhandene Basis darf nicht überschrieben werden")
        let ancestorAfter = try await store.serverBaseHtml(id: pageId)
        XCTAssertEqual(ancestorAfter, html, "vorhandener Ancestor darf nicht überschrieben werden")
    }

    /// Deadlock-Fix: `setSyncBase` setzt die Basis auch, wenn ein Outbox-Eintrag
    /// existiert (`applied == false` in `fetchAndMirror`). Das serverHtml wird
    /// als Merge-Ancestor gesetzt (nicht das lokale HTML aus dem Store), weil
    /// der 3-Wege-Merge den Server-Stand als Basis braucht.
    func testSetSyncBaseWithOutboxEntry() async throws {
        let store = FakeStore()
        let engine = makeEngine(store: store)
        let pageId = "456"
        let serverUpdatedAt = "2026-08-25T12:00:00Z"
        let localHtml = "<p data-bid=\"b1\">Lokal geändert</p>"
        let serverHtml = "<p data-bid=\"b1\">Server-Stand</p>"

        // Seite im Store + Outbox-Eintrag (simuliert `applied == false`).
        _ = try await store.save(id: pageId, html: localHtml, baseUpdatedAt: nil)
        let pending = try await store.pendingOutbox()
        XCTAssertNotNil(pending.first { $0.pageId == pageId })

        // Basis setzen mit dem SERVER-HTML (nicht dem lokalen).
        await engine.setSyncBase(pageId: pageId, serverUpdatedAt: serverUpdatedAt, html: serverHtml)

        // ISO-Basis gesetzt → Push kann arbeiten.
        XCTAssertEqual(engine.stateStore.state.serverBaseISO[pageId], serverUpdatedAt)
        // Merge-Ancestor = Server-HTML (nicht das lokale HTML).
        let ancestor = try await store.serverBaseHtml(id: pageId)
        XCTAssertEqual(ancestor, serverHtml, "Merge-Ancestor muss der Server-Stand sein, nicht das lokale HTML")
        // Lokaler Inhalt bleibt unangetastet (Datenverlust-Schutz).
        let localPage = try await store.page(id: pageId)
        XCTAssertEqual(localPage?.html, localHtml, "lokaler Inhalt darf nicht überschrieben werden")
    }

    /// `repairStalledSyncBases` repariert den Deadlock: Seite im Store + Outbox-
    /// Eintrag, aber keine `serverBaseISO` → Push/Pull überspringen ewig. Holt
    /// den Server-Stand und setzt die Basis, damit der nächste Push läuft.
    func testRepairStalledSyncBasesSetsBaseForDeadlockedPage() async throws {
        let store = FakeStore()
        let pageId = "42"
        let serverUpdatedAt = "2026-08-25T14:00:00.000Z"
        let serverHtml = "<p data-bid=\"b1\">Server-Stand</p>"
        let bookId = 7

        // Seite im Store anlegen (simuliert fetchAndMirror) — MIT Buch (keine Waise).
        // Die lokale Änderung beruht auf genau dem Server-Stand, den der GET liefert
        // (Server seitdem unverändert) → die Basis darf gefahrlos gesetzt werden.
        _ = try await store.save(id: pageId, html: "<p>lokal</p>",
                                 baseUpdatedAt: ISOTime.millis(serverUpdatedAt))
        try await store.assignBook(pageId: pageId, bookId: bookId, chapterId: nil)

        let engine = makeEngine(store: store)
        // KEINE serverBaseISO gesetzt → simuliert den Deadlock.
        XCTAssertNil(engine.stateStore.state.serverBaseISO[pageId])

        // Stub für GET /content/pages/:id — HTML-Anführungszeichen als \" im JSON.
        let escapedHtml = serverHtml.replacingOccurrences(of: "\"", with: "\\\"")
        let stubbedJson = #"{"id":42,"updated_at":"\#(serverUpdatedAt)","html":"\#(escapedHtml)","book_id":\#(bookId)}"#
        router.on("GET", "/content/pages/\(pageId)", [push(200, stubbedJson)])

        await engine.repairStalledSyncBases()

        // Basis muss gesetzt sein.
        XCTAssertEqual(engine.stateStore.state.serverBaseISO[pageId], serverUpdatedAt)
        let ancestor = try await store.serverBaseHtml(id: pageId)
        XCTAssertEqual(ancestor, serverHtml)
    }

    /// Hat sich der Server seit der Basis der lokalen Änderung bewegt (oder ist
    /// die lokale Basis unbekannt), darf die Reparatur die Basis NICHT einfach
    /// auf „Server jetzt" stellen — der nächste Push ginge ohne 409 durch und
    /// überschriebe die fremde Änderung. Stattdessen Merge; ohne Editor → Konflikt.
    func testRepairStalledSyncBasesMergesWhenServerMoved() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "42", html: "<p>lokal</p>",
                                 baseUpdatedAt: ISOTime.millis(base))
        try await store.assignBook(pageId: "42", bookId: 7, chapterId: nil)
        let engine = makeEngine(store: store)
        router.on("GET", "/content/pages/42",
                  [push(200, #"{"id":42,"updated_at":"\#(newer)","html":"<p>fremd</p>","book_id":7}"#)])

        await engine.repairStalledSyncBases()

        XCTAssertNil(engine.stateStore.state.serverBaseISO["42"], "keine blinde Basis auf den bewegten Server-Stand")
        XCTAssertEqual(engine.conflicts.map(\.pageId), ["42"], "ohne Editor → sichtbarer Konflikt statt Überschreiben")
        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.map(\.pageId), ["42"], "lokaler Stand bleibt")
    }

    /// Lehnt der Editor den stillen Reload ab (inzwischen getippt), muss die
    /// Sync-Basis zurück auf den alten Stand — sonst pushte der nächste Save
    /// den alten Text + Tippen gegen die NEUE Basis und überschriebe die
    /// Server-Änderung ohne Merge.
    func testPullRevertsBaseWhenEditorDeclinesReload() async throws {
        let store = FakeStore()
        store.seedServerPage(id: "7", html: "<p>alt</p>", bookId: 1, updatedAt: 1)
        store.ancestors["7"] = "<p>alt</p>"
        let editor = FakeEditor()
        editor.openPageId = "7"
        editor.declineReload = true
        let engine = makeEngine(store: store, editor: editor)
        engine.stateStore.mutate { $0.serverBaseISO["7"] = base }
        seedBook(engine, ids: [1])
        router.on("GET", "/content/books/1/sync", [push(200, #"""
            {"now":"\#(newer)","has_more":false,"cursor":{"since":"\#(newer)","since_id":7},
             "pages":[{"page_id":7,"page_name":"P7","chapter_id":null,"updated_at":"\#(newer)","html":"<p>neu</p>"}]}
            """#)])

        try await engine.pullDeltas()

        XCTAssertEqual(engine.stateStore.state.serverBaseISO["7"], base, "Basis zurückgedreht")
        XCTAssertEqual(store.ancestors["7"], "<p>alt</p>", "Ancestor zurückgedreht")
        XCTAssertTrue(editor.reloaded.isEmpty)
    }

    /// Übernimmt der Editor den Reload, bleibt die neue Basis stehen.
    func testPullKeepsBaseWhenEditorAcceptsReload() async throws {
        let store = FakeStore()
        store.seedServerPage(id: "7", html: "<p>alt</p>", bookId: 1, updatedAt: 1)
        let editor = FakeEditor()
        editor.openPageId = "7"
        let engine = makeEngine(store: store, editor: editor)
        engine.stateStore.mutate { $0.serverBaseISO["7"] = base }
        seedBook(engine, ids: [1])
        router.on("GET", "/content/books/1/sync", [push(200, #"""
            {"now":"\#(newer)","has_more":false,"cursor":{"since":"\#(newer)","since_id":7},
             "pages":[{"page_id":7,"page_name":"P7","chapter_id":null,"updated_at":"\#(newer)","html":"<p>neu</p>"}]}
            """#)])

        try await engine.pullDeltas()

        XCTAssertEqual(engine.stateStore.state.serverBaseISO["7"], newer)
        XCTAssertEqual(editor.reloaded.map(\.html), ["<p>neu</p>"])
    }

    /// `repairStalledSyncBases` überspringt Seiten, die bereits eine Basis haben
    /// (idempotent) und Waisen ohne Buch (die werden vom Push als Konflikt erfasst).
    func testRepairStalledSyncBasesSkipsExistingBaseAndOrphans() async throws {
        let store = FakeStore()
        let engine = makeEngine(store: store)

        // Seite MIT Basis → darf nicht angerührt werden.
        let withBase = "100"
        _ = try await store.save(id: withBase, html: "<p>ok</p>", baseUpdatedAt: nil)
        engine.stateStore.mutate { $0.serverBaseISO[withBase] = base }
        try await store.assignBook(pageId: withBase, bookId: 1, chapterId: nil)

        // Waise (kein Buch) → darf nicht angerührt werden.
        let orphan = "200"
        _ = try await store.save(id: orphan, html: "<p>waise</p>", baseUpdatedAt: nil)
        // KEIN assignBook → bookId bleibt nil

        // Stub für beide — keiner darf aufgerufen werden.
        router.on("GET", "/content/pages/\(withBase)", [push(200, #"{"id":100,"updated_at":"2026-01-01T00:00:00Z"}"#)])
        router.on("GET", "/content/pages/\(orphan)", [push(200, #"{"id":200,"updated_at":"2026-01-01T00:00:00Z"}"#)])

        await engine.repairStalledSyncBases()

        // Basis der ersten Seite unverändert.
        XCTAssertEqual(engine.stateStore.state.serverBaseISO[withBase], base)
        // Waise hat immer noch keine Basis.
        XCTAssertNil(engine.stateStore.state.serverBaseISO[orphan])
    }

    // MARK: Helfer

    /// Setzt die bekannten Buch-IDs und unterdrückt den `/content/books`-Refresh
    /// dieses Ticks (frisch genug), damit der Pull-Test ohne Bücher-Stub auskommt.
    private func seedBook(_ engine: SyncEngine, ids: [Int]) {
        engine.stateStore.mutate { $0.bookIds = ids }
        engine.lastBooksRefreshAt = Date()
    }
}
