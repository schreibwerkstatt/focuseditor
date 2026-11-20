//
//  FocusWebView.swift
//  schreibwerkstatt-focuseditor
//
//  SwiftUI-Host für die WKWebView, die den Focus-Editor trägt.
//
//  HARTE REGEL (CLAUDE.md): Die WebView lädt IMMER lokal — nie eine Server-URL.
//   • Liegt im OTA-Cache (web-cache/, von EditorBundleStore gezogen) ein
//     bootfähiges Bundle (index.html), wird es über das eigene Scheme
//     (swk-app://) via AppSchemeHandler geladen — eine Origin, ES-Module laden.
//   • Sonst Fallback auf die In-Source-Dev-Harness (`loadHTMLString`), damit die
//     Shell + Bridge schon vor dem ersten Bundle-Download lauffähig und testbar sind.
//
//  Die Bridge-Facade wird at-document-start in beide Fälle injiziert.
//

import AppKit
import os
import SwiftUI
import WebKit

struct FocusWebView: NSViewRepresentable {
    /// App-weite Bridge (geteilt mit der SyncEngine über `AppCore`).
    let bridge: EditorBridge
    /// Wurzelverzeichnis des lokal gecachten OTA-Editor-Bundles (web-cache/).
    /// Der AppSchemeHandler liefert ausschließlich Dateien hierunter aus.
    let webRoot: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.bridge = bridge   // Lebensdauer an die View koppeln

        let controller = WKUserContentController()
        // Bridge-Primitiv at-document-start bereitstellen.
        controller.addUserScript(WKUserScript(source: WebAssets.bridgeFacadeJS,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        // Promise-basierter Handler (JS-`postMessage` liefert nativ ein Reply).
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: EditorBridge.handlerName)

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        // Bundle über ein eigenes Scheme ausliefern (EINE Origin → ES-Module laden;
        // loadFileURL gibt jeder Datei eine opake Origin → CORS-Block). Quelle ist
        // der lokale OTA-Cache (web-cache/); liegt dort kein index.html, greift
        // unten die Dev-Harness.
        if hasBundle {
            let handler = AppSchemeHandler(webRoot: webRoot)
            context.coordinator.schemeHandler = handler  // Lebensdauer an die View koppeln
            config.setURLSchemeHandler(handler, forURLScheme: AppScheme.scheme)
        }

        // Subklasse statt WKWebView: sie hängt dem nativen Kontextmenü der
        // Schreibfläche den Synonym-Eintrag voran (Rechtsklick-Zwilling zu ⌘⇧S
        // und zum Toolbar-Knopf). Der Klickpunkt geht mit an die Bridge, damit
        // der Glue das Wort unter der Maus bestimmt — der Rechtsklick setzt in
        // einem contenteditable nicht zuverlässig den Caret.
        let webView = FocusEditorWebView(frame: .zero, configuration: config)
        webView.isSynonymsAvailable = { [bridge] in
            SynonymPrefs.localEnabled && bridge.openPageId != nil
        }
        webView.onSynonyms = { [bridge] point in
            Task { await bridge.openSynonyms(at: point) }
        }
        Self.makeTransparent(webView)
        webView.navigationDelegate = context.coordinator
        context.coordinator.reload = { [self] webView in self.load(into: webView) }
        #if DEBUG
        if webView.responds(to: Selector(("setInspectable:"))) {
            webView.isInspectable = true   // Web-Inspector im Debug-Build
        }
        #endif

        // Swift→JS-Kanal verbinden (Open-Page-Reload, Block-Merge).
        bridge.attach(webView)

        load(into: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Statisches lokales Bundle — kein dynamisches Reload nötig.
    }

    /// Schaltet den opaken WKWebView-Hintergrund aus, damit die Brand-Fläche
    /// (BrandColor.bg) durchscheint. Es gibt KEINE öffentliche API dafür — die
    /// `drawsBackground`-Property ist privat und nur über KVC erreichbar. Der
    /// Zugriff ist gegen ein künftig fehlendes Setter-Selektor abgesichert
    /// (degradiert dann still zu opakem Weiss, statt zu crashen). Bewusst
    /// akzeptiert: Distribution läuft über Sparkle/Notarization, nicht den
    /// App Store (CLAUDE.md Roadmap 5).
    private static func makeTransparent(_ webView: WKWebView) {
        guard webView.responds(to: Selector(("setDrawsBackground:"))) else { return }
        webView.setValue(false, forKey: "drawsBackground")
    }

    /// Liegt im Cache ein bootfähiges Bundle (index.html)?
    private var hasBundle: Bool {
        FileManager.default.fileExists(atPath: webRoot.appendingPathComponent("index.html").path)
    }

    /// Lädt das gecachte Editor-Bundle über das eigene Scheme, sonst die Dev-Harness.
    private func load(into webView: WKWebView) {
        if hasBundle {
            webView.load(URLRequest(url: AppScheme.indexURL))
        } else {
            webView.loadHTMLString(WebAssets.devHarnessHTML, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: EditorBridge?
        var schemeHandler: AppSchemeHandler?
        /// Lädt Bundle bzw. Dev-Harness neu (gesetzt in `makeNSView`).
        var reload: ((WKWebView) -> Void)?
        /// Zeitpunkte der letzten Prozess-Abstürze — Deckel gegen eine
        /// Neustart-Schleife, falls das Bundle den Prozess beim Boot selbst
        /// zum Absturz bringt.
        private var recentCrashes: [Date] = []

        /// Der WebContent-Prozess ist abgestürzt oder wurde vom System beendet
        /// (Speicherdruck). Die Schreibfläche ist dann leer, die Bridge hielte
        /// aber weiter eine offene, evtl. dirty Seite fest — der Sync lüde sie
        /// nie still neu, die Toolbar zeigte eine Seite, die es im Editor nicht
        /// mehr gibt. Darum: Zustand zurücksetzen und neu booten (der Boot
        /// öffnet die zuletzt offene Seite aus dem lokalen Spiegel wieder).
        /// Verloren ist nur, was seit dem letzten Autosave nur im DOM lag.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            AppLog.bridge.error("WebContent-Prozess beendet — Editor wird neu geladen")
            bridge?.applyEditorState(pageId: nil, dirty: false)
            let now = Date()
            recentCrashes = recentCrashes.filter { now.timeIntervalSince($0) < 60 } + [now]
            guard recentCrashes.count <= 3 else {
                AppLog.bridge.error("WebContent-Prozess stürzt wiederholt ab — kein weiterer Neustart")
                return
            }
            reload?(webView)
        }

        // HARTE REGEL: keine externen Navigationen. Nur lokale Schemes erlauben.
        //
        // Ausnahme für vom Nutzer angeklickte http(s)-Links (z. B. „Regel-Info"
        // im LanguageTool-Popover, `<a target="_blank">`): die Navigation wird in
        // der WebView weiter abgelehnt, die URL aber an den Standard-Browser
        // übergeben. Ohne das reagiert der Link gar nicht — `target="_blank"`
        // bräuchte zusätzlich einen WKUIDelegate, und `.cancel` erstickt ihn ohnehin.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased()
            // Kein `file`: die Dev-Harness läuft auf `about:` (loadHTMLString
            // ohne baseURL), das Bundle auf dem eigenen Scheme.
            if scheme == AppScheme.scheme || scheme == "about" || scheme == nil {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            // http(s)/mailto/… gehören nicht in die Editor-WebView.
            guard let url, scheme == "http" || scheme == "https" else { return }
            // Nur echte Nutzer-Links: angeklickt oder als neues Fenster
            // angefordert (`target="_blank"` → targetFrame == nil, WebKit meldet
            // das je nach Fall als .linkActivated oder .other). Keine
            // Auto-Navigation aus dem Dokument heraus.
            let isNewWindow = navigationAction.targetFrame == nil
            guard navigationAction.navigationType == .linkActivated || isNewWindow else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
