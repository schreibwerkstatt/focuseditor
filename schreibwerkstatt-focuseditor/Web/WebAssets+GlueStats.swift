//
//  WebAssets+GlueStats.swift
//  schreibwerkstatt-focuseditor
//
//  Der Statistik-Teil des Boot-Glues: Wörter/Zeichen der offenen Seite zählen und
//  entprellt an Swift melden (`reportStats`). Treibt Toolbar-Anzeige, Schreibziel,
//  Tages-Delta — und über `bridge.onActivity` die Idle-Erkennung der Schreibzeit.
//
//  Teil des EINEN Boot-Moduls in [WebAssets+IndexHTML.swift](WebAssets+IndexHTML.swift):
//  die Fragmente teilen sich einen JS-Scope (`fb`, `currentPageId`, die Helfer)
//  und werden dort in fester Reihenfolge zusammengesetzt. Aufgeteilt, weil die
//  eine Datei über 1200 Zeilen gewachsen und der einzige Eintrag in der
//  Allowlist des Zeilen-Guards war — nicht, weil die Teile unabhängig wären.
//  Reihenfolge und Einrückung sind darum bindend; `WebAssetsSyntaxTests` lässt
//  `node --check` über das zusammengesetzte Ergebnis laufen.
//

import Foundation

extension WebAssets {
    /// Lebende Schreibstatistik — Fragment des Boot-Moduls (s. Kopfdoku).
    static let glueStatsJS = """
              // ── Lebende Schreibstatistik (Wörter/Zeichen) ───────────────────
              // Zählt den Text der offenen Seite und meldet ihn debounced an
              // Swift (Toolbar-Stats + Schreibziel). Liest .focus-editor__content
              // (Root der Schreibfläche, denselben Knoten nutzt die Spellcheck).
              (function () {
                let statsTimer = null;
                // Textlänge des letzten Zähllaufs (textContent, NICHT innerText):
                // billiges Änderungs-Gate ohne Layout-Reflow.
                let lastTcLen = -1;
                // Gerenderter Text der Schreibfläche. `innerText` ist die richtige
                // Metrik (kennt Block-Grenzen; `textContent` klebt Absätze ohne
                // Leerzeichen zusammen und würde Wörter verschmelzen) — WebKit
                // liefert sie aber GENAU DANN kaputt, wenn `padding-top +
                // padding-bottom` die `clientHeight` des Scrollers erreicht:
                // dieselbe Rendered-Text-/VisiblePosition-Machinerie, die dann
                // auch die Wortselektion bricht (s. padding-bottom-Kommentar
                // oben). Gemessen in WebKit 26.5: innerText == "\\n" (Länge 1)
                // bei 156 Zeichen textContent — die Toolbar zeigte konstant
                // „1 Zeichen". Weil "\\n" truthy ist, griff der alte
                // `|| textContent`-Fallback nicht. Darum hier explizit auf
                // leeren Rendered-Text prüfen und die Blöcke einzeln aus
                // textContent zusammensetzen (Wortgrenzen bleiben erhalten).
                function renderedText(root) {
                  const it = root.innerText || '';
                  if (it.trim().length > 0) return it;
                  const tc = root.textContent || '';
                  if (tc.trim().length === 0) return tc;   // wirklich leere Seite
                  const sel = 'p, h1, h2, h3, h4, h5, h6, li, blockquote, pre';
                  const parts = [];
                  root.querySelectorAll(sel).forEach(function (b) {
                    // Nur Blatt-Blöcke, sonst zählt verschachtelter Text doppelt.
                    if (!b.querySelector(sel)) parts.push(b.textContent || '');
                  });
                  return parts.length ? parts.join('\\n') : tc;
                }
                // `typed`: Zählung aus echter Eingabe (input-Event). Seitenwechsel,
                // stiller Server-Refresh, Schliessen und die Erstzählung melden
                // `false` — Swift darf sie weder als Tippaktivität (Idle-Uhr der
                // Schreibzeit) noch als „heute geschrieben" werten; sonst zählte
                // eine Änderung von einem anderen Gerät als eigene Arbeit.
                function countAndReport(typed) {
                  const root = document.querySelector('.focus-editor__content');
                  // textContent.length zuerst greifen (kein Reflow) und merken,
                  // damit das Gate unten dieselbe Metrik vergleicht.
                  lastTcLen = root && root.textContent ? root.textContent.length : 0;
                  const text = root ? renderedText(root) : '';
                  const trimmed = text.trim();
                  const words = trimmed ? trimmed.split(/\\s+/).length : 0;
                  const chars = text.replace(/\\u00a0/g, ' ').length;
                  try { fb.reportStats(words, chars, currentPageId, typed === true); } catch (_) {}
                }
                window.__countStats = countAndReport;
                // Der eigentliche Zähllauf liest innerText → erzwingt ein Layout.
                // In eine Idle-Phase legen (requestIdleCallback), damit er nie mit
                // dem Tastatur-Rendering konkurriert; Fallback setTimeout, falls die
                // WebView-Engine rIC nicht kennt.
                const ric = window.requestIdleCallback
                  || function (cb) { return setTimeout(function () { cb(); }, 200); };
                function scheduleCount() {
                  const root = document.querySelector('.focus-editor__content');
                  const len = root && root.textContent ? root.textContent.length : 0;
                  // Reiner Format-/Selektions-Input ohne Längenänderung → nichts zu
                  // zählen (spart den Reflow). Echtes Tippen ändert die Länge.
                  if (len === lastTcLen) return;
                  ric(function () { countAndReport(true); }, { timeout: 1000 });
                }
                // Debounced bei Eingabe (input bubblet vom Content nach oben).
                document.addEventListener('input', function () {
                  if (statsTimer) clearTimeout(statsTimer);
                  statsTimer = setTimeout(scheduleCount, 500);
                }, true);
                // Initiale Zählung (nach dem ersten Mount/loadPage).
                setTimeout(countAndReport, 150);
              })();

        """
}
