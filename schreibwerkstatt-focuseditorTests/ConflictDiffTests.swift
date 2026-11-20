//
//  ConflictDiffTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Deckt den reinen Diff-Helfer der Konflikt-Auflösung ab: HTML→Absätze und die
//  absatzweise Klassifikation (lokal-only / server-only). Kein UI, kein Netz.
//

import XCTest

// Kein `@testable import` (anders als die E2E-Tests): das Test-Target ist ein
// non-hosted Logic-Bundle. Ein App-Modul-Import zöge dessen GRDB-Abhängigkeit
// (GRDBSQLite) mit, die das Bundle nicht auflösen kann. ConflictDiff.swift wird
// stattdessen direkt ins Test-Bundle kompiliert (Membership im Test-Target) und
// ist als gleiches Modul zugänglich — wie APIClientTests & Co.
final class ConflictDiffTests: XCTestCase {

    // MARK: - HTML → Absätze

    func testParagraphsSplitsBlocks() {
        let html = "<p data-bid=\"b1\">Erster Absatz.</p><p data-bid=\"b2\">Zweiter Absatz.</p>"
        XCTAssertEqual(ConflictText.paragraphs(fromHTML: html),
                       ["Erster Absatz.", "Zweiter Absatz."])
    }

    func testParagraphsStripsTagsAndDecodesEntities() {
        let html = "<p>Tom &amp; Jerry &lt;b&gt;fett&lt;/b&gt;</p>"
        XCTAssertEqual(ConflictText.paragraphs(fromHTML: html), ["Tom & Jerry <b>fett</b>"])
    }

    func testParagraphsHandlesBrAndDropsEmpty() {
        let html = "<p>Zeile eins<br>Zeile zwei</p><p></p>"
        XCTAssertEqual(ConflictText.paragraphs(fromHTML: html), ["Zeile eins", "Zeile zwei"])
    }

    func testParagraphsKeepsHorizontalRuleAsMarker() {
        let html = "<p>Vorher.</p><hr data-bid=\"b2\"><p>Nachher.</p><HR/>"
        XCTAssertEqual(ConflictText.paragraphs(fromHTML: html),
                       ["Vorher.", ConflictText.ruleMarker, "Nachher.", ConflictText.ruleMarker])
    }

    func testRuleOnlyDifferenceIsVisible() {
        let local = ConflictText.paragraphs(fromHTML: "<p>A</p><hr><p>B</p>")
        let server = ConflictText.paragraphs(fromHTML: "<p>A</p><p>B</p>")
        let result = ConflictDiff.compare(local: local, server: server)
        XCTAssertEqual(result.local.filter(\.changed).map(\.text), [ConflictText.ruleMarker])
        XCTAssertTrue(result.server.allSatisfy { !$0.changed })
    }

    func testHrPrefixedTagIsNotARule() {
        // `<hrx>` o. Ä. ist keine Trennlinie (Wortgrenze im Muster).
        XCTAssertEqual(ConflictText.paragraphs(fromHTML: "<p>a<hrx>b</p>"), ["ab"])
    }

    // MARK: - Diff-Klassifikation

    func testCompareMarksOnlyDifferingParagraphs() {
        let local = ["Gleich A", "Nur lokal", "Gleich B"]
        let server = ["Gleich A", "Gleich B"]
        let result = ConflictDiff.compare(local: local, server: server)

        // Lokale Spalte: „Nur lokal" ist die Einfügung, der Rest unverändert.
        XCTAssertEqual(result.local.map(\.changed), [false, true, false])
        // Server-Spalte: nichts nur-serverseitig → keine Markierung.
        XCTAssertEqual(result.server.map(\.changed), [false, false])
    }

    func testCompareMarksServerOnlyParagraph() {
        let local = ["Gleich A"]
        let server = ["Gleich A", "Nur Server"]
        let result = ConflictDiff.compare(local: local, server: server)

        XCTAssertEqual(result.local.map(\.changed), [false])
        XCTAssertEqual(result.server.map(\.changed), [false, true])
    }

    func testCompareIdenticalHasNoChanges() {
        let same = ["A", "B", "C"]
        let result = ConflictDiff.compare(local: same, server: same)
        XCTAssertFalse(result.local.contains { $0.changed })
        XCTAssertFalse(result.server.contains { $0.changed })
    }

    func testComparePreservesTextAndOrder() {
        let local = ["X", "Y"]
        let server = ["X"]
        let result = ConflictDiff.compare(local: local, server: server)
        XCTAssertEqual(result.local.map(\.text), ["X", "Y"])
        XCTAssertEqual(result.server.map(\.text), ["X"])
    }
}
