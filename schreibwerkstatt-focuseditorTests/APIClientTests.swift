//
//  APIClientTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Offline-Regressionstests für die Status-/Fehler-Logik des APIClient — über
//  einen gemockten URLProtocol, also OHNE Netz und ohne Server. Deckt die
//  laufzeitkritischen Pfade ab: Bearer-Header, 401→onUnauthorized+unauthorized,
//  409→AuthError.server mit error_code, 304-Behandlung in getRaw,
//  Decoding-Fehler-Mapping und den „fachliches 4xx"-Pfad von postExpectingJSON.
//

import XCTest

/// Fängt alle Requests der Test-Session ab und liefert eine vorprogrammierte
/// Antwort. URLProtocol läuft auf einem eigenen Thread → Handler thread-sicher.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {

    private struct OK: Decodable { let ok: Bool }

    override func setUp() {
        super.setUp()
        ServerConfig.baseURLString = "http://127.0.0.1:3737"
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient(token: String? = "swd_token",
                            handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> APIClient {
        MockURLProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return APIClient(tokenProvider: { token }, session: URLSession(configuration: cfg))
    }

    private func response(_ status: Int, headers: [String: String] = [:], for req: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    // MARK: - Header

    func testSetsBearerAuthorizationHeader() async throws {
        let client = makeClient { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer swd_token")
            return (self.response(200, for: req), Data(#"{"ok":true}"#.utf8))
        }
        let r = try await client.send("/me/device-tokens", decode: OK.self)
        XCTAssertTrue(r.ok)
    }

    /// Ein Server unter einem Pfad (`https://host/sw`) behält den Pfad — die
    /// relative Auflösung mit führendem `/` hatte ihn durch die Wurzel ersetzt.
    func testKeepsPathOfServerBaseURL() async throws {
        ServerConfig.baseURLString = "http://127.0.0.1:3737/sw"
        let client = makeClient { req in
            XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:3737/sw/me/device-tokens?x=1")
            return (self.response(200, for: req), Data(#"{"ok":true}"#.utf8))
        }
        _ = try await client.send("/me/device-tokens?x=1", decode: OK.self)
    }

    // MARK: - Namespace-Slug

    /// Eindeutige Hosts behalten die bisherige Form (kein Umzug bestehender Daten).
    func testNamespaceSlugUnchangedForUnambiguousHosts() {
        XCTAssertEqual(ServerNamespace.slug(for: URL(string: "https://schreibwerkstatt.app")),
                       "https_schreibwerkstatt-app")
        XCTAssertEqual(ServerNamespace.slug(for: URL(string: "http://127.0.0.1:3737")),
                       "http_127-0-0-1_3737")
    }

    /// `a-b.example.com` und `a.b.example.com` (bzw. zwei Pfade desselben Hosts)
    /// dürfen sich keinen Namespace teilen.
    func testNamespaceSlugDisambiguatesDashesAndPaths() {
        let dashed = ServerNamespace.slug(for: URL(string: "https://a-b.example.com"))
        let dotted = ServerNamespace.slug(for: URL(string: "https://a.b.example.com"))
        XCTAssertNotEqual(dashed, dotted)
        let p1 = ServerNamespace.slug(for: URL(string: "https://host.example/eins"))
        let p2 = ServerNamespace.slug(for: URL(string: "https://host.example/zwei"))
        XCTAssertNotEqual(p1, p2)
        XCTAssertEqual(dashed, ServerNamespace.slug(for: URL(string: "https://a-b.example.com")),
                       "stabil über Aufrufe hinweg")
    }

    // MARK: - 401

    func testUnauthorizedTriggersCallbackAndThrows() async {
        let client = makeClient { req in (self.response(401, for: req), Data()) }
        let expectation = expectation(description: "onUnauthorized aufgerufen")
        client.onUnauthorized = { used in
            XCTAssertEqual(used, "swd_token", "meldet das Token des abgewiesenen Requests")
            expectation.fulfill()
        }

        do {
            _ = try await client.send("/me/device-tokens", decode: OK.self)
            XCTFail("Erwartete AuthError.unauthorized")
        } catch AuthError.unauthorized {
            // erwartet
        } catch {
            XCTFail("Falscher Fehler: \(error)")
        }
        await fulfillment(of: [expectation], timeout: 1)
    }

    // MARK: - 409 Konflikt

    func testConflictMapsToServerErrorWithCode() async {
        let body = Data(#"{"error_code":"PAGE_CONFLICT","server_updated_at":"2026-06-14T10:00:00.000Z"}"#.utf8)
        let client = makeClient { req in (self.response(409, for: req), body) }

        do {
            _ = try await client.send("/content/pages/1", method: .PUT,
                                      body: PushRequest(html: "<p>x</p>", expected_updated_at: "base"),
                                      decode: PushResponse.self)
            XCTFail("Erwartete AuthError.server(409)")
        } catch let AuthError.server(status, code, raw) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, "PAGE_CONFLICT")
            // Roh-Body muss zum ConflictBody dekodierbar bleiben (SyncEngine-Pfad).
            let conflict = raw.flatMap { try? JSONDecoder().decode(ConflictBody.self, from: $0) }
            XCTAssertEqual(conflict?.server_updated_at, "2026-06-14T10:00:00.000Z")
        } catch {
            XCTFail("Falscher Fehler: \(error)")
        }
    }

    // MARK: - Decoding-Fehler

    func testDecodingFailureWrappedInAuthError() async {
        let client = makeClient { req in (self.response(200, for: req), Data("kein json".utf8)) }
        do {
            _ = try await client.send("/x", decode: OK.self)
            XCTFail("Erwartete AuthError.decoding")
        } catch AuthError.decoding {
            // erwartet
        } catch {
            XCTFail("Falscher Fehler: \(error)")
        }
    }

    // MARK: - getRaw (Editor-Bundle-ZIP, konditional)

    func testGetRawNotModifiedReturns304() async throws {
        let client = makeClient { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "If-None-Match"), "\"etag-1\"")
            return (self.response(304, headers: ["ETag": "\"etag-1\""], for: req), Data())
        }
        let raw = try await client.getRaw("/content/editor-bundle.zip", ifNoneMatch: "\"etag-1\"")
        XCTAssertTrue(raw.notModified)
        XCTAssertEqual(raw.etag, "\"etag-1\"")
        XCTAssertTrue(raw.data.isEmpty)
    }

    func testGetRaw200ReturnsDataAndETag() async throws {
        let payload = Data([0x50, 0x4B, 0x03, 0x04])   // ZIP-Magic
        let client = makeClient { req in
            (self.response(200, headers: ["ETag": "\"etag-2\""], for: req), payload)
        }
        let raw = try await client.getRaw("/content/editor-bundle.zip")
        XCTAssertFalse(raw.notModified)
        XCTAssertEqual(raw.etag, "\"etag-2\"")
        XCTAssertEqual(raw.data, payload)
    }

    // MARK: - postExpectingJSON (LanguageTool: fachliches 4xx wird durchgereicht)

    func testPostExpectingJSONPassesThrough404() async throws {
        // 404 = LanguageTool serverseitig aus → KEIN Fehler, sondern „Feature aus".
        let client = makeClient { req in (self.response(404, for: req), Data(#"{"disabled":true}"#.utf8)) }
        let (status, data) = try await client.postExpectingJSON("/languagetool/check",
                                                                body: ["text": "hallo"])
        XCTAssertEqual(status, 404)
        XCTAssertFalse(data.isEmpty)
    }

    func testPostExpectingJSONThrowsOn500() async {
        let client = makeClient { req in (self.response(500, for: req), Data()) }
        do {
            _ = try await client.postExpectingJSON("/languagetool/check", body: ["text": "hallo"])
            XCTFail("Erwartete AuthError.server(500)")
        } catch let AuthError.server(status, _, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("Falscher Fehler: \(error)")
        }
    }
}
