//
//  WebAssets+GlueTypography.swift
//  schreibwerkstatt-focuseditor
//
//  Der Darstellungs-Teil des Boot-Glues: Fokus-Granularität (CSS-Klasse
//  `focus-mode--<value>`) und Typografie (CSS-Custom-Properties + EIN injiziertes
//  `<style>`, das `.focus-editor__content` überschreibt).
//
//  Bewusst eine Override-Schicht ÜBER dem unveränderten Editor-CSS — kein Fork.
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
    /// Fokus-Granularität + Typografie — Fragment des Boot-Moduls (s. Kopfdoku).
    static let glueTypographyJS = """
              // ── Fokus-Granularität live umschalten (Swift → JS) ─────────────
              // Nur über den öffentlichen Handle-Hook `setGranularity` (Vertrag
              // contract/editor-api.d.ts) — er kapselt Klassentausch + Overlay-
              // Neuberechnung in der Engine. Kein Nachbau über Interna
              // (`controller._*`, `host.*`): die darf der Server ohne Ankündigung
              // ändern. Ist der Editor noch nicht gemountet, gibt es nichts
              // umzuschalten — der Mount liest die Stufe selbst (`bridge.granularity`).
              function applyGranularity(g) {
                const handle = window.__standalone;
                if (handle && typeof handle.setGranularity === 'function') {
                  handle.setGranularity(g);
                }
              }
              fb.on('focusGranularity', (p) => {
                if (p && p.granularity) applyGranularity(p.granularity);
              });

              // ── Editor-Typografie (Schriftgrösse/Zeilenhöhe/measure/…) ──────
              // Override-Schicht ÜBER dem unveränderten Editor-CSS (kein Fork):
              // CSS-Custom-Properties auf :root + EIN persistentes <style>, das
              // den Editor-Content überschreibt. Überlebt setPage (greift nicht
              // in den Content-Baum ein). Werte kommen CSS-fertig aus Swift.
              function applyTypography(t) {
                if (!t) return;
                const root = document.documentElement;
                if (t.fontSize)   root.style.setProperty('--sw-font-size', t.fontSize);
                if (t.lineHeight) root.style.setProperty('--sw-line-height', t.lineHeight);
                if (t.measure)    root.style.setProperty('--sw-measure', t.measure);
                if (t.fontFamily) root.style.setProperty('--sw-font-family', t.fontFamily);
                // Papier-Ton: null = keine Überschreibung (System-/Theme-Fläche).
                if (t.paperBg)   root.style.setProperty('--sw-paper-bg', t.paperBg);
                else             root.style.removeProperty('--sw-paper-bg');
                if (t.paperText) root.style.setProperty('--sw-paper-text', t.paperText);
                else             root.style.removeProperty('--sw-paper-text');
                root.setAttribute('data-sw-paper', (t.paperBg ? 'custom' : 'system'));
                // Fokus-Abdunklung: null = Editor-Default (kein Override, theme-
                // korrekt); sonst Opazität der nicht-aktiven Absätze überschreiben.
                if (t.focusDim != null) {
                  root.style.setProperty('--sw-focus-dim', t.focusDim);
                  root.setAttribute('data-sw-dim', 'custom');
                } else {
                  root.style.removeProperty('--sw-focus-dim');
                  root.removeAttribute('data-sw-dim');
                }

                let style = document.getElementById('sw-native-typography');
                if (!style) {
                  style = document.createElement('style');
                  style.id = 'sw-native-typography';
                  style.textContent = [
                    '.focus-editor__content {',
                    '  font-size: var(--sw-font-size, 19px) !important;',
                    '  line-height: var(--sw-line-height, 1.7) !important;',
                    '  font-family: var(--sw-font-family, ui-serif, Georgia, serif) !important;',
                    // Der Scroller füllt die GANZE Fläche; die Spaltenbreite
                    // (measure) macht das Padding, nicht max-width.
                    // Grund: .focus-editor__content ist selbst der Scroller
                    // (focus-mode.css: overflow-y:auto). Mit `max-width:60ch;
                    // margin:0 auto` gehörten die breiten Leerränder
                    // links/rechts zum NICHT scrollbaren Eltern-Container —
                    // das Mausrad dort traf keinen Scroller (html/body sind
                    // overflow:hidden), das Scrollen „ging nur manchmal",
                    // nämlich nur mit Zeiger über der Textspalte. Padding statt
                    // max-width: gleiche Zeilenlänge, aber die ganze Fläche
                    // scrollt (Klick ins Padding fängt der SSoT-mousedown-
                    // Handler weiterhin ab → kein Caret-Sprung).
                    // border-box nötig, weil die Bundle-CSS keinen globalen
                    // Reset mitbringt (sonst width:100% + Padding = Überlauf).
                    '  box-sizing: border-box !important;',
                    '  max-width: none !important;',
                    '  margin-inline: 0 !important;',
                    // `--sw-measure: none` (Spaltenbreite aus) macht das calc()
                    // ungültig → Deklaration fällt weg, das Editor-Padding
                    // (2rem) greift: full-bleed wie bisher.
                    '  padding-inline: max(2rem, calc((100% - var(--sw-measure, 0px)) / 2)) !important;',
                    // Tail-Puffer: die SSoT rechnet unten
                    // `calc(100vh - --focus-vh * --focus-anchor)` (focus-mode.css,
                    // Desktop also 50 vh) — der Typewriter BRAUCHT diese Strecke,
                    // damit auch die LETZTE Zeile die Schreiblinie erreicht (ein
                    // kürzerer Tail klemmte den Scroll: „man kommt nur bis zum
                    // zweitletzten Absatz", und der geklemmte `scrollBy` liess den
                    // SSoT-Counter `expectedScroll` leaken → Spotlight blieb beim
                    // Blättern stehen). Kopf + Tail summieren sich damit auf exakt
                    // die Höhe der Schreibfläche (100 vh) — und genau das ist in
                    // WebKit der Bug: erreicht `padding-top + padding-bottom` die
                    // `clientHeight` des Scrollers, lässt sich in einem
                    // contenteditable KEIN Wort mehr auswählen. Die Selektion
                    // springt vom Klickpunkt bis zum Absatzende (gemessen in
                    // WebKit 26.5: Doppelklick liefert anchorOffset 39 →
                    // focusOffset 134 = Absatzende; ein Zieh-Select bleibt leer).
                    // Dieselbe Ursache traf die Live-Zählung: `innerText` der
                    // Schreibfläche kam als "\\n" (Länge 1) zurück, obwohl
                    // `textContent` 156 Zeichen hatte → Toolbar zeigte konstant
                    // „1 Zeichen" (Gegenprobe unten in `renderedText`).
                    // Bei Summe `clientHeight - 1px` funktioniert alles; Chromium
                    // ist nicht betroffen. Darum hier 4 px kürzen: die Summe
                    // bleibt unter der Schreibflächen-Höhe (in dieser Schale ist
                    // sie identisch mit `100vh` — die Schreibfläche liegt
                    // `fixed; inset: 0`, es gibt keine Topbar), und die letzte
                    // Zeile ruht 4 px über dem Anker statt genau darauf (unter der
                    // Typewriter-Dead-Zone, also unsichtbar).
                    // Gehört mittelfristig ins Hauptrepo (dort trifft es Safari
                    // und iOS ebenso, und die SPA-Schreibfläche ist wegen der
                    // Topbar noch kürzer als 100 vh); danach kann diese
                    // Deklaration wieder weg.
                    '  padding-bottom: calc(100vh - var(--focus-vh, 100vh) * var(--focus-anchor, 0.5) - 4px) !important;',
                    // Schreib-Caret in Marken-Gold — ein dezenter Identitäts-
                    // Akzent genau dort, wo geschrieben wird. Ein Ton, der auf
                    // hellem wie dunklem Papier trägt (kein Theme-Switch nötig).
                    '  caret-color: #b08d3f !important;',
                    '}',
                    // Papier-Ton nur, wenn gesetzt — sonst bleibt die native,
                    // transparente Brand-Fläche (Light/Dark) sichtbar.
                    ':root[data-sw-paper="custom"] body,',
                    ':root[data-sw-paper="custom"] .focus-editor {',
                    '  background: var(--sw-paper-bg) !important;',
                    '  color: var(--sw-paper-text) !important;',
                    '}',
                    // Fokus-Abdunklung: überschreibt NUR die Variable, die der
                    // Editor selbst liest (focus-mode.css: `--focus-dim-opacity`
                    // auf .focus-editor, ausgewertet an den gedimmten Blöcken) —
                    // statt den Dim-Selektor zu replizieren. Ändert das Hauptrepo
                    // welche Blöcke dimmen, folgt der Override automatisch (keine
                    // Kopplung an CSS-Interna). Spezifität (0,2,0) schlägt die
                    // Basisregel .focus-editor (0,1,0); greift nur bei data-sw-dim.
                    ':root[data-sw-dim="custom"] .focus-editor {',
                    '  --focus-dim-opacity: var(--sw-focus-dim) !important;',
                    '}',
                    // Sentence-Modus-Dim an denselben Override koppeln. Der
                    // Block-Dim ist Opazität auf der Papier-Textfarbe; der
                    // Sentence-Dim MUSS eine Farbe sein (Custom Highlight API
                    // kennt kein opacity). color-mix rekonstruiert dieselbe
                    // effektive Farbe: Papier-/Theme-Text bei der Dim-Opazität.
                    // Ohne das bliebe der Sentence-Dim auf dem hartcodierten
                    // Token (--color-focus-sentence-dim) stehen und passte bei
                    // custom Papier/Dim nicht zum Block-Dim. Token-Fallback
                    // greift weiter, solange weder Papier noch Dim custom sind.
                    ':root[data-sw-dim="custom"] ::highlight(focus-sentence-dim) {',
                    '  color: color-mix(in srgb, var(--color-text) calc(var(--sw-focus-dim) * 100%), transparent);',
                    '}',
                    ':root[data-sw-paper="custom"] ::highlight(focus-sentence-dim) {',
                    '  color: color-mix(in srgb, var(--sw-paper-text, var(--color-text)) calc(var(--sw-focus-dim, 0.35) * 100%), transparent);',
                    '}',
                  ].join('\\n');
                  document.head.appendChild(style);
                }
              }
              fb.on('editorTypography', (t) => applyTypography(t));
              // Boot-Pull: initiale Typografie ziehen und anwenden.
              try { applyTypography(await fb.editorTypography()); } catch (_) {}

        """
}
