//
//  EditorBundleStoreTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Der OTA-Lader ist die Schicht, an der die App scheitert, BEVOR der Nutzer
//  irgendetwas sieht: ohne bootfähigen Cache gibt es keinen Editor. Genau
//  deshalb sind hier die Fehlerpfade wichtiger als der Glücksfall — kaputtes
//  ZIP, 304 ohne Cache, Serverfehler mit Cache, halb geschriebenes Pending.
//
//  Zwei Vertragspunkte, die man von Hand kaum nachstellt und die beide
//  Datenverlust bzw. einen toten Editor bedeuten würden:
//    • Ein Fehler darf einen VORHANDENEN Cache nie beschädigen (offline
//      weiterarbeiten muss gehen).
//    • Ein neues Bundle wird bei laufendem Cache nur VORBEREITET, nie
//      hot-geswappt — sonst tauschte man dem Nutzer den Editor unter den
//      Fingern weg.
//
//  Das Basisverzeichnis ist injizierbar (`baseDirectory:`), die Tests laufen
//  also gegen ein temporäres Verzeichnis und nie gegen den echten Cache.
//

import XCTest

@MainActor
final class EditorBundleStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        ServerConfig.baseURLString = "http://127.0.0.1:3737"
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swk-bundle-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Ein plausibles Bundle: Manifest + je eine JS-/CSS-Datei. KEIN
    /// `index.html` — das erzeugt der Client selbst aus dem Manifest.
    private func bundleZip(commit: String = "abc123",
                           css: [String] = ["css/focus.css"],
                           editorApi: Int? = nil) -> Data {
        let apiField = editorApi.map { "\"editorApi\":\($0)," } ?? ""
        let manifest = """
            {"sourceCommit":"\(commit)",\(apiField)"jsFiles":["js/editor/focus.js"],\
            "cssFiles":[\(css.map { "\"\($0)\"" }.joined(separator: ","))]}
            """
        var specs: [ZipFixture.FileSpec] = [
            .init(name: "bundle-manifest.json", data: Data(manifest.utf8), method: 0),
            .init(name: "js/editor/focus.js", data: Data("export const x = 1;".utf8), method: 8),
        ]
        for path in css {
            specs.append(.init(name: path, data: Data(".focus-editor {}".utf8), method: 0))
        }
        return ZipFixture.build(specs)
    }

    /// Store gegen einen skriptbaren Server. `responses` wird der Reihe nach
    /// abgearbeitet (der letzte Eintrag wiederholt sich); `nil` = Transportfehler.
    private func makeStore(_ responses: [(status: Int, data: Data, etag: String?)?],
                           onRequest: @escaping (URLRequest) -> Void = { _ in }) -> EditorBundleStore {
        var index = 0
        MockURLProtocol.handler = { request in
            onRequest(request)
            let entry = responses.isEmpty ? nil : responses[min(index, responses.count - 1)]
            index += 1
            guard let entry else { throw URLError(.notConnectedToInternet) }
            var headers: [String: String] = [:]
            if let etag = entry.etag { headers["ETag"] = etag }
            let response = HTTPURLResponse(url: request.url!, statusCode: entry.status,
                                           httpVersion: nil, headerFields: headers)!
            return (response, entry.data)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(tokenProvider: { "swd_test" },
                            session: URLSession(configuration: cfg))
        return EditorBundleStore(api: api, baseDirectory: tempDir)
    }

    private var cacheDir: URL {
        tempDir.appendingPathComponent("schreibwerkstatt-focuseditor/web-cache", isDirectory: true)
    }
    private var pendingDir: URL {
        tempDir.appendingPathComponent("schreibwerkstatt-focuseditor/web-cache.pending", isDirectory: true)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Erst-Download

    func testFirstDownloadUnpacksBundleAndBecomesReady() async {
        let store = makeStore([(200, bundleZip(), "\"etag-1\"")])
        await store.refresh(silent: false)

        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.hasCache)
        XCTAssertEqual(store.sourceCommit, "abc123")
        XCTAssertTrue(exists(cacheDir.appendingPathComponent("js/editor/focus.js")))
        XCTAssertTrue(exists(cacheDir.appendingPathComponent("css/focus.css")))
    }

    /// Das `index.html` ist Client-Glue und steckt NICHT im Server-Bundle — der
    /// Store muss es aus dem Manifest schreiben, sonst bootet nichts.
    func testWritesClientIndexHTMLFromManifest() async throws {
        let store = makeStore([(200, bundleZip(css: ["css/focus.css", "css/spellcheck.css"]), nil)])
        await store.refresh(silent: false)

        let indexURL = cacheDir.appendingPathComponent("index.html")
        XCTAssertTrue(exists(indexURL))
        let html = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(html.contains("css/focus.css"))
        XCTAssertTrue(html.contains("css/spellcheck.css"))
        XCTAssertTrue(html.contains("__focusBridge"))
        // Reihenfolge = Kaskadenreihenfolge.
        XCTAssertTrue(html.range(of: "css/focus.css")!.lowerBound
                      < html.range(of: "css/spellcheck.css")!.lowerBound)
    }

    // MARK: - Fehler beim Erst-Download

    func testCorruptZipFailsWithoutLeavingACache() async {
        let store = makeStore([(200, Data("überhaupt kein zip".utf8), nil)])
        await store.refresh(silent: false)

        guard case .failed = store.state else {
            return XCTFail("erwartet .failed, bekam \(store.state)")
        }
        XCTAssertFalse(store.hasCache, "ein kaputter Download darf keinen halben Cache hinterlassen")
    }

    func testEmptyZipIsRejected() async {
        let store = makeStore([(200, ZipFixture.build([]), nil)])
        await store.refresh(silent: false)
        guard case .failed = store.state else {
            return XCTFail("erwartet .failed, bekam \(store.state)")
        }
        XCTAssertFalse(store.hasCache)
    }

    func testNetworkErrorWithoutCacheFails() async {
        let store = makeStore([nil])
        await store.refresh(silent: false)
        guard case .failed = store.state else {
            return XCTFail("erwartet .failed, bekam \(store.state)")
        }
    }

    /// Ohne Cache ist ein 304 unbrauchbar (der Server meint „du hast es ja
    /// schon") — das muss als Fehler sichtbar werden, nicht als leerer Editor.
    func testNotModifiedWithoutCacheIsAFailure() async {
        let store = makeStore([(304, Data(), "\"etag-1\"")])
        await store.refresh(silent: false)
        guard case .failed = store.state else {
            return XCTFail("erwartet .failed, bekam \(store.state)")
        }
    }

    /// Ein stiller Hintergrund-Refresh darf ohne Cache KEINEN Fehlerzustand in
    /// die UI schreiben — er läuft im Rücken des Nutzers.
    func testSilentRefreshDoesNotSurfaceFailure() async {
        let store = makeStore([nil])
        await store.refresh(silent: true)
        XCTAssertEqual(store.state, .idle, "stiller Lauf darf die UI nicht auf .failed setzen")
    }

    // MARK: - Der Kernpunkt: vorhandener Cache bleibt unangetastet

    func testNetworkErrorKeepsExistingCache() async {
        let store = makeStore([(200, bundleZip(commit: "erste"), nil), nil])
        await store.refresh(silent: false)          // Cache aufbauen
        XCTAssertTrue(store.hasCache)

        await store.refresh(silent: false)          // jetzt Transportfehler
        XCTAssertEqual(store.state, .ready, "mit Cache bleibt die App bereit")
        XCTAssertTrue(store.hasCache)
        XCTAssertEqual(store.sourceCommit, "erste")
    }

    func testCorruptSecondDownloadKeepsExistingCache() async throws {
        let store = makeStore([(200, bundleZip(commit: "erste"), nil),
                               (200, Data("kaputt".utf8), nil)])
        await store.refresh(silent: false)
        await store.refresh(silent: true)

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.sourceCommit, "erste", "der Live-Cache darf nicht verfälscht werden")
        let js = try String(contentsOf: cacheDir.appendingPathComponent("js/editor/focus.js"),
                            encoding: .utf8)
        XCTAssertEqual(js, "export const x = 1;")
    }

    func testNotModifiedWithCacheStaysReady() async {
        let store = makeStore([(200, bundleZip(), "\"etag-1\""), (304, Data(), "\"etag-1\"")])
        await store.refresh(silent: false)
        await store.refresh(silent: true)
        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.hasCache)
    }

    // MARK: - Kein Hot-Swap

    /// Läuft bereits ein Cache, wird ein neues Bundle nur VORBEREITET. Der
    /// Live-Cache bleibt exakt, wie er ist — sonst tauschte man dem Schreibenden
    /// den Editor mitten in der Sitzung aus.
    func testNewBundleIsStagedNotHotSwapped() async {
        let store = makeStore([(200, bundleZip(commit: "alt"), "\"e1\""),
                               (200, bundleZip(commit: "neu"), "\"e2\"")])
        await store.refresh(silent: false)
        await store.refresh(silent: true)

        XCTAssertEqual(store.sourceCommit, "alt", "der Live-Cache darf sich in der Sitzung nicht ändern")
        XCTAssertTrue(exists(pendingDir), "das neue Bundle muss vorbereitet danebenliegen")
        XCTAssertEqual(store.state, .ready)
    }

    /// …und beim NÄCHSTEN Start (neue Instanz auf demselben Verzeichnis) wird
    /// es aktiviert.
    func testPendingBundleIsPromotedOnNextLaunch() async {
        let first = makeStore([(200, bundleZip(commit: "alt"), "\"e1\""),
                               (200, bundleZip(commit: "neu"), "\"e2\"")])
        await first.refresh(silent: false)
        await first.refresh(silent: true)
        XCTAssertEqual(first.sourceCommit, "alt")

        let second = makeStore([])   // neuer Start, kein Netz nötig
        XCTAssertEqual(second.sourceCommit, "neu", "vorbereitetes Bundle muss beim Start greifen")
        XCTAssertEqual(second.state, .ready)
        XCTAssertFalse(exists(pendingDir), "nach der Aktivierung darf kein Pending zurückbleiben")
    }

    /// Ein abgebrochener Vorlauf (Pending ohne `index.html`) darf beim Start
    /// NICHT aktiviert werden — das ergäbe einen toten Editor.
    func testIncompletePendingIsDiscardedOnLaunch() async throws {
        let first = makeStore([(200, bundleZip(commit: "gut"), nil)])
        await first.refresh(silent: false)

        // Halb geschriebenes Pending von Hand herstellen.
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        try Data("bruchstueck".utf8).write(to: pendingDir.appendingPathComponent("js.js"))

        let second = makeStore([])
        XCTAssertEqual(second.sourceCommit, "gut", "der intakte Live-Cache muss bleiben")
        XCTAssertTrue(second.hasCache)
        XCTAssertFalse(exists(pendingDir), "das Bruchstück muss verworfen werden")
    }

    // MARK: - Cache leeren

    func testClearRemovesCacheAndPending() async {
        let store = makeStore([(200, bundleZip(commit: "alt"), "\"e1\""),
                               (200, bundleZip(commit: "neu"), "\"e2\""),
                               nil])   // der Neu-Download nach dem Leeren scheitert
        await store.refresh(silent: false)
        await store.refresh(silent: true)
        XCTAssertTrue(exists(pendingDir))

        await store.clearEditorCache()
        XCTAssertFalse(exists(cacheDir))
        XCTAssertFalse(exists(pendingDir), "ein vorbereitetes Bundle darf das Leeren nicht überleben")
    }

    // MARK: - Path-Traversal

    /// Ein Bundle mit `../`-Pfad darf NICHT ausserhalb des Cache schreiben.
    /// Der Server ist vertrauenswürdig — aber ein Entpacker, der das zulässt,
    /// ist eine Lücke, die man nicht offen lässt.
    func testRejectsPathTraversalInBundle() async {
        let evil = ZipFixture.build([
            .init(name: "bundle-manifest.json", data: Data(#"{"sourceCommit":"x"}"#.utf8), method: 0),
            .init(name: "../../ausbruch.txt", data: Data("böse".utf8), method: 0),
        ])
        let store = makeStore([(200, evil, nil)])
        await store.refresh(silent: false)

        guard case .failed = store.state else {
            return XCTFail("erwartet .failed, bekam \(store.state)")
        }
        XCTAssertFalse(exists(tempDir.appendingPathComponent("ausbruch.txt")))
        XCTAssertFalse(store.hasCache)
    }

    // MARK: - Bundle-Vertrag (X-Editor-Api)

    /// Body der 409-Absage, wie der Server ihn schickt (contract/fixtures/
    /// editor-bundle-unsupported.json).
    private var unsupportedBody: Data {
        Data(#"{"error_code":"EDITOR_API_UNSUPPORTED","params":{"client":[1],"server":2}}"#.utf8)
    }

    /// Jeder Bundle-Request meldet die Majors, die die Schale kann — aus der
    /// EINEN Konstante, nicht als zweites Literal.
    func testBundleRequestSendsEditorApiHeader() async {
        var seen: [String?] = []
        let store = makeStore([(200, bundleZip(editorApi: 1), "\"e1\""), (304, Data(), "\"e1\"")],
                              onRequest: { seen.append($0.value(forHTTPHeaderField: "X-Editor-Api")) })
        await store.refresh(silent: false)
        await store.refresh(silent: true)

        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen.first ?? nil, EditorBundleStore.editorApiHeaderValue)
        XCTAssertEqual(seen.last ?? nil, EditorBundleStore.editorApiHeaderValue)
        XCTAssertEqual(EditorBundleStore.editorApiHeaderValue, "1")
        XCTAssertEqual(store.state, .ready)
        XCTAssertFalse(store.appUpdateRequired)
    }

    /// 409 EDITOR_API_UNSUPPORTED mit Cache: das gecachte Bundle bleibt in
    /// Betrieb (wie bei einem Netzfehler), nichts wird vorbereitet, und die App
    /// meldet „App-Update nötig".
    func testUnsupportedEditorApiKeepsCacheAndFlagsAppUpdate() async {
        let store = makeStore([(200, bundleZip(commit: "erste", editorApi: 1), "\"e1\""),
                               (409, unsupportedBody, nil)])
        await store.refresh(silent: false)
        XCTAssertFalse(store.appUpdateRequired)

        await store.refresh(silent: true)
        XCTAssertEqual(store.state, .ready, "mit Cache bleibt der Editor bereit")
        XCTAssertTrue(store.hasCache)
        XCTAssertEqual(store.sourceCommit, "erste")
        XCTAssertFalse(exists(pendingDir), "eine Absage darf kein Pending hinterlassen")
        XCTAssertTrue(store.appUpdateRequired)
        XCTAssertTrue(store.showsAppUpdateNotice)

        store.dismissAppUpdateNotice()
        XCTAssertFalse(store.showsAppUpdateNotice)
        XCTAssertTrue(store.appUpdateRequired, "der Hinweis in den Einstellungen bleibt")
    }

    /// …und sobald der Server wieder einen unserer Majors bedient, fällt der
    /// Hinweis weg.
    func testAppUpdateFlagClearsWhenServerServesAgain() async {
        let store = makeStore([(200, bundleZip(editorApi: 1), "\"e1\""),
                               (409, unsupportedBody, nil),
                               (304, Data(), "\"e1\"")])
        await store.refresh(silent: false)
        await store.refresh(silent: true)
        XCTAssertTrue(store.appUpdateRequired)

        await store.refresh(silent: true)
        XCTAssertFalse(store.appUpdateRequired)
        XCTAssertFalse(store.showsAppUpdateNotice)
    }

    /// Ohne Cache gibt es nichts zu behalten: klarer Fehlerzustand statt
    /// Ladebildschirm.
    func testUnsupportedEditorApiWithoutCacheFails() async {
        let store = makeStore([(409, unsupportedBody, nil)])
        await store.refresh(silent: false)
        guard case .failed(let message) = store.state else {
            return XCTFail("erwartet .failed, bekam \(store.state)")
        }
        XCTAssertEqual(message, t("bundle.appUpdate.noCache"))
        XCTAssertFalse(store.hasCache)
        XCTAssertTrue(store.appUpdateRequired)
    }

    /// Ein Bundle, dessen Manifest einen fremden Major trägt, wird nicht
    /// installiert — auch wenn der Server es (fälschlich) ausliefert.
    func testManifestWithUnsupportedEditorApiIsNotInstalled() async {
        let store = makeStore([(200, bundleZip(commit: "erste", editorApi: 1), "\"e1\""),
                               (200, bundleZip(commit: "fremd", editorApi: 99), "\"e2\"")])
        await store.refresh(silent: false)
        await store.refresh(silent: true)

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.sourceCommit, "erste")
        XCTAssertFalse(exists(pendingDir), "fremder Major darf nicht vorbereitet werden")
        XCTAssertTrue(store.appUpdateRequired)
    }

    /// Ein Manifest ohne `editorApi` (Server vor der Versionierung) gilt als Major 1.
    func testManifestWithoutEditorApiIsAccepted() async {
        let store = makeStore([(200, bundleZip(), nil)])
        await store.refresh(silent: false)
        XCTAssertEqual(store.state, .ready)
        XCTAssertFalse(store.appUpdateRequired)
    }
}
