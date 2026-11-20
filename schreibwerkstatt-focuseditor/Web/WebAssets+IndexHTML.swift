//
//  WebAssets+IndexHTML.swift
//  schreibwerkstatt-focuseditor
//
//  Der Boot-/Bridge-Glue der Mac-Schale (`indexHTML`) für das OTA-Editor-Bundle.
//
//  Das `index.html` ist NICHT Teil des Server-Bundles (Editor-SSoT) — es ist
//  Client-Glue (adaptiert die WKWebView-Bridge `window.__focusBridge` auf den
//  standalone-Vertrag und mountet die Focus-Engine). Der EditorBundleStore
//  schreibt es nach dem Entpacken in den Cache, mit den `<link>`-Tags aus den
//  `cssFiles` des Bundle-Manifests (Reihenfolge = Link-Reihenfolge).
//

import Foundation

extension WebAssets {
    /// Escaped einen String für die Verwendung in einem doppelt-gequoteten
    /// HTML-Attribut. Die CSS-Pfade stammen aus dem OTA-Bundle-Manifest
    /// (Trust-Grenze) — ein Pfad mit `"`/`<`/`>`/`&` würde sonst aus dem
    /// href-Attribut ausbrechen und Markup ins Boot-HTML injizieren, das mit
    /// Bridge-Zugriff im Page-World läuft.
    private static func htmlAttributeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Content-Security-Policy des Boot-Dokuments. HARTE REGEL „WebView lädt nur
    /// lokal": der Navigations-Guard (`FocusWebView.decidePolicyFor`) sieht nur
    /// Navigationen, nicht Unterressourcen — ein aus Safari eingefügtes
    /// `<img src="https://…">` oder eine externe CSS-`url()` lüde WebKit sonst
    /// selbst aus dem Netz (IP + Lesezeitpunkt an Dritte). Erlaubt ist nur das
    /// eigene Scheme plus `data:`/`blob:` für Bilder und Schriften (das
    /// Editor-CSS nutzt `data:`-SVGs). `'unsafe-inline'` braucht das Boot-Modul
    /// (Inline-`<script>`) und die Typografie-Override-Schicht (`<style>`).
    /// WKUserScripts und `callAsyncJavaScript` unterliegen der CSP nicht.
    /// Externe Bilder bleiben im HTML stehen (und synchen normal) — sie werden
    /// hier nur nicht geladen. `swk-app` = `AppScheme.scheme` (literal, weil das
    /// Test-Target `AppSchemeHandler.swift` nicht mitkompiliert).
    static let contentSecurityPolicy = [
        "default-src 'self' swk-app:",
        "script-src 'self' swk-app: 'unsafe-inline'",
        "style-src 'self' swk-app: 'unsafe-inline'",
        "img-src 'self' swk-app: data: blob:",
        "font-src 'self' swk-app: data:",
        "connect-src 'self' swk-app:",
        "media-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "form-action 'none'",
        "base-uri 'self'",
    ].joined(separator: "; ")

    static func indexHTML(cssFiles: [String], sourceCommit: String) -> String {
        let links = cssFiles
            .map { "  <link rel=\"stylesheet\" href=\"\(htmlAttributeEscaped($0))\">" }
            .joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="de">
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Schreibwerkstatt — Focus-Editor</title>
          <!-- GENERIERT vom EditorBundleStore aus dem OTA-Bundle (Quelle @\(htmlAttributeEscaped(sourceCommit))). Nicht von Hand editieren. -->
          <script>
            // Theme-Brücke: Die Editor-CSS schaltet Dark Mode NUR über
            // :root[data-theme="dark"] (theme-init.js aus dem Hauptrepo läuft
            // hier nicht). Die native AppearanceController setzt NSApp.appearance,
            // die WKWebView erbt sie → prefers-color-scheme stimmt. Wir spiegeln
            // diese Media-Query auf data-theme (vor erstem Paint = FOUC-sicher)
            // und folgen Live-Umschaltungen (System wie auch manuell Hell/Dunkel).
            (function () {
              var mq = window.matchMedia('(prefers-color-scheme: dark)');
              var sync = function () {
                document.documentElement.setAttribute('data-theme', mq.matches ? 'dark' : 'light');
              };
              sync();
              mq.addEventListener ? mq.addEventListener('change', sync) : mq.addListener(sync);
            })();
          </script>
        \(links)
          <style>
            html, body { margin: 0; height: 100%; background: var(--color-bg, #faf7f2); color: var(--color-text, #1f1c18); }
            /* Dokument selbst darf NIE scrollen. Der Editor ist ein
               `position: fixed`-Overlay; ein (auch nur minimal) gescrolltes
               Dokument darunter zieht Darstellung und Maus-Hit-Test von fixed-
               Elementen auseinander (Vorschlag sichtbar hier, klickbar dort).
               Gescrollt wird ausschliesslich .focus-editor__content. Im Web-SPA
               macht das `body.focus-mode { overflow: hidden }`, das im
               Standalone-Mount nicht gesetzt wird — darum hier. */
            html, body { overflow: hidden; overscroll-behavior: none; }
            #mount { height: 100vh; display: flex; flex-direction: column; }
            #boot-status { font: 13px/1.5 -apple-system, system-ui, sans-serif; padding: 24px; }
            .err { color: #c62828; }
            /* LanguageTool-Status-Badge ans Fenster-Eck pinnen. Der Editor-Controller
               positioniert .lt-badge per Inline-Style an die rechte Kante der
               .focus-editor__content (offsetLeft+offsetWidth). Da wir die Spalte
               zentriert + schmal (measure) auf breiter Fläche rendern, schwebte es
               sonst mitten über dem Text. position:fixed + !important überschreibt
               die Inline-Top/Left ohne Editor-Fork (Override-Schicht, CLAUDE.md). */
            .lt-badge {
              position: fixed !important;
              top: 12px !important;
              right: 16px !important;
              left: auto !important;
              transform: none !important;
            }
            /* Cursor-Konsistenz über der Schreibfläche. Die Textspalte
               (.focus-editor__content) ist schmal (max-width:60ch) + zentriert
               (margin:0 auto); auf breitem Fenster bleiben links/rechts grosse
               Leerränder, die zum NICHT editierbaren Eltern-Container gehören
               → dort zeigte WebKit den Default-Pfeil, über der Spalte den
               I-Beam. Das wirkte wie „mal Edit, mal Pfeil". Wir geben der
               ganzen aktiven Fläche den Text-Cursor; die Topbar (Buttons:
               pointer) bleibt davon ausgenommen. Override-Schicht statt
               Editor-Fork (CLAUDE.md). Auto-Hide (.focus-cursor-hidden →
               cursor:none auf .focus-editor__content) gewinnt weiterhin. */
            .focus-editor.is-active { cursor: text; }
            .focus-editor.is-active .focus-editor__topbar { cursor: default; }
            /* Popover/Menüs sind UI, keine Schreibfläche — der Zeiger muss dort
               IMMER sichtbar und normal sein. Sie hängen als Kind IN
               .focus-editor__content (das Popover reitet absichtlich im
               Scroll-Layer mit), darum trafen sie zwei Cursor-Regeln:
                 • unser `cursor: text` von oben (I-Beam über UI),
                 • die Auto-Hide-Regel des Editors
                   (`.focus-cursor-hidden .focus-editor__content *` → cursor:none).
               Letztere greift 2 s nach der letzten Mausbewegung wieder
               (focus/card.js `showCursor` bewaffnet den Timer unbedingt neu) —
               also genau, während man die Vorschläge liest: der Zeiger
               verschwand über der Popover-Fläche und tauchte erst über einem
               Vorschlag-Chip wieder auf („Cursor nach unten verrutscht").
               Unlayered + höhere Spezifität → gewinnt gegen beide (Editor-CSS
               liegt in @layer components). Override-Schicht statt Fork; der
               Fix gehört zusätzlich ins Hauptrepo (gleiche Wirkung im Web-SPA). */
            .focus-editor.is-active :is(.lt-popover, .synonym-menu, .synonym-picker, .figur-lookup),
            .focus-editor.is-active :is(.lt-popover, .synonym-menu, .synonym-picker, .figur-lookup) * {
              cursor: default;
            }
            .focus-editor.is-active :is(.lt-popover, .synonym-menu, .synonym-picker, .figur-lookup)
              :is(button, a, [role="button"], [role="option"]) {
              cursor: pointer;
            }
            /* Ruhige Leerfläche, wenn keine Seite offen ist (geschlossen / Boot
               ohne Seite). Liegt über der geleerten Schreibfläche und nimmt ihr
               jede Ablenkung: ein sanfter Verlauf in der Markenfläche + ein
               dezenter Hinweis, wie man eine Seite öffnet. Theme-treu über die
               Editor-CSS-Variablen (Light/Dark). Eingeblendet via body.sw-no-page. */
            #sw-empty {
              position: fixed; inset: 0; z-index: 30;
              display: none;
              flex-direction: column; align-items: center; justify-content: center;
              gap: 16px; padding: 48px; text-align: center;
              background:
                radial-gradient(135% 105% at 50% 14%,
                  color-mix(in srgb, var(--color-text, #1f1c18) 5%, transparent),
                  transparent 62%),
                var(--color-bg, #faf7f2);
              -webkit-user-select: none; user-select: none; cursor: default;
              animation: sw-empty-in .45s ease both;
            }
            body.sw-no-page #sw-empty { display: flex; }
            @keyframes sw-empty-in { from { opacity: 0 } to { opacity: 1 } }
            #sw-empty .sw-empty__mark {
              width: 46px; height: 46px;
              color: var(--color-text, #1f1c18); opacity: .26;
            }
            #sw-empty .sw-empty__title {
              margin: 0; font: 400 19px/1.4 var(--sw-font-family, ui-serif, Georgia, serif);
              color: var(--color-text, #1f1c18); opacity: .72;
            }
            #sw-empty .sw-empty__hint {
              margin: 0; font: 13px/1.5 -apple-system, system-ui, sans-serif;
              color: var(--color-text, #1f1c18); opacity: .42;
            }
            #sw-empty kbd {
              font: inherit; padding: 1px 7px; border-radius: 5px;
              background: color-mix(in srgb, var(--color-text, #1f1c18) 11%, transparent);
            }
          </style>
        </head>
        <body>
          <!-- Mount-Punkt für den Standalone-Focus-Editor. -->
          <div id="mount"></div>
          <div id="boot-status">Lade Editor…</div>

          <!-- Ruhige Leerfläche (keine Seite offen). Per body.sw-no-page eingeblendet. -->
          <div id="sw-empty">
            <svg class="sw-empty__mark" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
              <path d="M6 3 H13 L19 9 V21 H6 Z"/>
              <path d="M13 3 V9 H19"/>
            </svg>
            <p class="sw-empty__title">Keine Seite geöffnet</p>
            <p class="sw-empty__hint">Eine Seite öffnen mit <kbd>⌘O</kbd></p>
          </div>

          <script type="module">
            // Boot der nativen Schale: adaptiert die WKWebView-Bridge (window.__focusBridge:
            // load/save/list) auf den standalone-Bridge-Vertrag (loadPage/savePage) und
            // mountet die Focus-Engine. Die Bridge-Facade liegt at-document-start bereit
            // (WKUserScript). Im reinen Browser (ohne Swift) fehlt sie → Hinweis statt Crash.
            const status = document.getElementById('boot-status');
            const fb = window.__focusBridge;
            try {
              if (!fb) throw new Error('window.__focusBridge fehlt (kein nativer Kontext)');
              // Spellcheck-Nachzieh-Fn SEHR FRÜH der Facade unterlegen — noch
              // VOR dem ersten await (standalone-Import). Die
              // Funktionsdeklaration weiter unten ist im try-Block gehoisted,
              // darum ist `initSpellcheckIfEnabled` hier bereits im Scope. So
              // kann Swifts `pushDeferredSpellcheckInit` die Race gegen die
              // lange Modul-Importphase nicht verlieren — sobald das Boot-
              // Modul überhaupt läuft, hängt die FN an der Facade.
              window.__focusBridge._trySpellcheckInit = initSpellcheckIfEnabled;
              const { mountStandaloneFocus } = await import('./js/editor/focus/standalone.js');

              // baseUpdatedAt je Seite mitführen (für den nächsten Push / 409-Basis).
              const bases = new Map();
              // Offene Seite + ihr Buch — die Rechtschreibprüfung reicht die
              // bookId an den Server, der daraus die Locale (de-CH) auflöst.
              let currentPageId = null;
              let currentBookId = null;
              // Hatte der Boot eine echte Seite zu laden? Wenn nein (leeres/
              // ungesynctes Buch), startet die App in der ruhigen Leerfläche
              // statt mit einer leeren Schreibfläche.
              let bootHadPage = false;

        \(glueSpellcheckJS)
        \(glueCaretJS)
        \(glueHistoryJS)
        \(glueEventsJS)
        \(glueTypographyJS)
        \(glueStatsJS)
        \(glueMountJS)
        \(glueSynonymsJS)
            } catch (e) {
              status.className = 'err';
              status.textContent = 'Boot-Fehler: ' + (e && e.message ? e.message : e);
              fb?.log?.('Boot-Fehler: ' + e, 'error');
              console.error(e);
            }
          </script>
        </body>
        </html>
        """
    }
}
