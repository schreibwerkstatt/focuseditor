//
//  MiniZipTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Offline-Regressionstests für den bordeigenen ZIP-Entpacker (MiniZip.swift),
//  der das OTA-Editor-Bundle (GET /content/editor-bundle.zip) auspackt. Bricht
//  dieser Pfad, lädt der Editor nicht — also voll abgesichert: stored + deflate,
//  Verzeichnis-Skip, Central-Directory mit Extra-Feld, Fehlerfälle.
//
//  Die Test-ZIPs werden hier byteweise selbst gebaut (kein `Process`/`zip` im
//  Sandbox), DEFLATE über dasselbe Compression-Framework wie MiniZip — so ist
//  der Encode/Decode-Pfad symmetrisch (raw DEFLATE, RFC 1951).
//

import XCTest
import Compression

final class MiniZipTests: XCTestCase {

    // MARK: - Tests

    func testExtractsStoredEntry() throws {
        let payload = Data("Hallo Welt — äöü".utf8)
        let zip = ZipFixture.build([ZipFixture.FileSpec(name: "a.txt", data: payload, method: 0)])
        let entries = try MiniZip.entries(in: zip)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.path, "a.txt")
        XCTAssertEqual(entries.first?.data, payload)
    }

    func testInflatesDeflatedEntry() throws {
        // Gut komprimierbarer Inhalt → method 8 greift wirklich.
        let payload = Data(String(repeating: "abcABC123 ", count: 500).utf8)
        let zip = ZipFixture.build([ZipFixture.FileSpec(name: "js/focus.js", data: payload, method: 8)])
        let entries = try MiniZip.entries(in: zip)
        XCTAssertEqual(entries.first?.path, "js/focus.js")
        XCTAssertEqual(entries.first?.data, payload, "DEFLATE-Roundtrip muss bit-genau sein")
    }

    func testSkipsDirectoryEntries() throws {
        let zip = ZipFixture.build([
            ZipFixture.FileSpec(name: "js/", data: Data(), method: 0),                 // Verzeichnis
            ZipFixture.FileSpec(name: "js/focus.js", data: Data("x".utf8), method: 0),
        ])
        let entries = try MiniZip.entries(in: zip)
        XCTAssertEqual(entries.map(\.path), ["js/focus.js"], "Verzeichnis-Einträge werden übersprungen")
    }

    func testHandlesMultipleEntriesWithCentralDirectoryExtraField() throws {
        // Regression: das Central Directory trägt hier ein Extra-Feld (z. B.
        // Extended-Timestamp). Wird die Extra-Länge falsch gelesen, rutscht der
        // CD-Parser aus dem Tritt und der 2. Eintrag wird nicht gefunden.
        let extra = Data([0x55, 0x54, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])  // "UT" Extended-Timestamp
        let zip = ZipFixture.build([
            ZipFixture.FileSpec(name: "css/style.css", data: Data("body{}".utf8), method: 0, cdExtra: extra),
            ZipFixture.FileSpec(name: "js/app.js", data: Data("let x=1".utf8), method: 8, cdExtra: extra),
        ])
        let entries = try MiniZip.entries(in: zip)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.path == "css/style.css" }?.data, Data("body{}".utf8))
        XCTAssertEqual(entries.first { $0.path == "js/app.js" }?.data, Data("let x=1".utf8))
    }

    func testRejectsChecksumMismatch() {
        let zip = ZipFixture.build([ZipFixture.FileSpec(name: "a.js", data: Data("x".utf8),
                                                        method: 0, crcOverride: 0xDEAD_BEEF)])
        XCTAssertThrowsError(try MiniZip.entries(in: zip)) { error in
            guard case MiniZipError.checksumMismatch = error else {
                return XCTFail("erwartet checksumMismatch, war \(error)")
            }
        }
    }

    func testRejectsEntryOverSizeLimitBeforeInflating() {
        let payload = Data(repeating: 0x41, count: 2_000)
        let zip = ZipFixture.build([ZipFixture.FileSpec(name: "big.js", data: payload, method: 8)])
        let limits = MiniZip.Limits(maxEntries: 10, maxEntrySize: 1_000, maxTotalSize: 10_000)
        XCTAssertThrowsError(try MiniZip.entries(in: zip, limits: limits)) { error in
            guard case MiniZipError.tooLarge = error else {
                return XCTFail("erwartet tooLarge, war \(error)")
            }
        }
    }

    func testRejectsTooManyEntries() {
        let specs = (0..<3).map { ZipFixture.FileSpec(name: "f\($0).js", data: Data("x".utf8), method: 0) }
        let limits = MiniZip.Limits(maxEntries: 2, maxEntrySize: 1_000, maxTotalSize: 10_000)
        XCTAssertThrowsError(try MiniZip.entries(in: ZipFixture.build(specs), limits: limits))
    }

    func testThrowsOnNonZipInput() {
        XCTAssertThrowsError(try MiniZip.entries(in: Data("überhaupt kein zip".utf8))) { error in
            guard case MiniZipError.notAZip = error else {
                return XCTFail("Erwartete .notAZip, bekam \(error)")
            }
        }
    }

    func testThrowsOnTooShortInput() {
        XCTAssertThrowsError(try MiniZip.entries(in: Data([0x50, 0x4B]))) { error in
            guard case MiniZipError.notAZip = error else {
                return XCTFail("Erwartete .notAZip, bekam \(error)")
            }
        }
    }
}
