//
//  EditorBridge.swift
//  schreibwerkstatt-focuseditor
//
//  Die EINZIGE Kopplungsschicht zwischen WebView (gebündelter Focus-Editor) und
//  Swift-Kern. Kein direkter `fetch` aus dem Editor — alles läuft über diese
//  Bridge. Netzwerk macht ausschliesslich der Swift-Kern; die WebView spricht
//  nur diese Nachrichten.
//
//  Transport: `WKScriptMessageHandlerWithReply` → jede `postMessage` aus JS
//  liefert nativ ein Promise zurück (kein manuelles requestId-Matching nötig).
//
//  Diese Datei hält den KERN: Abhängigkeiten, Zustand/Callbacks, den gehärteten
//  Message-Handler und das Dirty-Tracking der offenen Seite. Der Rest liegt in
//  Geschwister-Dateien (eine Datei = eine Verantwortung, Vorbild
//  `SyncEngine[+Push/+Pull]`):
//
//    • EditorBridge+Ops.swift      — `route(op:params:)` + alle Ops (JS → Swift),
//                                    inkl. Nachrichtenvertrag in der Kopfdoku
//    • EditorBridge+Events.swift   — Swift → JS (Event-Bus, `callAsyncJavaScript`
//                                    mit Timeout, Block-Merge, Draft-Flush)
//    • EditorBridge+Params.swift   — Validierung der (nicht vertrauenswürdigen)
//                                    WebView-Parameter + `StoredPage`-Encoding
//    • EditorBridge+Recents.swift  — gerätelokale Merker (zuletzt geöffnete Seite,
//                                    MRU-Historie, aktives Buch)
//    • EditorBridge+Proxies.swift  — Server-Proxys (LanguageTool, Wörterbuch,
//                                    Synonyme) + lokale Vorlieben
//
//  Erweiterung: Braucht der Editor eine neue Root-Methode, wird sie ZUERST hier
//  (bzw. in `+Ops`) und in der JS-Facade (focusHost-Vertrag) ergänzt und in
//  CLAUDE.md dokumentiert.
//
//  Härtung: Die WebView ist eine (prinzipiell) nicht vertrauenswürdige Quelle —
//  sie führt fremden Editor-Code aus dem OTA-Bundle aus. Darum gilt hier:
//   1. Nachrichten nur aus dem eigenen Kanal, dem Haupt-Frame und einer lokalen
//      Origin (dieser Datei, s. `userContentController`).
//   2. Jeder Parameter wird validiert/geklemmt, nie direkt weitergereicht
//      (`EditorBridge+Params.swift`).
//   3. Kein Swift→JS-Aufruf ohne Timeout — ein hängendes JS darf den Swift-Kern
//      nicht blockieren (`EditorBridge+Events.swift`).
//

import Foundation
import WebKit
import OSLog

@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandlerWithReply, EditorCoordinating {
    /// Name, unter dem die Bridge in JS erreichbar ist:
    /// `window.webkit.messageHandlers.swBridge.postMessage(...)`.
    /// Single Source of Truth in `WebAssets` (dependency-frei, testbar).
    static let handlerName = WebAssets.handlerName

    // MARK: Abhängigkeiten
    //
    // Alle `internal` (nicht `private`): die Extensions in den Geschwister-Dateien
    // (+Ops/+Events/+Params/+Recents/+Proxies) greifen darauf zu.

    /// Lokaler Spiegel — jeder Save geht local-first hierhin (HARTE REGEL).
    let store: any LocalStore

    /// HTTP-Client für den LanguageTool-/Wörterbuch-/Synonym-Proxy und das
    /// Nachladen einer noch nicht gespiegelten Seite. Optional, damit die Bridge
    /// ohne Netz-Abhängigkeit (Tests/Dev-Harness) konstruierbar bleibt; fehlt er,
    /// melden die Proxy-Ops „deaktiviert".
    let api: APIClient?

    /// Diagnose-Logger (auch der Kanal für die `log`-Op der WebView).
    let log = AppLog.bridge

    /// WebView für den Swift→JS-Kanal (`callAsyncJavaScript`). Schwach: die
    /// View besitzt die Bridge (Handler-Registrierung), nicht umgekehrt.
    weak var webView: WKWebView?

    // MARK: Gecachter / lokaler Zustand

    /// Zuletzt vom Server gelesene LanguageTool-Konfiguration (aus `/config`).
    /// Wird gecacht, damit ein Offline-Tick den letzten bekannten Stand behält
    /// statt die Prüfung fälschlich abzuschalten.
    var ltConfig: (enabled: Bool, debounceMs: Int)?

    /// Hat der verzögerte Spellcheck-Nachzieh-Versuch in dieser Server-Sitzung
    /// schon stattgefunden? Verhindert, dass jeder erfolgreiche Sync-Tick die
    /// JS-Fn erneut anstösst, sobald sie einmal angeboten wurde. Sitzungs-lokal;
    /// `resetSpellcheckDeferred()` gibt ihn für einen Serverwechsel frei.
    var spellcheckDeferredDone = false
    /// Seiten, die in dieser Sitzung am Server gelöscht wurden. Ein Save dafür
    /// (etwa der Sicherungs-Save des Close-Handlers, der erst NACH dem lokalen
    /// Löschen ankommt) würde die Seite samt Outbox-Eintrag wiederbeleben — mit
    /// einem 404 beim nächsten Push als Dauer-Konflikt. `opSave` verwirft sie.
    private(set) var deletedPageIds: Set<String> = []

    func markPageDeleted(_ pageId: String) {
        deletedPageIds.insert(pageId)
    }

    /// Lokal gewählte Fokus-Granularität (CSS-Klasse `focus-mode--<value>`).
    /// Vom `FocusController` gesetzt; Default aus UserDefaults, damit der
    /// Boot-Pull schon vor `FocusController.bind(_:)` den richtigen Wert liefert.
    var focusGranularity: String = {
        let raw = UserDefaults.standard.string(forKey: FocusGranularity.storageKey) ?? ""
        return (FocusGranularity(rawValue: raw) ?? .paragraph).rawValue
    }()

    /// CSS-fertiges Typografie-Payload (Schriftgrösse/Zeilenhöhe/measure/Familie/
    /// Papier-Ton). Vom `TypographyController` gesetzt; Boot-Pull liefert es über
    /// die `editorTypography`-Op, Live-Umschalten über `pushTypography()`.
    /// Default aus UserDefaults (analog `focusGranularity`), damit der Boot-Pull
    /// schon VOR `TypographyController.bind(_:)` die persistierten Werte liefert —
    /// sonst startete der Editor mit seinen CSS-Defaults, falls der Pull das
    /// `bind(_:)` im `.task` gewinnt (Symptom: „Typografie verschwindet").
    var typography: [String: Any] = TypographyController.persistedPayload()

    // MARK: Offene Seite + Dirty-Zustand

    /// Aktuell im Editor geöffnete Seite (vom JS via `editorState` gemeldet).
    /// Änderungen laufen ausschliesslich über `applyEditorState(pageId:dirty:)`.
    private(set) var openPageId: String? {
        didSet {
            guard openPageId != oldValue else { return }
            onOpenPageChange?(openPageId)
            // Genau EIN echtes Öffnen einer Seite (nicht beim Schliessen → nil):
            // treibt den gezielten Einzelseiten-Pull (Frische beim Öffnen, statt
            // aufs Poll-Intervall zu warten). Folgemeldungen (dirty/Stats) für
            // dieselbe Seite refeuern nicht (didSet-Guard auf Wertwechsel).
            if let pid = openPageId { onPageOpened?(pid) }
        }
    }

    /// Benachrichtigung bei Wechsel der offenen Seite (treibt die Toolbar-Anzeige).
    var onOpenPageChange: ((String?) -> Void)?
    /// Benachrichtigung beim Öffnen einer (echten) Seite — triggert den gezielten
    /// Einzelseiten-Pull der SyncEngine („sicherheitshalber frisch beim Öffnen").
    /// Feuert NICHT beim Schliessen (nil) und nicht bei Folgemeldungen derselben Seite.
    var onPageOpened: ((String) -> Void)?
    /// Benachrichtigung, wenn sich der Dirty-Zustand der OFFENEN Seite ändert
    /// (treibt den lokalen Save-Indikator in der Toolbar). `true` = ungespeicherte
    /// Änderung offen, `false` = lokal gesichert / keine Seite offen.
    var onOpenDirtyChange: ((Bool) -> Void)?
    /// Lebende Schreibstatistik (pageId, Wörter, Zeichen) aus der WebView —
    /// treibt die Stats-Anzeige, das Schreibziel und den Tages-Delta. Die pageId
    /// erlaubt dem Store, „heute geschrieben" PRO Seite zu führen. Gesetzt vom
    /// `WritingStatsStore`.
    /// `(pageId, words, chars, typed)` — `typed == false` für Zählungen ohne
    /// Eingabe (Seitenwechsel, stiller Server-Refresh): die gehen in die
    /// Live-Anzeige, aber nicht in „heute geschrieben".
    var onStats: ((String?, Int, Int, Bool) -> Void)?
    /// Nutzer-Tippaktivität (`reportStats`-Meldungen aus echter Eingabe). Vom `onStats`
    /// bewusst GETRENNT, damit der `WritingStatsStore` seinen `onStats`-Slot behält.
    /// Treibt die Idle-Erkennung im `WritingTimeTracker` (Schreibzeit pausiert bei
    /// längerer Tipp-Pause). Gesetzt von `AppCore`.
    var onActivity: (() -> Void)?
    /// Ergebnis eines lokalen Saves: `nil` = erfolgreich, sonst die Fehlermeldung.
    /// Ein fehlgeschlagener `save` bedeutet, dass der Tippstand NICHT im lokalen
    /// Spiegel landete (Platte voll / DB-Fehler) — ein echter, sonst nur geloggter
    /// Datenverlust-Pfad. Treibt einen sichtbaren Warn-Banner (gesetzt von `AppCore`
    /// → `LibraryStore`), statt den Fehler still im Log verschwinden zu lassen.
    var onSaveResult: ((String?) -> Void)?
    /// Ein Widerrufen (`true`) bzw. Wiederherstellen (`false`) im Editor hat
    /// gerade `chars` Zeichen entfernt bzw. wieder eingesetzt. WebKit fasst eine
    /// ganze Tippstrecke in EINEN Undo-Schritt zusammen (alles seit dem letzten
    /// Mausklick), ein versehentliches ⌘Z kann also viel Text auf einmal
    /// entfernen — und der Auto-Save persistiert das still. Treibt darum einen
    /// sichtbaren Hinweis mit dem Rückweg ⌘⇧Z (gesetzt von `AppCore` →
    /// `LibraryStore`). Inhalte werden nie angetastet.
    var onHistoryEdit: ((Bool, Int) -> Void)?
    /// Sync-Basis für eine Seite setzen (pageId, serverUpdatedAt, serverHtml).
    /// Wird von `fetchAndMirror` aufgerufen, wenn es eine Seite vom Server holt.
    /// Das serverHtml wird direkt übergeben (nicht aus dem Store gelesen), weil
    /// bei `applied == false` (Outbox blockiert) der Store das lokale HTML hält,
    /// nicht das Server-HTML — der Merge-Ancestor muss aber der Server-Stand sein.
    /// Verhindert den Deadlock: ohne Basis würde der Push die Seite ewig
    /// überspringen, während der Pull sie ebenfalls überspringt (Outbox-Eintrag).
    /// Gesetzt von `AppCore` → `SyncEngine.setSyncBase`.
    var onSetSyncBase: ((String, String, String) async -> Void)?

    /// Seiten mit ungespeicherten Editor-Änderungen. Der Editor hält immer genau
    /// EINE Seite offen → der Set enthält höchstens die offene Seite (s.
    /// `applyEditorState`).
    private var dirtyPages: Set<String> = []
    /// Zuletzt gemeldeter Dirty-Zustand der offenen Seite (Entprellung der Events).
    private var lastNotifiedDirty = false

    init(store: any LocalStore, api: APIClient? = nil) {
        self.store = store
        self.api = api
    }

    /// Verbindet die Bridge mit der WebView (Swift→JS-Kanal). Wird vom
    /// `FocusWebView`-Host nach dem Erstellen der WKWebView aufgerufen.
    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - WKScriptMessageHandlerWithReply

    /// Origin-Schemes, aus denen die Bridge NIEMALS Nachrichten annimmt. Der
    /// Editor läuft unter `swk-app://local` (OTA-Cache) bzw. mit leerer Origin
    /// (Dev-Harness via `loadHTMLString`) — beides lokal. Ein echtes Netz-Schema
    /// kann hier nur erscheinen, wenn die harte Regel „WebView lädt nur lokal"
    /// gebrochen wird; dann bekommt der Fremd-Inhalt trotzdem keinen Zugriff auf
    /// LocalStore, Token oder Netz. (Positivliste wäre falsch: die Dev-Harness
    /// hat gar keine Origin.)
    private static let remoteOriginSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp", "ftps"]

    /// Deckel für den geloggten `op`-Namen (jeder echte Op ist deutlich kürzer) —
    /// verhindert Log-Flooding/-Verschleierung über absurd lange Werte.
    private static let maxOpLength = 40

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        // Härtung: nur der eigene Kanal und nur der Haupt-Frame. Die Facade wird
        // ohnehin nur dort injiziert (`forMainFrameOnly: true`) — ein (theoretisch)
        // eingebetteter iframe darf nicht laden/speichern.
        guard message.name == Self.handlerName, message.frameInfo.isMainFrame else {
            log.error("Bridge: Nachricht aus fremdem Kanal/Frame abgewiesen")
            replyHandler(nil, "Bridge: Nachricht abgewiesen (Kanal/Frame)")
            return
        }
        let originScheme = message.frameInfo.securityOrigin.`protocol`.lowercased()
        guard !Self.remoteOriginSchemes.contains(originScheme) else {
            log.error("Bridge: Nachricht aus Netz-Origin (\(originScheme, privacy: .public)) abgewiesen")
            replyHandler(nil, "Bridge: Nachricht abgewiesen (fremde Origin)")
            return
        }
        guard let body = message.body as? [String: Any],
              let rawOp = body["op"] as? String, !rawOp.isEmpty else {
            replyHandler(nil, "Bridge: ungültige Nachricht (op fehlt)")
            return
        }
        let op = String(rawOp.prefix(Self.maxOpLength))
        let params = body["params"] as? [String: Any] ?? [:]

        Task {
            do {
                let result = try await route(op: op, params: params)
                replyHandler(result, nil)
            } catch {
                self.log.error("Bridge-Op \(op, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - Editor-Zustand (offene Seite + Dirty)

    /// Übernimmt den vom Editor gemeldeten Zustand. EINZIGER Weg, `openPageId`
    /// und die Dirty-Flags zu verändern — auch `closePage()` (Swift→JS) läuft
    /// darüber, damit Save-Indikator und Beobachter nicht an zwei Stellen
    /// gepflegt werden müssen.
    ///
    /// Härtung: der Editor hält immer genau EINE Seite offen, also wird der
    /// Dirty-Set auf sie reduziert. Ein stehengebliebenes Flag (Seitenwechsel,
    /// während die alte Seite dirty war) hätte den stillen Server-Reload dieser
    /// Seite dauerhaft blockiert und den Set unbegrenzt wachsen lassen. Der
    /// Datenverlust-Schutz bleibt: lokal gesicherte, ungepushte Stände hängen an
    /// der Outbox (nicht an diesem Flag).
    func applyEditorState(pageId: String?, dirty: Bool) {
        openPageId = pageId
        if let pageId, dirty {
            dirtyPages = [pageId]
        } else {
            dirtyPages.removeAll()
        }
        notifyDirty()
    }

    func isDirty(_ pageId: String) -> Bool {
        dirtyPages.contains(pageId)
    }

    /// Meldet den Dirty-Zustand der OFFENEN Seite an Beobachter (Toolbar-Save-
    /// Indikator), aber nur bei echtem Wechsel. Keine offene Seite → `false`.
    private func notifyDirty() {
        let dirty = openPageId.map { dirtyPages.contains($0) } ?? false
        guard dirty != lastNotifiedDirty else { return }
        lastNotifiedDirty = dirty
        onOpenDirtyChange?(dirty)
    }
}

// MARK: - Fehler

enum BridgeError: LocalizedError {
    case unknownOp(String)
    case missingParam(String)
    case invalidParam(String, reason: String)
    case webViewUnavailable
    case mergeFailed
    case mergeTimedOut
    case jsTimedOut(String)
    case languagetool(status: Int)

    var errorDescription: String? {
        switch self {
        case .unknownOp(let op):     return "Bridge: unbekannte Operation '\(op)'"
        case .missingParam(let key): return "Bridge: Parameter '\(key)' fehlt"
        case .invalidParam(let key, let reason):
            return "Bridge: Parameter '\(key)' ungültig (\(reason))"
        case .webViewUnavailable:    return "Bridge: keine WebView verfügbar (Swift→JS)"
        case .mergeFailed:           return "Bridge: Block-Merge lieferte kein Ergebnis"
        case .mergeTimedOut:         return "Bridge: Block-Merge zeitüberschritten"
        case .jsTimedOut(let label): return "Bridge: JS-Aufruf zeitüberschritten (\(label))"
        case .languagetool(let s):   return "Bridge: LanguageTool-Proxy antwortete mit Status \(s)"
        }
    }
}
