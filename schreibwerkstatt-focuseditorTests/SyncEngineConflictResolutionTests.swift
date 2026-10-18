//
//  SyncEngineConflictResolutionTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Manuelle Konflikt-Auflösung (`SyncEngine.resolveConflict(pageId:keepLocal:)`):
//  die Wahl „Mein Stand"/„Server-Stand" betrifft nur die kollidierenden Absätze,
//  alle übrigen Änderungen beider Seiten bleiben erhalten. Ohne Merge-Ancestor
//  oder bei werfendem Merge greift das alte „alles oder nichts".
//
//  HTTP-Stubs und LocalStore-Fake teilt die Datei mit SyncEngineTests; der
//  Editor-Fake hier mergt absatzweise wie `block-merge.js` (Kollision ⇔ beide
//  Seiten haben denselben Absatz verschieden geändert), damit auch geprüft ist,
//  dass die Engine Basis/lokal/Server richtig übergibt.
//

import XCTest

/// Absatzweiser 3-Wege-Merge nach Position — genügt für Szenarien mit gleicher
/// Absatzzahl. `merged` = Kollision lokal, `mergedRemote` = Kollision Server.
@MainActor
private final class BlockMergeEditor: EditorCoordinating {
    var openPageId: String?
    var mergeError: Error?
    var declineReload = false
    private(set) var mergeCalls = 0
    private(set) var reloaded: [String] = []

    func isDirty(_ pageId: String) -> Bool { false }

    func reloadPage(pageId: String, html: String, baseUpdatedAt: Double, force: Bool) async -> Bool {
        if declineReload && !force { return false }
        reloaded.append(html)
        return true
    }

    func merge3(base: String?, local: String, server: String) async throws -> MergeOutcome {
        mergeCalls += 1
        if let mergeError { throw mergeError }
        let b = Self.blocks(base ?? ""), l = Self.blocks(local), r = Self.blocks(server)
        var merged: [String] = [], remote: [String] = [], conflicts = 0
        for i in 0..<max(l.count, r.count) {
            let bi = i < b.count ? b[i] : nil, li = i < l.count ? l[i] : nil, ri = i < r.count ? r[i] : nil
            if li == ri || ri == bi { merged.append(li ?? ""); remote.append(li ?? "") }
            else if li == bi { merged.append(ri ?? ""); remote.append(ri ?? "") }
            else { conflicts += 1; merged.append(li ?? ""); remote.append(ri ?? "") }
        }
        let mergedRemote = remote.joined()
        return MergeOutcome(merged: merged.joined(), conflictCount: conflicts,
                            mergedRemote: mergedRemote, remoteUnchanged: mergedRemote == server)
    }

    func flushDraftSave() async {}

    private static func blocks(_ html: String) -> [String] {
        html.components(separatedBy: "</p>").filter { !$0.isEmpty }.map { $0 + "</p>" }
    }
}

@MainActor
final class SyncEngineConflictResolutionTests: XCTestCase {

    private let baseISO = "2026-01-01T00:00:00.000Z"
    private let serverISO = "2026-01-02T00:00:00.000Z"
    private let pushedISO = "2026-01-03T00:00:00.000Z"
    private var router = StubRouter()
    /// Engines dieses Tests — ihre Snapshot-Writes laufen asynchron und müssen
    /// vor dem nächsten Test durch sein: sonst landet ein Konflikt auf Seite 5
    /// NACH dem Löschen in `setUp` auf der Platte, und die nächste Engine (auch
    /// in SyncEngineTests, gleicher Namespace) stellt ihn im `init` wieder her.
    private var engines: [SyncEngine] = []

    override func setUp() {
        super.setUp()
        router = StubRouter()
        router.install()
        ServerConfig.baseURLString = "http://synctest.local"
        try? FileManager.default.removeItem(
            at: AppSupport.serverDir().appendingPathComponent("syncstate.json"))
    }

    override func tearDown() {
        engines.forEach { $0.stateStore.flushForTesting() }
        engines = []
        try? FileManager.default.removeItem(
            at: AppSupport.serverDir().appendingPathComponent("syncstate.json"))
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: Szenario

    private static func page(_ a: String, _ b: String, _ c: String) -> String {
        "<p>\(a)</p><p>\(b)</p><p>\(c)</p>"
    }
    private let base = page("A", "B", "C")

    /// Engine mit offenem Konflikt auf Seite 5: Ancestor `base` (wenn `withBase`),
    /// lokal ungepusht `local`, Server liefert `server`.
    private func makeEngine(local: String, server: String, editor: BlockMergeEditor,
                            withBase: Bool = true) async throws -> (SyncEngine, FakeStore) {
        let store = FakeStore()
        store.seedServerPage(id: "5", html: base, bookId: 1, updatedAt: 1)
        if withBase { store.ancestors["5"] = base }
        _ = try await store.save(id: "5", html: local, baseUpdatedAt: nil)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(tokenProvider: { "swd_test" }, session: URLSession(configuration: cfg))
        let engine = SyncEngine(api: api, content: ContentAPI(api: api), store: store,
                                reachability: nil, shouldSync: { true })
        engine.editor = editor
        engines.append(engine)
        engine.stateStore.mutate { $0 = SyncState() }
        engine.stateStore.mutate { $0.serverBaseISO["5"] = baseISO }
        await engine.recordConflict(pageId: "5", serverUpdatedAt: serverISO, serverEditorName: "Laptop")

        let serverJSON = try JSONSerialization.data(withJSONObject:
            ["id": 5, "updated_at": serverISO, "html": server])
        router.on("GET", "/content/pages/5", [Stub(status: 200, json: String(decoding: serverJSON, as: UTF8.self))])
        router.on("PUT", "/content/pages/5", [Stub(status: 200, json: #"{"id":5,"updated_at":"\#(pushedISO)"}"#)])
        return (engine, store)
    }

    /// Gepushte Bodies (HTML + erwartete Basis).
    private func pushes() -> [(html: String, expected: String?)] {
        router.sentBodies("PUT", "/content/pages/5").compactMap { data in
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let html = obj["html"] as? String else { return nil }
            return (html, obj["expected_updated_at"] as? String)
        }
    }

    // MARK: „Mein Stand"

    func testKeepLocalKeepsServerOnlyChanges() async throws {
        let editor = BlockMergeEditor()
        let (engine, store) = try await makeEngine(local: Self.page("A'", "B", "C"),
                                                   server: Self.page("A''", "B", "C''"), editor: editor)

        await engine.resolveConflict(pageId: "5", keepLocal: true)

        let expected = Self.page("A'", "B", "C''")
        XCTAssertEqual(pushes().map(\.html), [expected], "Kollision lokal, Absatz C vom Server bleibt")
        XCTAssertEqual(pushes().first?.expected, serverISO, "gegen den frischen Server-Stand gepusht")
        let ancestor = try await store.serverBaseHtml(id: "5")
        XCTAssertEqual(ancestor, expected, "Basis = tatsächlich gepushtes HTML")
        XCTAssertEqual(store.pages["5"]?.html, expected, "Spiegel trägt den gepushten Stand")
        XCTAssertEqual(engine.stateStore.state.serverBaseISO["5"], pushedISO)
        let pending = try await store.pendingOutbox()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(engine.conflicts.isEmpty)
    }

    func testKeepLocalReloadsOpenPageWithPushedState() async throws {
        let editor = BlockMergeEditor()
        editor.openPageId = "5"
        let (engine, _) = try await makeEngine(local: Self.page("A'", "B", "C"),
                                               server: Self.page("A''", "B", "C''"), editor: editor)

        await engine.resolveConflict(pageId: "5", keepLocal: true)

        XCTAssertEqual(editor.reloaded, [Self.page("A'", "B", "C''")])
    }

    func testDeclinedReloadMakesLocalStateTheAncestor() async throws {
        let editor = BlockMergeEditor()
        editor.openPageId = "5"
        editor.declineReload = true   // inzwischen getippt
        let local = Self.page("A'", "B", "C")
        let (engine, store) = try await makeEngine(local: local,
                                                   server: Self.page("A''", "B", "C''"), editor: editor)

        await engine.resolveConflict(pageId: "5", keepLocal: true)

        let ancestor = try await store.serverBaseHtml(id: "5")
        XCTAssertEqual(ancestor, local, "Editor trägt noch den lokalen Stand → er ist der Ancestor")
        XCTAssertEqual(engine.stateStore.state.serverBaseISO["5"], serverISO,
                       "ISO-Basis bleibt alt → nächster Push merged per 409")
        XCTAssertTrue(engine.conflicts.isEmpty)
    }

    // MARK: „Server-Stand"

    func testKeepServerWithOnlyCollidingLocalChangeAdoptsServer() async throws {
        let editor = BlockMergeEditor()
        let server = Self.page("A''", "B", "C''")
        let (engine, store) = try await makeEngine(local: Self.page("A'", "B", "C"),
                                                   server: server, editor: editor)

        await engine.resolveConflict(pageId: "5", keepLocal: false)

        XCTAssertTrue(pushes().isEmpty, "nichts Lokales ohne Kollision → kein PUT")
        XCTAssertEqual(store.pages["5"]?.html, server)
        let ancestor = try await store.serverBaseHtml(id: "5")
        XCTAssertEqual(ancestor, server)
        let pending = try await store.pendingOutbox()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(engine.conflicts.isEmpty)
    }

    func testKeepServerKeepsLocalOnlyChanges() async throws {
        let editor = BlockMergeEditor()
        let (engine, store) = try await makeEngine(local: Self.page("A'", "B'", "C"),
                                                   server: Self.page("A''", "B", "C''"), editor: editor)

        await engine.resolveConflict(pageId: "5", keepLocal: false)

        let expected = Self.page("A''", "B'", "C''")
        XCTAssertEqual(pushes().map(\.html), [expected], "Kollision Server, lokales B' bleibt")
        let ancestor = try await store.serverBaseHtml(id: "5")
        XCTAssertEqual(ancestor, expected, "Basis = tatsächlich gepushtes HTML")
        XCTAssertEqual(store.pages["5"]?.html, expected)
        let pending = try await store.pendingOutbox()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(engine.conflicts.isEmpty)
    }

    // MARK: Rückfall auf „alles oder nichts"

    func testWithoutBaseKeepLocalForcePushesRawLocal() async throws {
        let editor = BlockMergeEditor()
        let local = Self.page("A'", "B", "C")
        let (engine, store) = try await makeEngine(local: local, server: Self.page("A''", "B", "C''"),
                                                   editor: editor, withBase: false)

        await engine.resolveConflict(pageId: "5", keepLocal: true)

        XCTAssertEqual(editor.mergeCalls, 0, "ohne Ancestor kein Merge")
        XCTAssertEqual(pushes().map(\.html), [local], "Force-Push des rohen lokalen Stands")
        let ancestor = try await store.serverBaseHtml(id: "5")
        XCTAssertEqual(ancestor, local)
        XCTAssertTrue(engine.conflicts.isEmpty)
    }

    func testWithoutBaseKeepServerAdoptsServer() async throws {
        let editor = BlockMergeEditor()
        let server = Self.page("A''", "B", "C''")
        let (engine, store) = try await makeEngine(local: Self.page("A'", "B'", "C"), server: server,
                                                   editor: editor, withBase: false)

        await engine.resolveConflict(pageId: "5", keepLocal: false)

        XCTAssertTrue(pushes().isEmpty)
        XCTAssertEqual(store.pages["5"]?.html, server)
        let pending = try await store.pendingOutbox()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(engine.conflicts.isEmpty)
    }

    func testThrowingMergeFallsBackToForcePush() async throws {
        let editor = BlockMergeEditor()
        editor.mergeError = BridgeError.mergeTimedOut
        let local = Self.page("A'", "B", "C")
        let (engine, store) = try await makeEngine(local: local, server: Self.page("A''", "B", "C''"),
                                                   editor: editor)

        await engine.resolveConflict(pageId: "5", keepLocal: true)

        XCTAssertEqual(pushes().map(\.html), [local])
        let ancestor = try await store.serverBaseHtml(id: "5")
        XCTAssertEqual(ancestor, local)
        XCTAssertTrue(engine.conflicts.isEmpty)
    }

    func testThrowingMergeFallsBackToAdoptServer() async throws {
        let editor = BlockMergeEditor()
        editor.mergeError = BridgeError.mergeFailed
        let server = Self.page("A''", "B", "C''")
        let (engine, store) = try await makeEngine(local: Self.page("A'", "B'", "C"), server: server,
                                                   editor: editor)

        await engine.resolveConflict(pageId: "5", keepLocal: false)

        XCTAssertTrue(pushes().isEmpty)
        XCTAssertEqual(store.pages["5"]?.html, server)
        XCTAssertTrue(engine.conflicts.isEmpty)
    }
}
