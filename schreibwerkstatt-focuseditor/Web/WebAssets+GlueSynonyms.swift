//
//  WebAssets+GlueSynonyms.swift
//  schreibwerkstatt-focuseditor
//
//  Der Synonym-Teil des Boot-Glues: den gebündelten, Alpine-freien Controller aus
//  dem Hauptrepo einhängen (⌘⇧S) und den Toolbar-/Kontextmenü-Zwilling bedienen
//  (Swift→JS-Event `synonyms`, das synthetisch dessen Tastendruck feuert).
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
    /// Synonyme — Fragment des Boot-Moduls (s. Kopfdoku).
    static let glueSynonymsJS = """
              // ── Synonyme (Cmd+Shift+S) ──────────────────────────────────────
              // Wiederverwendet den Synonym-Controller aus dem Hauptrepo (kein
              // Fork). Thesaurus + KI laufen über die Bridge → Swift → Server
              // (OpenThesaurus synchron, KI als serverseitig fertig gepollter
              // Job). Greift nur, wenn lokal aktiviert UND das Bundle den
              // Controller mitliefert; sonst still übersprungen (online-only —
              // offline ohnehin kein Roundtrip). i18n kommt lokalisiert (de/en)
              // über die Bridge (synonymConfig.i18n) — kein hartkodierter String.
              // Der Controller hängt IMMER, wenn das Bundle ihn mitbringt; ob er
              // reagiert, entscheidet das Live-Flag (Einstellungen ▸ Schreiben,
              // Swift → `synonymConfig`-Event). Sonst wirkte der Schalter erst
              // nach einem Neustart, während Toolbar + Kontextmenü ihn sofort
              // zeigten.
              let synonymsEnabled = false;
              fb.on('synonymConfig', (p) => { synonymsEnabled = !!(p && p.enabled); });
              try {
                const scfg = await fb.synonymConfig();
                synonymsEnabled = !!(scfg && scfg.enabled);
                {
                  const mod = await import('./js/cards/editor-synonyme/controller.js');
                  // Range-Mutation + Caret + bubbelndes input-Event (markiert die
                  // Seite dirty) — derselbe geteilte Helper wie die Spellcheck-
                  // Ersetzung; keine Client-Kopie der Caret-Logik.
                  const { applySpellcheckReplacement } = await import('./js/editor/shared/apply-replacement.js');
                  const root = document.querySelector('.focus-editor__content');
                  if (mod && typeof mod.createSynonymController === 'function' && root) {
                    const I18N = (scfg && scfg.i18n) || {};
                    const i18n = (k, params) => {
                      let s = I18N[k] || k;
                      if (params) for (const kk in params) s = s.replace('{' + kk + '}', params[kk]);
                      return s;
                    };
                    const ctl = mod.createSynonymController({
                      root,
                      getBookId: () => currentBookId,
                      getPageId: () => currentPageId,
                      isEnabled: () => synonymsEnabled,
                      i18n,
                      onApplyReplacement: (range, text) => applySpellcheckReplacement(range, text),
                      // Transport über die Bridge (kein direkter fetch).
                      lookupThesaurus: async ({ word, bookId }) => {
                        const res = await fb.synonymsThesaurus({ word, bookId });
                        if (res && res.disabled) return { disabled: true, synonyme: [] };
                        return { synonyme: (res && res.synonyme) || [] };
                      },
                      // Der Swift-Kern pollt den Job fertig → EIN Ergebnis. Bei
                      // Fehler einen Fehler werfen (Controller zeigt KI-Fehler).
                      lookupAi: async ({ word, satz, bookId, pageId }) => {
                        const res = await fb.synonymsAi({
                          wort: word, satz, bookId,
                          pageId: pageId == null ? null : String(pageId),
                        });
                        if (res && res.disabled) return { disabled: true, synonyme: [] };
                        if (res && res.error) throw new Error(res.error);
                        return { synonyme: (res && res.synonyme) || [] };
                      },
                    });
                    ctl.attach();
                    window.__synonyms = ctl;

                    // ── Synonyme aus Toolbar/Kontextmenü auslösen (Swift → JS) ─
                    // Der Controller (SSoT, kein Fork) kennt nur seinen Hotkey
                    // ⌘⇧S auf dem Editor-Root — er exportiert keinen
                    // programmatischen Trigger. Statt ihn zu forken feuern wir
                    // genau dieses Tastenereignis synthetisch: der Controller
                    // erledigt dann seine eigene Wort-/Selektions-Logik
                    // (Auswahl oder Caret-Wort) unverändert. Der Klick in der
                    // Titelleiste nimmt der WebView den Fokus — Swift gibt ihn
                    // vorher zurück, hier zusätzlich der Editor-Fokus, damit die
                    // Selektion/der Caret wieder lebt.
                    //
                    // Kommt ein Punkt mit (Rechtsklick-Kontextmenü), wird der
                    // Caret vorher dorthin gesetzt: der Rechtsklick verschiebt
                    // ihn im contenteditable nicht zuverlässig, sonst käme das
                    // Synonym zum zuletzt bearbeiteten Wort statt zum
                    // angeklickten. Eine bestehende Auswahl, in die hinein
                    // geklickt wurde, bleibt unangetastet.
                    function caretToPoint(x, y) {
                      const sel = window.getSelection();
                      if (!sel) return;
                      if (sel.rangeCount > 0 && !sel.isCollapsed) {
                        const rects = sel.getRangeAt(0).getClientRects();
                        for (const rc of rects) {
                          if (x >= rc.left && x <= rc.right && y >= rc.top && y <= rc.bottom) return;
                        }
                      }
                      let r = null;
                      if (document.caretRangeFromPoint) {
                        r = document.caretRangeFromPoint(x, y);
                      } else if (document.caretPositionFromPoint) {
                        const p = document.caretPositionFromPoint(x, y);
                        if (p && p.offsetNode) {
                          r = document.createRange();
                          r.setStart(p.offsetNode, p.offset);
                          r.collapse(true);
                        }
                      }
                      if (!r || !root.contains(r.startContainer)) return;
                      sel.removeAllRanges();
                      sel.addRange(r);
                    }

                    fb.on('synonyms', (p) => {
                      if (!synonymsEnabled) return;
                      try {
                        // Bewusst `root` (nicht activeContent()) — genau das
                        // Element, auf dem der Controller lauscht und gegen das
                        // er die Selektion prüft.
                        if (document.activeElement !== root) root.focus?.();
                        if (p && typeof p.x === 'number' && typeof p.y === 'number') {
                          caretToPoint(p.x, p.y);
                        }
                        root.dispatchEvent(new KeyboardEvent('keydown', {
                          key: 's', code: 'KeyS',
                          metaKey: true, shiftKey: true,
                          bubbles: true, cancelable: true,
                        }));
                      } catch (e) {
                        fb.log?.('Synonyme-Trigger: ' + (e && e.message ? e.message : e), 'info');
                      }
                    });

                    fb.log?.('Synonyme aktiv');
                  }
                }
              } catch (e) {
                fb.log?.('Synonyme nicht verfügbar: ' + (e && e.message ? e.message : e), 'info');
              }
        """
}
