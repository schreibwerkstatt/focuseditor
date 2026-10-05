//
//  EditorBundleStore.swift
//  schreibwerkstatt-focuseditor
//
//  OTA-Verwaltung des Focus-Editor-Bundles. Statt die Editor-Assets zur
//  Build-Zeit aus dem Hauptrepo zu kopieren, zieht der Client sie zur Laufzeit
//  vom Server (GET /content/editor-bundle.zip) und cacht sie lokal:
//
//    Application Support/schreibwerkstatt-focuseditor/web-cache/   (js/, css/, index.html)
//    …/web-cache.meta.json                                         (ETag + sourceCommit)
//
//  HARTE REGEL (CLAUDE.md): Die WebView lädt IMMER lokal — sie liest nur aus
//  diesem Cache (via AppSchemeHandler). Netzwerk macht ausschließlich der
//  Swift-Kern. Offline-Kern bleibt gewahrt: nach dem ersten erfolgreichen
//  Download arbeitet die App vollständig offline; ein Refresh greift still beim
//  nächsten Start (kein Hot-Swap mitten im Schreiben → Datenverlust-Schutz).
//
//  Das ZIP ist DEFLATE-komprimiert und wird mit MiniZip (bordeigen, sandbox-
//  tauglich) entpackt. Das `index.html` (Boot/Bridge) ist NICHT im Bundle —
//  der Client schreibt es aus WebAssets + den Manifest-`cssFiles`.
//

import Foundation
import Combine

@MainActor
final class EditorBundleStore: ObservableObject {

    enum BundleState: Equatable {
        case idle          // noch nichts versucht
        case refreshing    // Download/Entpacken läuft (nur relevant ohne Cache)
        case ready         // ein nutzbares Bundle liegt im Cache
        case failed(String) // kein Cache UND Download fehlgeschlagen
    }

    @Published private(set) var state: BundleState = .idle
    /// Quell-Commit des aktuell gecachten Bundles (aus dem Manifest) — für die
    /// Versionsanzeige in den Einstellungen. `nil` ohne Cache.
    @Published private(set) var sourceCommit: String?
    /// Läuft gerade ein manueller Update-Check? (Spinner in den Einstellungen.)
    @Published private(set) var isCheckingUpdate = false

    private let api: APIClient
    private let fileManager = FileManager.default
    private let cacheDir: URL
    private let metaURL: URL
    /// Verzeichnis für ein im Hintergrund gezogenes, noch NICHT aktiviertes
    /// Bundle. Wird erst beim nächsten Start (in `init`, vor dem WebView-Load)
    /// in den Live-Cache promotet — so wird der live gelesene `cacheDir` NIE
    /// mitten in einer Session getauscht (Datenverlust-/Konsistenz-Schutz).
    private let pendingDir: URL
    private let pendingMetaURL: URL
    private let bundlePath = "/content/editor-bundle.zip"

    /// Verhindert parallele Refreshes (mehrfaches `ensureReady` aus der View).
    private var isRefreshing = false

    /// `baseDirectory` überschreibt die Application-Support-Wurzel — nur für
    /// Tests, damit die OTA-Fehlerpfade (kaputtes ZIP, 304, abgebrochener
    /// Download, atomarer Tausch) gegen ein temporäres Verzeichnis laufen
    /// können, statt den echten Cache des Entwicklers anzufassen.
    init(api: APIClient, baseDirectory: URL? = nil) {
        self.api = api
        let base = baseDirectory
            ?? (try? fileManager.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true))
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("schreibwerkstatt-focuseditor", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDir = dir.appendingPathComponent("web-cache", isDirectory: true)
        self.metaURL = dir.appendingPathComponent("web-cache.meta.json")
        self.pendingDir = dir.appendingPathComponent("web-cache.pending", isDirectory: true)
        self.pendingMetaURL = dir.appendingPathComponent("web-cache.pending.meta.json")

        // Ein im Vorlauf (letzte Session) gezogenes Bundle JETZT aktivieren —
        // synchron, BEVOR irgendeine WebView den Cache liest. `init` läuft vor
        // dem ersten View-Body, daher ist der Swap hier kollisionsfrei (während
        // einer Session wird der Live-Cache nie getauscht → kein Hot-Swap).
        promotePendingIfReady()
        if hasCache {
            // App-seitiges Boot-Glue (index.html) kann sich mit einem App-Update
            // geändert haben — hier (vor dem WebView-Load) aus dem Manifest neu
            // erzeugen, nicht mehr im Hintergrund-Refresh (der den Live-Cache
            // sonst während der Session mutieren würde).
            regenerateIndexHTMLFromCache()
            state = .ready
        }
        sourceCommit = loadMeta()?.sourceCommit
    }

    /// Wurzelverzeichnis, das der AppSchemeHandler ausliefert.
    var webRoot: URL { cacheDir }

    /// Liegt ein bootfähiges Bundle vor? (index.html als Marker.)
    var hasCache: Bool {
        fileManager.fileExists(atPath: cacheDir.appendingPathComponent("index.html").path)
    }

    // MARK: - Steuerung

    /// Aus der Editor-Host-View (nur bei signedIn). Mit Cache: sofort bereit,
    /// Refresh still im Hintergrund (greift beim nächsten Start). Ohne Cache:
    /// blockierender Erst-Download, dessen Zustand die UI treibt.
    func ensureReady() async {
        if hasCache {
            state = .ready
            Task { await refresh(silent: true) }   // Hintergrund-Update für den nächsten Start
        } else {
            await refresh(silent: false)
        }
    }

    /// Manueller Update-Check (aus den Einstellungen). Zieht das Bundle
    /// konditional; ein neueres Bundle wird in den Cache übernommen und greift
    /// beim nächsten Start (kein Hot-Swap mitten im Schreiben → Datenverlust-
    /// Schutz). Setzt nur den Spinner-Status; ein vorhandenes Bundle bleibt bei
    /// Fehlern unangetastet.
    func checkForUpdate() async {
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        await refresh(silent: true)
    }

    /// Leert den gecachten Editor (web-cache + Meta) und lädt ihn neu. Betrifft
    /// NUR die Editor-Assets — KEINE Inhalte (die liegen im SQLite-Spiegel und
    /// werden nicht angetastet). Nach dem Leeren erfolgt ein frischer Download.
    func clearEditorCache() async {
        // Erst einen laufenden (Start-)Refresh auslaufen lassen. Sonst liefe er
        // mit dem ETag des eben gelöschten Caches weiter: ein 304 endete in
        // „304, aber kein lokaler Cache", und der frische Download unten käme
        // am `isRefreshing`-Guard gar nicht erst an (Ladebildschirm hängt).
        // Gedeckelt — der Request selbst hat ein endliches Timeout.
        var waited = 0
        while isRefreshing && waited < 600 {    // max. ~60 s
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        try? fileManager.removeItem(at: cacheDir)
        try? fileManager.removeItem(at: metaURL)
        // Auch ein evtl. vorbereitetes (noch nicht aktiviertes) Bundle verwerfen,
        // sonst würde der frische Erst-Download es nicht ersetzen.
        try? fileManager.removeItem(at: pendingDir)
        try? fileManager.removeItem(at: pendingMetaURL)
        sourceCommit = nil
        state = .idle
        await ensureReady()
    }

    /// Lädt das Bundle konditional (ETag). Bei vorhandenem Live-Cache wird ein
    /// neues Bundle nur ins `pendingDir` VORBEREITET und beim nächsten Start
    /// aktiviert (kein Hot-Swap mitten in der Session); ohne Cache geht der
    /// Erst-Download direkt in den Live-Cache.
    /// `silent`: ein vorhandener Cache bleibt bei Fehlern unangetastet und der
    /// Zustand fällt nicht auf `.failed` (Hintergrund-Refresh).
    func refresh(silent: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if !silent && !hasCache { state = .refreshing }

        do {
            // Konditional gegen den EFFEKTIVEN Stand: liegt bereits ein
            // vorbereitetes Bundle im pendingDir, dessen ETag verwenden (sonst
            // würde dasselbe Update jede Session erneut gezogen). Sonst der
            // Live-Cache-ETag.
            let effectiveETag = (loadMeta(at: pendingMetaURL) ?? loadMeta())?.etag
            let res = try await api.getRaw(bundlePath, ifNoneMatch: effectiveETag)

            if res.notModified {
                // Bundle unverändert. Den Live-Cache NICHT anfassen — die
                // index.html-Glue-Regeneration passiert beim Start (s. `init`),
                // nicht mitten in der Session.
                state = hasCache ? .ready : .failed("Server meldet 304, aber kein lokaler Cache.")
                return
            }

            if hasCache {
                // Live-Cache läuft → neues Bundle nur VORBEREITEN (pendingDir).
                // Es wird beim nächsten Start aktiviert (kein Hot-Swap).
                try installBundle(zip: res.data, etag: res.etag, into: pendingDir, metaURL: pendingMetaURL)
                state = .ready   // weiterhin der bestehende Live-Cache
            } else {
                // Erst-Download (keine WebView liest noch) → direkt in den Cache.
                try installBundle(zip: res.data, etag: res.etag, into: cacheDir, metaURL: metaURL)
                sourceCommit = loadMeta()?.sourceCommit
                state = .ready
            }
        } catch {
            if hasCache {
                state = .ready   // Offline/Fehler: am vorhandenen Bundle festhalten
            } else if !silent {
                state = .failed(Self.describe(error))
            }
        }
    }

    // MARK: - Installation

    /// Entpackt das ZIP in ein Staging-Verzeichnis, schreibt index.html aus dem
    /// Manifest und tauscht `target` (Live-Cache ODER pendingDir) atomar. Die
    /// zugehörige Meta (ETag/Commit) wird nach `metaURL` geschrieben.
    private func installBundle(zip: Data, etag: String?, into target: URL, metaURL: URL) throws {
        let entries = try MiniZip.entries(in: zip)
        guard !entries.isEmpty else { throw MiniZipError.malformed("leeres Bundle") }

        // Staging neben dem Ziel (gleicher Volume → atomarer Replace möglich).
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent("web-cache.staging-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        // Bricht das Entpacken/Schreiben unten ab, bleibt sonst ein halb gefüllter
        // Staging-Ordner zurück. Nach erfolgreichem `swapIntoPlace` ist der Pfad
        // bereits weg (replaceItemAt konsumiert ihn) → das removeItem ist dann ein
        // harmloser No-op.
        defer { try? fileManager.removeItem(at: staging) }

        var manifest: BundleManifest?
        for entry in entries {
            // Path-Traversal-Schutz: nur Pfade innerhalb des Stagings.
            let dst = staging.appendingPathComponent(entry.path).standardizedFileURL
            guard dst.path == staging.path || dst.path.hasPrefix(staging.path + "/") else {
                throw MiniZipError.malformed("Pfad-Ausbruch: \(entry.path)")
            }
            if entry.path == "bundle-manifest.json" {
                manifest = try? JSONDecoder().decode(BundleManifest.self, from: entry.data)
            }
            try fileManager.createDirectory(at: dst.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try entry.data.write(to: dst)
        }

        // Client-eigenes index.html (Boot/Bridge) aus dem Manifest erzeugen.
        let css = manifest?.cssFiles ?? []
        let commit = manifest?.sourceCommit ?? "unknown"
        let html = WebAssets.indexHTML(cssFiles: css, sourceCommit: commit)
        try Data(html.utf8).write(to: staging.appendingPathComponent("index.html"))

        try swapIntoPlace(staging: staging, target: target)
        saveMeta(BundleMeta(etag: etag, sourceCommit: commit), to: metaURL)
    }

    /// Aktiviert beim Start ein im Vorlauf gezogenes Bundle: ersetzt den
    /// Live-Cache atomar durch `pendingDir` und übernimmt dessen Meta. Wird nur
    /// aus `init` aufgerufen (vor jedem WebView-Load) — nie während einer Session.
    private func promotePendingIfReady() {
        guard fileManager.fileExists(atPath: pendingDir.path) else { return }
        // Nur ein vollständiges Bundle aktivieren (index.html als Marker); ein
        // halb geschriebenes pending verwerfen statt einen kaputten Cache zu setzen.
        guard fileManager.fileExists(atPath: pendingDir.appendingPathComponent("index.html").path) else {
            try? fileManager.removeItem(at: pendingDir)
            try? fileManager.removeItem(at: pendingMetaURL)
            return
        }
        do {
            try swapIntoPlace(staging: pendingDir, target: cacheDir)
            // Pending-Meta wird zur neuen Live-Meta.
            try? fileManager.removeItem(at: metaURL)
            if fileManager.fileExists(atPath: pendingMetaURL.path) {
                try? fileManager.moveItem(at: pendingMetaURL, to: metaURL)
            }
        } catch {
            // Promotion fehlgeschlagen → pending verwerfen, am Live-Cache festhalten.
            try? fileManager.removeItem(at: pendingDir)
            try? fileManager.removeItem(at: pendingMetaURL)
        }
    }

    /// Erzeugt das Client-glue `index.html` aus dem bereits gecachten Manifest
    /// neu und schreibt es nur bei tatsächlicher Änderung (vermeidet I/O bei
    /// jedem Start). Greift auf der 304-Strecke, wenn das Bundle gleich bleibt,
    /// der App-seitige Boot-Code aber aktualisiert wurde.
    private func regenerateIndexHTMLFromCache() {
        let manifestURL = cacheDir.appendingPathComponent("bundle-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BundleManifest.self, from: data) else { return }
        let html = WebAssets.indexHTML(cssFiles: manifest.cssFiles ?? [],
                                       sourceCommit: manifest.sourceCommit ?? "unknown")
        let indexURL = cacheDir.appendingPathComponent("index.html")
        if let current = try? String(contentsOf: indexURL, encoding: .utf8), current == html { return }
        try? Data(html.utf8).write(to: indexURL, options: .atomic)
    }

    /// Ersetzt `target` atomar durch das Staging-Verzeichnis (Quelle wird dabei
    /// verbraucht/entfernt). `target` ist der Live-Cache (Erst-Download/Promotion)
    /// oder das pendingDir (Hintergrund-Refresh).
    private func swapIntoPlace(staging: URL, target: URL) throws {
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: target)
        }
    }

    // MARK: - Meta (ETag/Commit)

    private struct BundleManifest: Decodable {
        let sourceCommit: String?
        let jsFiles: [String]?
        let cssFiles: [String]?
    }

    private struct BundleMeta: Codable {
        let etag: String?
        let sourceCommit: String?
    }

    /// Live-Cache-Meta (an `hasCache` gekoppelt, damit kein verwaister Stand
    /// gelesen wird, wenn der Cache fehlt).
    private func loadMeta() -> BundleMeta? {
        guard hasCache else { return nil }
        return loadMeta(at: metaURL)
    }

    /// Meta von einem beliebigen Ort lesen (z. B. `pendingMetaURL`) — ungated.
    private func loadMeta(at url: URL) -> BundleMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BundleMeta.self, from: data)
    }

    private func saveMeta(_ meta: BundleMeta, to url: URL) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
