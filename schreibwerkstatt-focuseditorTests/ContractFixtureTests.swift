//
//  ContractFixtureTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Decoding gegen den Client-Vertrag des Servers. Die Fixtures unter
//  contract/fixtures/ (eingecheckt, gezogen mit scripts/sync-contract.sh) sind
//  echte Server-Antworten, aufs Schema projiziert und normalisiert — jede ist
//  `{ operation, request, status, response }`. Hier dekodiert jede Antwort, die
//  die App liest, mit dem ECHTEN DTO und dem ECHTEN Decoder des APIClient
//  (`APIClient.makeDecoder()`), nicht mit einem Nachbau.
//
//  Ein roter Test nach einem Sync heisst: der Server liefert etwas anders, als
//  die App es liest. Das ist ein Befund — erst contract/CHANGELOG.md lesen,
//  dann das DTO anpassen, nie die Fixture von Hand.
//
//  Drei Zusagen:
//    1. Jede Fixture-Datei ist zugeordnet (`checks`) oder begründet ignoriert
//       (`ignored`) — eine neue Fixture fällt auf, statt still ungeprüft zu bleiben.
//    2. Jede zugeordnete Antwort dekodiert mit dem DTO, das die App benutzt.
//    3. Jeder Key, den der Push (`PushRequest`) sendet, steht im Vertrag.
//
//  Geladen wird per Pfad relativ zu `#filePath` (wie LocalizationCatalogTests):
//  das Test-Bundle ist non-hosted und trägt keine Repo-Ressourcen.
//

import XCTest

@MainActor
final class ContractFixtureTests: XCTestCase {

    // MARK: - Zuordnung

    /// Fixtures, die der Mac nicht liest — mit Grund. Kommt eine neue Fixture
    /// dazu, gehört sie in `checks` oder hierher; Testfall 1 erzwingt das.
    private var ignored: [String: String] {
        [
            // Android-only (x-clients ohne macos in openapi.json):
            "chapter-create": "Android: POST /content/chapters (Tagebuch-Kapitel)",
            "device-ping": "Android: Buch-Präsenz POST …/device-ping",
            "research-create": "Android: Recherche teilen POST /research",
            "research-list": "Android: GET /research",
            // Fall, den der Mac nie erzeugt:
            "push-empty": "Mac sendet nie einen leeren Push-Body (PushRequest trägt immer html)",
        ]
    }

    /// Je Fixture die Prüfung — das DTO, das die App für genau diese Antwort
    /// benutzt, plus inhaltliche Asserts, wo die App sich auf ein Feld verlässt.
    private var checks: [String: (Fixture) throws -> Void] {
        [
            // ── Bücher / Baum / Sync ────────────────────────────────────────
            "books": { f in
                let books = try self.decode([BookDTO].self, f)
                XCTAssertFalse(books.isEmpty)
            },
            "book-tree": { f in
                let tree = try self.decode(BookTreeDTO.self, f)
                XCTAssertFalse(tree.chapters.isEmpty)
                XCTAssertFalse(tree.topPages.isEmpty)
                XCTAssertFalse(tree.chapters[0].subchapters.isEmpty, "Unterkapitel müssen rekursiv dekodieren")
            },
            "sync-full": { f in
                let resp = try self.decode(BookSyncResponse.self, f)
                XCTAssertFalse(resp.pages.isEmpty)
                XCTAssertGreaterThan(resp.cursor.since_id, 0)
                XCTAssertNotNil(resp.cursor.since)
                for page in resp.pages {
                    XCTAssertNotNil(page.updated_at.flatMap { ISOTime.millis($0) }, "Basis muss als ISO lesbar sein")
                    XCTAssertNotNil(page.html)
                }
            },
            "sync-delta": { f in
                let resp = try self.decode(BookSyncResponse.self, f)
                XCTAssertFalse(resp.has_more)
                XCTAssertGreaterThan(resp.cursor.since_id, 0)
                XCTAssertNotNil(resp.cursor.since)
            },

            // ── Abschnitt lesen / pushen / anlegen / umbenennen ─────────────
            "page": { f in
                let page = try self.decode(PushResponse.self, f)
                XCTAssertNotNil(ISOTime.millis(page.updated_at))
                XCTAssertTrue(page.html?.contains("data-bid") ?? false, "Block-Merge braucht data-bid")
                XCTAssertNotNil(page.book_id)
            },
            "push": { f in
                let resp = try self.decode(PushResponse.self, f)
                XCTAssertEqual(resp.last_save_id, self.requestBody(f)["save_id"] as? String)
                XCTAssertNil(resp.save_match)
                XCTAssertNil(resp.merged)
            },
            "push-replay": { f in
                let resp = try self.decode(PushResponse.self, f)
                XCTAssertEqual(resp.save_match, "replay")
            },
            "push-merged": { f in
                let resp = try self.decode(PushResponse.self, f)
                XCTAssertEqual(resp.merged, true)
            },
            "rename": { f in
                let resp = try self.decode(PushResponse.self, f)
                XCTAssertEqual(resp.name, self.requestBody(f)["name"] as? String)
                XCTAssertNotNil(ISOTime.millis(resp.updated_at), "Rename liefert die neue Basis")
            },
            "page-create": { f in
                let resp = try self.decode(PushResponse.self, f)
                XCTAssertNotNil(resp.html)
                XCTAssertNotNil(ISOTime.millis(resp.updated_at))
            },
            "push-conflict": { f in
                XCTAssertEqual(f.status, 409)
                let body = try self.decode(ConflictBody.self, f)
                XCTAssertEqual(body.error_code, "PAGE_CONFLICT")
                XCTAssertNotNil(body.server_updated_at)
                XCTAssertNil(body.merge_conflicts)
            },
            "push-merge-conflict": { f in
                XCTAssertEqual(f.status, 409)
                let body = try self.decode(ConflictBody.self, f)
                XCTAssertEqual(body.error_code, "PAGE_CONFLICT")
                XCTAssertFalse(body.merge_conflicts?.isEmpty ?? true)
            },
            "push-locked": { f in
                XCTAssertEqual(f.status, 423)
                let body = try self.decode(LockBody.self, f)
                XCTAssertEqual(body.error_code, "PAGE_LOCKED")
                XCTAssertNotNil(body.expires_at.flatMap { ISOTime.date($0) }, "Lock-Ende steuert den Backoff")
            },
            // DELETE /content/pages/:id läuft über `sendVoid` — nur der Status zählt.
            "page-delete": { f in XCTAssertEqual(f.status, 200) },

            // ── Frühere Fassungen ───────────────────────────────────────────
            "revisions": { f in
                let list = try self.decode(RevisionListResponse.self, f)
                XCTAssertFalse(list.revisions.isEmpty)
                XCTAssertNotNil(list.revisions[0].createdAt)
            },
            "revision": { f in
                let detail = try self.decode(RevisionDetailResponse.self, f)
                XCTAssertNotNil(detail.revision.body_html)
            },
            // Restore läuft über `sendVoid`; danach zieht der Sync den Stand.
            "revision-restore": { f in XCTAssertEqual(f.status, 200) },

            // ── Jobs (Lektorat, KI-Synonyme) ────────────────────────────────
            "job-check-create": { f in
                let created = try self.decode(CheckJobCreateResponse.self, f)
                XCTAssertNotNil(created.jobId)
            },
            "job-check-done": { f in
                let job = try self.decode(JobStatusEnvelope<LektoratJobResult>.self, f)
                XCTAssertEqual(job.status, "done")
                XCTAssertEqual(job.result?.fehler?.count, 1)
            },
            "job-synonym-create": { f in
                let created = try self.decode(JobCreateResponse.self, f)
                XCTAssertNotNil(created.jobId)
            },
            "job-synonym-done": { f in
                let job = try self.decode(JobStatusEnvelope<SynonymJobResult>.self, f)
                XCTAssertEqual(job.status, "done")
                XCTAssertFalse(job.result?.synonyme?.isEmpty ?? true)
            },

            // ── Konto / Auth ────────────────────────────────────────────────
            "device-tokens": { f in
                let list = try self.decode(DeviceTokenListResponse.self, f)
                XCTAssertFalse(list.tokens.isEmpty)
            },
            // Fehler-Body, wie AccountDeletionController ihn liest.
            "account-delete-unconfirmed": { f in
                XCTAssertEqual(f.status, 400)
                let body = try self.decode(ServerErrorBody.self, f)
                XCTAssertEqual(body.error_code, "CONFIRM_REQUIRED")
            },
            // 401 deutet der APIClient am Status (→ AuthError.unauthorized); der
            // Body muss trotzdem als generischer Fehler lesbar bleiben.
            "auth-invalid-token": { f in
                XCTAssertEqual(f.status, 401)
                _ = try self.decode(ServerErrorBody.self, f)
            },
            // Generische Fehler-Bodies (APIClient.serverError → AuthError.server.code).
            "page-not-found": { f in
                XCTAssertEqual(f.status, 404)
                XCTAssertEqual(try self.decode(ServerErrorBody.self, f).error_code, "PAGE_NOT_FOUND")
            },
            "scope-forbidden": { f in
                XCTAssertEqual(f.status, 403)
                XCTAssertNotNil(try self.decode(ServerErrorBody.self, f).error_code)
            },

            // ── Konfiguration / Proxys ──────────────────────────────────────
            "config": { f in
                let cfg = try self.decode(ConfigDTO.self, f)
                XCTAssertGreaterThanOrEqual(cfg.clientContract?.api ?? 0, 1)
                XCTAssertNotNil(cfg.clientContract?.editorApi)
                XCTAssertNotNil(cfg.languagetool?.enabled)
                XCTAssertNotNil(cfg.languagetool?.debounceMs)
                XCTAssertNotNil(cfg.userSettings?.locale)
            },
            "book-settings": { f in
                let settings = try self.decode(BookSettingsDTO.self, f)
                XCTAssertNotNil(settings.language)
            },
            // POST /dictionary: die Bridge wertet nur den Status aus.
            "dictionary-add": { f in XCTAssertEqual(f.status, 200) },
            // POST /history/writing-time läuft über `sendVoid`.
            "writing-time": { f in XCTAssertEqual(f.status, 200) },
            // Markdown-Export: der Client schreibt den Roh-Body in die Datei.
            "export-md": { f in
                let markdown = try self.decode(String.self, f)
                XCTAssertTrue(markdown.hasPrefix("# "))
            },
            // OTA-Override der UI-Strings: I18nBundleStore cacht nur, was als
            // `[locale: [key: text]]` lesbar ist.
            "macclient-i18n": { f in
                let parsed = try JSONSerialization.jsonObject(with: self.responseData(f)) as? [String: [String: String]]
                XCTAssertNotNil(parsed)
            },

            // ── Editor-Bundle (OTA) ─────────────────────────────────────────
            "editor-bundle": { f in
                XCTAssertEqual(self.requestHeader(f, "X-Editor-Api"), EditorBundleStore.editorApiHeaderValue)
                let manifest = try self.decode(EditorBundleStore.BundleManifest.self, f)
                let major = try XCTUnwrap(manifest.editorApi, "Manifest muss editorApi tragen")
                XCTAssertTrue(EditorBundleStore.supportedEditorApiMajors.contains(major))
                XCTAssertNotNil(manifest.cssFiles)
            },
            "editor-bundle-unchanged": { f in
                XCTAssertEqual(f.status, 304)
                XCTAssertEqual(self.requestHeader(f, "X-Editor-Api"), EditorBundleStore.editorApiHeaderValue)
            },
            "editor-bundle-unsupported": { f in
                XCTAssertEqual(f.status, 409)
                let body = try self.decode(EditorBundleStore.EditorApiUnsupportedBody.self, f)
                XCTAssertEqual(body.error_code, EditorBundleStore.editorApiUnsupportedCode)
                XCTAssertNotNil(body.params?.server)
            },
        ]
    }

    // MARK: - 1. Vollständigkeit

    func testEveryFixtureIsMappedOrIgnored() throws {
        let names = try fixtureNames()
        XCTAssertFalse(names.isEmpty, "keine Fixtures unter \(Self.fixturesDir.path) — scripts/sync-contract.sh laufen lassen")

        let mapped = Set(checks.keys)
        let skipped = Set(ignored.keys)
        XCTAssertTrue(mapped.isDisjoint(with: skipped),
                      "zugeordnet UND ignoriert: \(mapped.intersection(skipped).sorted())")

        let unassigned = names.subtracting(mapped).subtracting(skipped)
        XCTAssertTrue(unassigned.isEmpty,
                      "Fixtures ohne Zuordnung (in `checks` aufnehmen oder in `ignored` begründen): \(unassigned.sorted())")

        let stale = mapped.union(skipped).subtracting(names)
        XCTAssertTrue(stale.isEmpty, "Zuordnung ohne Fixture-Datei (serverseitig entfernt?): \(stale.sorted())")
    }

    // MARK: - 2. Decoding

    func testEveryMappedFixtureDecodesWithTheAppDTO() throws {
        let names = try fixtureNames()
        for (name, check) in checks.sorted(by: { $0.key < $1.key }) where names.contains(name) {
            let f = try fixture(name)
            do {
                try check(f)
            } catch {
                XCTFail("\(name) (\(f.operation)): \(error)")
            }
        }
    }

    /// Der eingecheckte Vertrag muss zu dem passen, was diese Schale kann —
    /// sonst lieferte der Server ihr nach dem Deploy kein Bundle mehr.
    func testVendoredContractVersionIsSupported() throws {
        let data = try Data(contentsOf: Self.contractDir.appendingPathComponent("version.json"))
        let version = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let api = try XCTUnwrap(version["api"] as? Int)
        let editorApi = try XCTUnwrap(version["editorApi"] as? Int)
        XCTAssertGreaterThanOrEqual(api, 1)
        XCTAssertTrue(EditorBundleStore.supportedEditorApiMajors.contains(editorApi),
                      "Vertrag editorApi \(editorApi) ⇒ Schale nachziehen (contract/CHANGELOG.md), dann supportedEditorApiMajors erweitern")
    }

    // MARK: - 3. Request-Seite

    /// Jeder Key, den der Push sendet, muss im Vertrag stehen: im Requestschema
    /// von `PUT /content/pages/{page_id}` (openapi.json) oder im Fixture-Request
    /// `push.json`. Ein Key ausserhalb ignoriert der Server still — dann liefe
    /// ein Feature ins Leere, ohne dass es jemand merkt.
    func testPushRequestKeysAreInTheContract() throws {
        let req = PushRequest(html: "<p data-bid=\"b1\">x</p>",
                              expected_updated_at: "2026-01-01T00:00:00.000Z",
                              save_id: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed",
                              own_save_ids: ["6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b"])
        let encoded = try APIClient.makeEncoder().encode(req)
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        let fixtureKeys = try Set(requestBody(fixture("push")).keys)
        let schemaKeys = try openAPIRequestProperties(path: "/content/pages/{page_id}", method: "put")
        XCTAssertFalse(schemaKeys.isEmpty)

        for key in sent.keys.sorted() {
            XCTAssertTrue(schemaKeys.contains(key) || fixtureKeys.contains(key),
                          "PushRequest sendet `\(key)`, der Vertrag kennt es nicht")
        }
        // Der Mac mergt selbst (merge3) — `base_html` schickt er bewusst nicht.
        XCTAssertNil(sent["base_html"])
    }

    // MARK: - Laden

    private struct Fixture {
        let name: String
        let operation: String
        let status: Int
        let request: [String: Any]
        /// Die ganze Fixture als JSON-Objekt (für `response`).
        let root: [String: Any]
    }

    private static var contractDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // schreibwerkstatt-focuseditorTests/
            .deletingLastPathComponent()   // <repo>/
            .appendingPathComponent("contract", isDirectory: true)
    }

    private static var fixturesDir: URL {
        contractDir.appendingPathComponent("fixtures", isDirectory: true)
    }

    private func fixtureNames() throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixturesDir,
                                                                includingPropertiesForKeys: nil)
        return Set(files.filter { $0.pathExtension == "json" }
                        .map { $0.deletingPathExtension().lastPathComponent })
    }

    private func fixture(_ name: String) throws -> Fixture {
        let url = Self.fixturesDir.appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                 "\(name): kein JSON-Objekt")
        return Fixture(name: name,
                       operation: root["operation"] as? String ?? "?",
                       status: root["status"] as? Int ?? -1,
                       request: root["request"] as? [String: Any] ?? [:],
                       root: root)
    }

    /// `response` der Fixture als JSON-Bytes — so, wie der Server sie schickt.
    private func responseData(_ f: Fixture) throws -> Data {
        let response = f.root["response"] ?? NSNull()
        return try JSONSerialization.data(withJSONObject: response, options: [.fragmentsAllowed])
    }

    /// Dekodiert `response` mit dem Decoder, den der APIClient benutzt.
    private func decode<T: Decodable>(_ type: T.Type, _ f: Fixture) throws -> T {
        try APIClient.makeDecoder().decode(T.self, from: responseData(f))
    }

    private func requestBody(_ f: Fixture) -> [String: Any] {
        f.request["body"] as? [String: Any] ?? [:]
    }

    private func requestHeader(_ f: Fixture, _ name: String) -> String? {
        (f.request["headers"] as? [String: Any])?[name] as? String
    }

    /// Property-Namen des Requestschemas einer Operation (löst einen `$ref` auf
    /// `#/components/schemas/…` auf).
    private func openAPIRequestProperties(path: String, method: String) throws -> Set<String> {
        let data = try Data(contentsOf: Self.contractDir.appendingPathComponent("openapi.json"))
        let spec = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let paths = try XCTUnwrap(spec["paths"] as? [String: Any])
        let op = try XCTUnwrap((paths[path] as? [String: Any])?[method] as? [String: Any],
                               "\(method.uppercased()) \(path) fehlt in openapi.json")
        let content = (op["requestBody"] as? [String: Any])?["content"] as? [String: Any]
        var schema = try XCTUnwrap((content?["application/json"] as? [String: Any])?["schema"] as? [String: Any])
        if let ref = schema["$ref"] as? String {
            let name = String(ref.split(separator: "/").last ?? "")
            let schemas = (spec["components"] as? [String: Any])?["schemas"] as? [String: Any]
            schema = try XCTUnwrap(schemas?[name] as? [String: Any], "Schema \(name) fehlt")
        }
        let props = schema["properties"] as? [String: Any] ?? [:]
        return Set(props.keys)
    }
}
