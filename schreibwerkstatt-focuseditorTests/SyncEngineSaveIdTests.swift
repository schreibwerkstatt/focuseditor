//
//  SyncEngineSaveIdTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Save-Kennungen im Push-Pfad (`save_id` / `own_save_ids`): eine verlorene
//  Push-Antwort (Zug, Funkloch, zugeklappter Laptop) darf beim nächsten Push
//  nicht als Konflikt gegen den eigenen Stand enden — ein Write eines anderen
//  Geräts dazwischen aber sehr wohl. Gleiche Stubs/Fakes wie SyncEngineTests.
//

import XCTest

@MainActor
final class SyncEngineSaveIdTests: XCTestCase {

    private let base = "2026-01-01T00:00:00.000Z"
    private let newer = "2026-01-02T00:00:00.000Z"
    private let newest = "2026-01-03T00:00:00.000Z"
    private var router = StubRouter()

    override func setUp() {
        super.setUp()
        router = StubRouter()
        router.install()
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
        engine.stateStore.mutate { $0 = SyncState() }
        engine.stateStore.mutate { $0.serverBaseISO["5"] = self.base }
        return engine
    }

    /// Die bisher gepushten Bodies als JSON-Objekte.
    private func pushedBodies() -> [[String: Any]] {
        router.sentBodies("PUT", "/content/pages/5").compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
    }

    /// Erster Push, dessen Antwort verloren geht (kein Stub → Transportfehler).
    /// Liefert die dabei gesendete `save_id`.
    private func pushWithLostResponse(_ engine: SyncEngine) async throws -> String {
        try await engine.pushOutbox()
        let sid = try XCTUnwrap(pushedBodies().last?["save_id"] as? String)
        return sid
    }

    // (a) Antwort verloren → Folge-Push trägt die Kennung → Server erkennt „own".
    func testLostResponseFollowUpPushSendsOwnSaveIdsAndIsNoConflict() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>eins</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)

        let first = try await pushWithLostResponse(engine)
        let afterLoss = try await store.pendingOutbox()
        XCTAssertEqual(afterLoss.first?.sentUnconfirmedIds, [first], "Transportfehler → Kennung bleibt")

        // Im selben Absatz weitergetippt.
        _ = try await store.save(id: "5", html: "<p>eins zwei</p>", baseUpdatedAt: nil)
        router.on("PUT", "/content/pages/5",
                  [Stub(status: 200, json: #"{"id":5,"updated_at":"\#(newer)","save_match":"own"}"#)])

        try await engine.pushOutbox()

        let body = try XCTUnwrap(pushedBodies().last)
        XCTAssertNotEqual(body["save_id"] as? String, first, "neuer Text → neue Kennung")
        XCTAssertEqual(body["own_save_ids"] as? [String], [first], "der verlorene Push geht als eigener mit")
        XCTAssertEqual(body["expected_updated_at"] as? String, base, "Basis bleibt die alte")
        XCTAssertTrue(engine.conflicts.isEmpty, "kein Konflikt gegen sich selbst")
        let pending = try await store.pendingOutbox()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(engine.stateStore.state.serverBaseISO["5"], newer)
        let ancestor = try await store.serverBaseHtml(id: "5")
        XCTAssertEqual(ancestor, "<p>eins zwei</p>")
    }

    // (a) Sicherheitsnetz: der Server erkennt es beim PUT nicht (409), aber sein
    // `last_save_id` ist unsere → ohne Merge mit dem Server-Stempel neu pushen.
    func testConflictAgainstOwnLostPushRePushesWithoutMerge() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>eins</p>", baseUpdatedAt: nil)
        let editor = FakeEditor()
        // Würde gemergt, meldete der Merge eine Kollision (alle drei Fassungen verschieden).
        editor.mergeResult = MergeOutcome(merged: "<p>x</p>", conflictCount: 1)
        let engine = makeEngine(store: store, editor: editor)

        let first = try await pushWithLostResponse(engine)
        _ = try await store.save(id: "5", html: "<p>eins zwei</p>", baseUpdatedAt: nil)
        router.on("PUT", "/content/pages/5", [
            Stub(status: 409, json: #"{"error_code":"PAGE_CONFLICT","server_updated_at":"\#(newer)"}"#),
            Stub(status: 200, json: #"{"id":5,"updated_at":"\#(newest)"}"#),
        ])
        router.on("GET", "/content/pages/5", [Stub(status: 200, json:
            #"{"id":5,"updated_at":"\#(newer)","html":"<p>eins</p>","last_save_id":"\#(first)"}"#)])

        try await engine.pushOutbox()

        XCTAssertTrue(engine.conflicts.isEmpty, "eigener Stand ist kein Konflikt")
        let bodies = pushedBodies()
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(bodies.last?["expected_updated_at"] as? String, newer, "gegen den Server-Stempel")
        XCTAssertEqual(bodies.last?["html"] as? String, "<p>eins zwei</p>", "ungemergt der lokale Stand")
        XCTAssertEqual(bodies.last?["save_id"] as? String, bodies[1]["save_id"] as? String,
                       "derselbe Eintrag → dieselbe Kennung")
        let pending = try await store.pendingOutbox()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(engine.stateStore.state.serverBaseISO["5"], newest)
        XCTAssertEqual(store.pages["5"]?.html, "<p>eins zwei</p>")
    }

    // Der Server liefert `last_save_id` immer kleingeschrieben; eine gespeicherte
    // Kennung in Grossbuchstaben (Altbestand) muss trotzdem als eigene gelten.
    func testOwnLostPushIsRecognizedRegardlessOfCase() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>eins zwei</p>", baseUpdatedAt: nil)
        let upper = "0B6F2C1E-7A4D-4E8B-9C3F-1D2E3F4A5B6C"
        store.outbox["5"]?.sentUnconfirmedIds = [upper]
        let editor = FakeEditor()
        editor.mergeResult = MergeOutcome(merged: "<p>x</p>", conflictCount: 1)
        let engine = makeEngine(store: store, editor: editor)
        router.on("PUT", "/content/pages/5", [
            Stub(status: 409, json: #"{"error_code":"PAGE_CONFLICT","server_updated_at":"\#(newer)"}"#),
            Stub(status: 200, json: #"{"id":5,"updated_at":"\#(newest)"}"#),
        ])
        router.on("GET", "/content/pages/5", [Stub(status: 200, json:
            #"{"id":5,"updated_at":"\#(newer)","html":"<p>eins</p>","last_save_id":"\#(upper.lowercased())"}"#)])

        try await engine.pushOutbox()

        XCTAssertTrue(engine.conflicts.isEmpty, "kleingeschriebene Server-Kennung = eigene grosse Kennung")
        XCTAssertEqual(pushedBodies().last?["expected_updated_at"] as? String, newer, "ohne Merge neu gepusht")
        let pending = try await store.pendingOutbox()
        XCTAssertTrue(pending.isEmpty)
    }

    // (b) Ein Retry desselben Eintrags trägt dieselbe `save_id`.
    func testRetryOfSameEntryKeepsSaveId() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>eins</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)
        router.on("PUT", "/content/pages/5", [Stub(status: 503, json: #"{}"#)])

        try await engine.pushOutbox()
        try await engine.pushOutbox()

        let bodies = pushedBodies()
        XCTAssertEqual(bodies.count, 2)
        let sid = try XCTUnwrap(bodies[0]["save_id"] as? String)
        XCTAssertEqual(bodies[1]["save_id"] as? String, sid)
        XCTAssertEqual(bodies[1]["own_save_ids"] as? [String], [], "die eigene Kennung geht als save_id, nicht doppelt")
        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.first?.saveId, sid)
        XCTAssertEqual(pending.first?.sentUnconfirmedIds, [sid], "5xx → Kennung bleibt (vielleicht geschrieben)")
    }

    // 4xx: der Server hat nicht geschrieben → die Kennung ist erledigt.
    func testClientErrorForgetsSaveId() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>eins</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)
        router.on("PUT", "/content/pages/5", [Stub(status: 423, json: #"{"error_code":"PAGE_LOCKED"}"#)])

        try await engine.pushOutbox()

        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.first?.sentUnconfirmedIds, [], "423 → nicht geschrieben, Kennung weg")
    }

    // (c) Fremder Write dazwischen: `last_save_id` ist nicht unsere → normaler
    // Konfliktpfad über den Block-Merge.
    func testForeignWriteInBetweenTakesRegularConflictPath() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>eins</p>", baseUpdatedAt: nil)
        let editor = FakeEditor()
        editor.mergeResult = MergeOutcome(merged: "<p>x</p>", conflictCount: 1)
        let engine = makeEngine(store: store, editor: editor)

        let first = try await pushWithLostResponse(engine)
        _ = try await store.save(id: "5", html: "<p>eins zwei</p>", baseUpdatedAt: nil)
        router.on("PUT", "/content/pages/5",
                  [Stub(status: 409, json: #"{"error_code":"PAGE_CONFLICT","server_updated_at":"\#(newer)"}"#)])
        // Anderes Gerät hat ohne Kennung geschrieben → last_save_id null.
        router.on("GET", "/content/pages/5", [Stub(status: 200, json:
            #"{"id":5,"updated_at":"\#(newer)","html":"<p>fremd</p>","last_save_id":null}"#)])

        try await engine.pushOutbox()

        XCTAssertEqual(pushedBodies().last?["own_save_ids"] as? [String], [first], "nur eigene Kennungen")
        XCTAssertEqual(pushedBodies().count, 2, "kein Re-Push ohne Merge")
        XCTAssertEqual(engine.conflicts.map(\.pageId), ["5"], "fremder Write → Block-Kollision → Konflikt-UI")
        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.first?.html, "<p>eins zwei</p>", "lokaler Stand bleibt")
    }

    // Antwort kam an, aber WÄHREND des PUT wurde gespeichert: der Nachfolger hat
    // die gerade bestätigte Kennung geerbt und darf sie nicht weiter mitschicken.
    func testConfirmedSaveIdIsDroppedFromSuccessor() async throws {
        let store = FakeStore()
        _ = try await store.save(id: "5", html: "<p>eins</p>", baseUpdatedAt: nil)
        let engine = makeEngine(store: store)
        let queued = try await store.pendingOutbox()
        let sent = try await store.markSaveIdSent(pageId: "5", queuedAt: queued[0].queuedAt)
        let pushed = try XCTUnwrap(sent)
        // Save während des PUT: der Nachfolger erbt die gesendete Kennung.
        _ = try await store.save(id: "5", html: "<p>eins zwei</p>", baseUpdatedAt: nil)
        let successor = try await store.pendingOutbox()
        XCTAssertEqual(successor.first?.sentUnconfirmedIds, [pushed.saveId])
        XCTAssertNotEqual(successor.first?.saveId, pushed.saveId)

        let resp = try JSONDecoder().decode(PushResponse.self,
                                            from: Data(#"{"id":5,"updated_at":"\#(newer)"}"#.utf8))
        try await engine.confirmPush(pushed, resp: resp)

        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.map(\.html), ["<p>eins zwei</p>"], "Nachfolger bleibt in der Outbox")
        XCTAssertEqual(pending.first?.sentUnconfirmedIds, [], "bestätigte Kennung nicht weiter mitschicken")
        XCTAssertEqual(engine.stateStore.state.serverBaseISO["5"], newer)
    }
}
