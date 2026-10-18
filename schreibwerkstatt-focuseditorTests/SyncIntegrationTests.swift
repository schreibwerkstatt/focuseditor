//
//  SyncIntegrationTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Integrationstest des Swift-Sync-Clients gegen eine LAUFENDE
//  schreibwerkstatt-Instanz. Trifft den echten `APIClient`, alle Sync-DTOs
//  und das Fehler-Mapping (inkl. 409-Konflikt) — fängt Decoding-/Logikfehler,
//  die ein reiner curl-Vertragstest nicht sieht.
//
//  Konfiguration via Env (im Test-Scheme gesetzt); ohne diese Variablen
//  überspringt der Test (XCTSkip) — so bleibt er CI-/Server-los harmlos:
//    SW_E2E_BASE   z. B. http://localhost:3737
//    SW_E2E_TOKEN  Device-Token swd_…
//    SW_E2E_BOOK   Buch-ID (Int)
//    SW_E2E_PAGE   Seiten-ID (Int)
//
//  Seed dazu: scripts/sw-e2e-seed.mjs gegen den laufenden Dev-Server.
//  Oder gegen die Demo-Instanz (scripts/demo.env): die Werte als
//  TEST_RUNNER_SW_E2E_* an xcodebuild übergeben, das überschreibt das Scheme
//  (so macht es /release). Geschrieben wird nur in einen Wegwerf-Abschnitt.
//

import XCTest
// Non-hosted Logic-Test-Bundle: die getesteten Quelldateien (APIClient,
// AuthError, ServerConfig, DeviceToken, SyncModels) sind direkt Mitglied dieses
// Targets (kein App-Host, kein @testable import) → läuft headless via xctest.

@MainActor
final class SyncIntegrationTests: XCTestCase {

    private struct Cfg { let base: String; let token: String; let book: Int; let page: Int }

    private func cfg() throws -> Cfg {
        let e = ProcessInfo.processInfo.environment
        guard let base = e["SW_E2E_BASE"],
              let token = e["SW_E2E_TOKEN"],
              let book = e["SW_E2E_BOOK"].flatMap(Int.init),
              let page = e["SW_E2E_PAGE"].flatMap(Int.init) else {
            throw XCTSkip("SW_E2E_* nicht gesetzt — Integrationstest übersprungen (laufender Server + Seed nötig).")
        }
        ServerConfig.baseURLString = base
        return Cfg(base: base, token: token, book: book, page: page)
    }

    private func client(_ c: Cfg) -> APIClient {
        APIClient(tokenProvider: { c.token })
    }

    /// Device-Token-Auth-Probe + Decoding der Token-Liste.
    func testAuthProbe() async throws {
        let c = try cfg()
        let resp = try await client(c).send("/me/device-tokens", decode: DeviceTokenListResponse.self)
        XCTAssertFalse(resp.tokens.isEmpty, "mindestens das Test-Token sollte gelistet sein")
    }

    /// `GET /content/books` dekodiert zu [BookDTO] und enthält das Seed-Buch.
    func testBooksContainsSeed() async throws {
        let c = try cfg()
        let books = try await client(c).send("/content/books", decode: [BookDTO].self)
        XCTAssertTrue(books.contains { $0.id == c.book }, "Buch \(c.book) fehlt in /content/books")
    }

    /// Per-Buch-Delta dekodiert vollständig (page_id/html/cursor/has_more).
    func testSyncDeltaDecodes() async throws {
        let c = try cfg()
        let resp = try await client(c).send("/content/books/\(c.book)/sync", decode: BookSyncResponse.self)
        let p = try XCTUnwrap(resp.pages.first { $0.page_id == c.page }, "Seite \(c.page) nicht im Delta")
        XCTAssertNotNil(p.updated_at)
        XCTAssertNotNil(p.html)
        // Cursor ist Pflichtfeld der Antwort → Decoding hätte sonst geworfen.
        _ = resp.cursor.since_id
    }

    /// `GET /content/pages/:id` (Merge-Fetch-Pfad) dekodiert html + updated_at.
    func testPageFetchDecodes() async throws {
        let c = try cfg()
        let page = try await client(c).send("/content/pages/\(c.page)", decode: PushResponse.self)
        XCTAssertFalse(page.updated_at.isEmpty)
        XCTAssertNotNil(page.html)
    }

    /// Optimistic-Concurrency end-to-end: korrekter Push → 200 (Basis rückt vor),
    /// veralteter Push → 409 PAGE_CONFLICT mit dekodierbarem ConflictBody.
    ///
    /// Schreibt nie in `SW_E2E_PAGE`, sondern in einen eigens angelegten
    /// Wegwerf-Abschnitt, der danach wieder gelöscht wird — so darf die Suite
    /// auch gegen die Demo-Instanz laufen, deren Buch der App-Review sieht.
    func testPushSuccessThenConflict() async throws {
        let c = try cfg()
        let api = client(c)

        let before = try await api.send(
            "/content/pages", method: .POST,
            body: CreatePageBody(book_id: c.book, name: "XCTest \(UUID().uuidString.prefix(8))"),
            decode: PushResponse.self)
        let pageId = before.id
        addTeardownBlock {
            try? await api.sendVoid("/content/pages/\(pageId)", method: .DELETE)
        }
        let base = before.updated_at

        let ok = try await api.send(
            "/content/pages/\(pageId)", method: .PUT,
            body: PushRequest(html: "<p data-bid=\"b1\">XCTest-Push.</p>", expected_updated_at: base),
            decode: PushResponse.self)
        XCTAssertNotEqual(ok.updated_at, base, "updated_at muss nach erfolgreichem Push vorrücken")

        do {
            _ = try await api.send(
                "/content/pages/\(pageId)", method: .PUT,
                body: PushRequest(html: "<p data-bid=\"b1\">stale.</p>", expected_updated_at: base),
                decode: PushResponse.self)
            XCTFail("Erwartete 409 (veraltete Basis), bekam 200")
        } catch let AuthError.server(status, code, body) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, "PAGE_CONFLICT")
            let conflict = try XCTUnwrap(body.flatMap { try? JSONDecoder().decode(ConflictBody.self, from: $0) })
            XCTAssertEqual(conflict.error_code, "PAGE_CONFLICT")
            XCTAssertEqual(conflict.server_updated_at, ok.updated_at,
                           "server_updated_at sollte dem zuletzt erfolgreichen Push entsprechen")
        }
    }
}

private struct CreatePageBody: Encodable {
    let book_id: Int
    let name: String
}
