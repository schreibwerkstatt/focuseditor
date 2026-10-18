//
//  LocalizationCatalogTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Guard für die zwei gebündelten Kataloge (mac-de.json / mac-en.json) — die
//  einzige Quelle der Schalen-Strings. Ein Key, den nur eine Sprache kennt,
//  fällt sonst nicht auf: die Fallback-Kette
//  (`bundled[locale] → bundled["de"] → key`) liefert im
//  englischen Build still den deutschen Text — oder, fehlt er ganz, den nackten
//  Key. Beides sieht man nur, wenn man die App in der Sprache benutzt.
//
//  Geprüft wird gegen die Dateien im Repo (wie SourceFileSizeTests), nicht
//  gegen das gebaute Bundle: das Test-Bundle ist non-hosted und trägt die
//  App-Ressourcen nicht.
//
//  Vier Zusagen:
//    1. Beide Kataloge kennen exakt dieselben Keys.
//    2. Jeder Key trägt in beiden Sprachen dieselben `{param}`-Platzhalter.
//    3. Jeder im Swift-Code benutzte `t(…)`/`tn(…)`-Key existiert im Katalog.
//    4. Plural-Keys (`tn`) haben ihre `.one`/`.other`-Formen in beiden Sprachen.
//

import XCTest

final class LocalizationCatalogTests: XCTestCase {

    // MARK: - 1. Key-Parität

    func testCatalogsHaveIdenticalKeySets() throws {
        let de = try Self.catalog("de"), en = try Self.catalog("en")
        let missingInEn = Set(de.keys).subtracting(en.keys).sorted()
        let missingInDe = Set(en.keys).subtracting(de.keys).sorted()
        XCTAssertTrue(missingInEn.isEmpty, "nur in mac-de.json: \(missingInEn.joined(separator: ", "))")
        XCTAssertTrue(missingInDe.isEmpty, "nur in mac-en.json: \(missingInDe.joined(separator: ", "))")
    }

    // MARK: - 2. Platzhalter-Parität

    /// Ein `{param}`, der in einer Sprache fehlt, verschluckt den eingesetzten
    /// Wert (z. B. „Seite  von " statt „Seite 3 von 12"); ein zusätzlicher
    /// bleibt roh als `{count}` im Text stehen. Beides ohne Fehlermeldung.
    func testPlaceholdersMatchAcrossLanguages() throws {
        let de = try Self.catalog("de"), en = try Self.catalog("en")
        var offenders: [String] = []
        for (key, deValue) in de.sorted(by: { $0.key < $1.key }) {
            guard let enValue = en[key] else { continue }   // Fall 1 meldet das schon
            let a = Self.placeholders(in: deValue), b = Self.placeholders(in: enValue)
            if a != b {
                offenders.append("  \(key): de\(a.sorted()) ≠ en\(b.sorted())")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) Key(s) mit unterschiedlichen Platzhaltern:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - 3. Benutzte Keys existieren

    /// Scannt die App-Quellen nach `t("…")` / `tn(…, "…")` mit literalem Key und
    /// prüft ihn gegen den Katalog. Dynamisch zusammengesetzte Keys (z. B.
    /// `t(metric.labelKey)`) sieht der Scan nicht — er ist ein Sieb gegen
    /// Tippfehler und vergessene Katalog-Einträge, keine Vollabdeckung.
    func testEveryLiteralKeyUsedInCodeExists() throws {
        let de = try Self.catalog("de")
        let used = try Self.literalKeysUsedInSources()
        XCTAssertFalse(used.isEmpty, "keine t(…)-Aufrufe gefunden — Scanner kaputt?")
        let missing = used.subtracting(de.keys).sorted()
        XCTAssertTrue(missing.isEmpty, """
            \(missing.count) im Code benutzte(r) Key(s) fehlen in den Katalogen:
            \(missing.map { "  " + $0 }.joined(separator: "\n"))
            """)
    }

    // MARK: - 4. Plural-Formen vollständig

    /// `tn(count, "base")` löst auf `base.one` / `base.other` auf. Fehlt eine
    /// Form, zeigt die App den Roh-Key mitten im Satz.
    func testPluralKeysHaveBothForms() throws {
        let de = try Self.catalog("de"), en = try Self.catalog("en")
        let bases = try Self.pluralBasesUsedInSources()
        XCTAssertFalse(bases.isEmpty, "keine tn(…)-Aufrufe gefunden — Scanner kaputt?")
        var offenders: [String] = []
        for base in bases.sorted() {
            for form in ["one", "other"] {
                let key = "\(base).\(form)"
                if de[key] == nil { offenders.append("  mac-de.json: \(key)") }
                if en[key] == nil { offenders.append("  mac-en.json: \(key)") }
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            unvollständige Plural-Formen:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - Helpers

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // schreibwerkstatt-focuseditorTests/
            .deletingLastPathComponent()   // <repo>/
    }

    private static func sourceRoot() throws -> URL {
        let dir = repoRoot().appendingPathComponent("schreibwerkstatt-focuseditor", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            throw XCTSkip("Source-Ordner nicht am erwarteten Pfad (\(dir.path)) — andere Maschine/CI?")
        }
        return dir
    }

    private static func catalog(_ locale: String) throws -> [String: String] {
        let url = try sourceRoot()
            .appendingPathComponent("Localization", isDirectory: true)
            .appendingPathComponent("mac-\(locale).json")
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw XCTSkip("mac-\(locale).json ist kein flaches String→String-Objekt")
        }
        return dict
    }

    /// `{name}`-Platzhalter eines Katalogwerts (wie die Web-i18n).
    static func placeholders(in value: String) -> Set<String> {
        var out: Set<String> = []
        var rest = Substring(value)
        while let open = rest.firstIndex(of: "{") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "}") else { break }
            let name = String(rest[after..<close])
            // Nur echte Bezeichner — eine `{`-Klammer in Prosa zählt nicht mit.
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                out.insert(name)
            }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    private static func swiftSources() throws -> [String] {
        let dir = try sourceRoot()
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return try e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }

    /// Literale Keys aus `t("…")`. Die Regex verlangt den öffnenden Quote direkt
    /// hinter `t(` — das schliesst `t(someVariable)` aus und trifft dank der
    /// Wortgrenze auch `.help(t("…"))` ohne Fehlalarm auf fremde `…t(`-Endungen.
    static func literalKeysUsedInSources() throws -> Set<String> {
        let re = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])t\(\s*"([A-Za-z0-9_.]+)"#)
        return matches(of: re, in: try swiftSources())
    }

    /// Basis-Keys aus `tn(<irgendwas>, "…")` UND `NumberText.plural(<x>, "…")`
    /// — beide wählen dieselben `.one`/`.other`-Formen, nur formatiert
    /// `NumberText` die Zahl zusätzlich (Tausender-Trennung).
    static func pluralBasesUsedInSources() throws -> Set<String> {
        let sources = try swiftSources()
        let tn = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])tn\([^",)]+,\s*"([A-Za-z0-9_.]+)"#)
        let numberText = try NSRegularExpression(pattern: #"NumberText\.plural\([^",)]+,\s*"([A-Za-z0-9_.]+)"#)
        return matches(of: tn, in: sources).union(matches(of: numberText, in: sources))
    }

    private static func matches(of re: NSRegularExpression, in sources: [String]) -> Set<String> {
        var out: Set<String> = []
        for source in sources {
            let ns = source as NSString
            for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                out.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return out
    }
}
