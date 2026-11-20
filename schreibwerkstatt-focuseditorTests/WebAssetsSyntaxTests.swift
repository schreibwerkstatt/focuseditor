//
//  WebAssetsSyntaxTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Syntax-Guard für den Client-Glue: der Boot-/Bridge-Code lebt als Swift-
//  String-Literal in WebAssets+IndexHTML/-BridgeFacade/-DevHarness — über 1000
//  Zeilen JavaScript, die der Swift-Compiler als reinen Text durchwinkt. Ein
//  fehlendes `}`, ein Tippfehler im Bezeichner, eine verirrte Swift-String-
//  Interpolation: alles fällt erst zur Laufzeit in der WKWebView auf, und dort
//  still (der Boot bricht ab, die Schreibfläche bleibt leer).
//
//  Die übrigen `WebAssetsTests` prüfen `contains("…")` — sie sichern, dass die
//  richtigen Vertragspunkte DRINSTEHEN, nicht dass das Ganze parst. Genau diese
//  Lücke schliesst dieser Test: er schneidet die `<script>`-Blöcke aus dem
//  generierten HTML und lässt `node --check` darüberlaufen.
//
//  `node --check` parst nur (kein Ausführen, kein Netz, keine Module-Auflösung)
//  — DOM-/Import-Referenzen stören also nicht. Fehlt `node`, prüft die
//  JavaScriptCore-Shell `jsc` aus macOS (`checkModuleSyntax`/`checkScriptSyntax`,
//  ebenfalls nur Parsen) — vorher übersprang sich der Guard auf Rechnern ohne
//  node still, und der Glue blieb ungeprüft. Fehlen beide, wird übersprungen
//  statt rot (Test-Bundles sind nicht sandboxed, `Process` ist hier erlaubt).
//

import XCTest

final class WebAssetsSyntaxTests: XCTestCase {

    // MARK: - Prüflinge

    func testIndexHTMLScriptsParse() throws {
        let html = WebAssets.indexHTML(cssFiles: ["css/focus.css"], sourceCommit: "deadbeef")
        let blocks = Self.scriptBlocks(in: html)
        XCTAssertGreaterThanOrEqual(blocks.count, 2,
            "index.html soll den klassischen Boot-Block UND das ES-Modul enthalten — \(blocks.count) gefunden")
        for (i, block) in blocks.enumerated() {
            try Self.assertParses(block.source, module: block.isModule,
                                  label: "indexHTML-Script #\(i + 1)\(block.isModule ? " (module)" : "")")
        }
    }

    func testBridgeFacadeParses() throws {
        try Self.assertParses(WebAssets.bridgeFacadeJS, module: false, label: "bridgeFacadeJS")
    }

    func testDevHarnessScriptsParse() throws {
        for (i, block) in Self.scriptBlocks(in: WebAssets.devHarnessHTML).enumerated() {
            try Self.assertParses(block.source, module: block.isModule,
                                  label: "devHarness-Script #\(i + 1)")
        }
    }

    /// Der Glue wird per Swift-Interpolation zusammengesetzt (Handler-Name,
    /// CSS-Liste, Commit). Bleibt ein `\(…)` unaufgelöst im Ausgabetext stehen,
    /// ist das im Browser ein Syntaxfehler — aber einer, den `node --check`
    /// je nach Stelle durchwinken könnte. Darum zusätzlich direkt geprüft.
    func testNoUnresolvedSwiftInterpolationLeaksIntoOutput() {
        let html = WebAssets.indexHTML(cssFiles: ["css/focus.css"], sourceCommit: "deadbeef")
        for (label, text) in [("indexHTML", html),
                              ("bridgeFacadeJS", WebAssets.bridgeFacadeJS),
                              ("devHarnessHTML", WebAssets.devHarnessHTML)] {
            XCTAssertFalse(text.contains("\\("), "\(label) enthält eine unaufgelöste Swift-Interpolation")
        }
    }

    // MARK: - Script-Blöcke aus dem HTML schneiden

    struct ScriptBlock {
        let source: String
        let isModule: Bool
    }

    /// Zerlegt HTML in seine `<script>`-Inhalte. Bewusst simpel (Suche auf
    /// `<script`…`</script>`) — die Eingabe ist unser eigenes, festes Template
    /// und kein Fremd-HTML. `src`-Skripte haben keinen Inhalt und fallen raus.
    static func scriptBlocks(in html: String) -> [ScriptBlock] {
        var blocks: [ScriptBlock] = []
        var rest = Substring(html)
        while let open = rest.range(of: "<script") {
            guard let headEnd = rest[open.upperBound...].firstIndex(of: ">") else { break }
            let attrs = String(rest[open.upperBound..<headEnd])
            let bodyStart = rest.index(after: headEnd)
            guard let close = rest[bodyStart...].range(of: "</script>") else { break }
            let body = String(rest[bodyStart..<close.lowerBound])
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(ScriptBlock(source: body, isModule: attrs.contains("type=\"module\"")))
            }
            rest = rest[close.upperBound...]
        }
        return blocks
    }

    // MARK: - node --check

    /// Schreibt die Quelle in eine temporäre Datei und lässt `node --check`
    /// darüber. `.mjs` für Module (erlaubt `import`/top-level `await`), `.js`
    /// sonst. Schlägt der Parse fehl, landet die node-Meldung samt Zeile in der
    /// Testausgabe — sie zeigt auf die Zeile IM BLOCK, nicht in der Swift-Datei.
    static func assertParses(_ source: String, module: Bool, label: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let checker = try syntaxChecker()
        let tmp = FileManager.default.temporaryDirectory
        let url = tmp.appendingPathComponent("swk-glue-\(UUID().uuidString)")
            .appendingPathExtension(module ? "mjs" : "js")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let proc = Process()
        proc.executableURL = checker.executable
        var driver: URL?
        switch checker.kind {
        case .node:
            proc.arguments = ["--check", url.path]
        case .jsc:
            // Das Treiber-Skript lässt den SyntaxError bewusst ungefangen: nur
            // eine ungefangene Exception setzt bei jsc einen Exit-Code ≠ 0
            // (`quit(n)` ignoriert sein Argument — nachgemessen).
            let script = tmp.appendingPathComponent("swk-jsc-\(UUID().uuidString).js")
            try """
                const src = readFile(arguments[0]);
                if (arguments[1] === 'module') checkModuleSyntax(src); else checkScriptSyntax(src);
                """.write(to: script, atomically: true, encoding: .utf8)
            driver = script
            proc.arguments = [script.path, "--", url.path, module ? "module" : "script"]
        }
        defer { if let driver { try? FileManager.default.removeItem(at: driver) } }
        let out = Pipe()
        proc.standardError = out
        proc.standardOutput = out
        try proc.run()
        // Vor dem `waitUntilExit` lesen: eine volllaufende Pipe würde den
        // Prüfer sonst blockieren (Fehlerausgaben sind mehrzeilig).
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        XCTAssertEqual(proc.terminationStatus, 0, """
            \(label): JavaScript parst nicht (\(checker.kind)).
            \(String(data: outData, encoding: .utf8) ?? "")
            """, file: file, line: line)
    }

    enum CheckerKind { case node, jsc }

    /// Bevorzugt `node`, sonst die `jsc`-Shell des Systems.
    static func syntaxChecker() throws -> (kind: CheckerKind, executable: URL) {
        if let node = try? nodeExecutable() { return (.node, node) }
        let jsc = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"
        if FileManager.default.isExecutableFile(atPath: jsc) {
            return (.jsc, URL(fileURLWithPath: jsc))
        }
        throw XCTSkip("weder node noch jsc gefunden — Syntax-Guard übersprungen")
    }

    /// Gegenprobe: der Prüfer muss einen echten Syntaxfehler auch melden —
    /// sonst wäre ein grüner Lauf wertlos (jsc etwa endet ohne Treiber mit 0).
    func testCheckerRejectsBrokenSource() throws {
        let checker = try Self.syntaxChecker()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swk-glue-bad-\(UUID().uuidString).mjs")
        try "export const x = { ;".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTExpectFailure("absichtlich kaputtes JS muss als Parse-Fehler auffallen (\(checker.kind))")
        try Self.assertParses("export const x = { ;", module: true, label: "Gegenprobe")
    }

    /// `node` aus den üblichen Installationspfaden (Homebrew arm64/x86, System).
    /// `Process` erbt kein Login-`PATH`, darum die explizite Liste statt `env`.
    static func nodeExecutable() throws -> URL {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw XCTSkip("node nicht gefunden (\(candidates.joined(separator: ", "))) — Syntax-Guard übersprungen")
    }
}
