//
//  WebAssets+GlueSpellcheck.swift
//  schreibwerkstatt-focuseditor
//
//  Der Spellcheck-Teil des Boot-Glues: `initSpellcheckIfEnabled()`.
//
//  Verdrahtet den UNVERÄNDERTEN Editor-Controller aus dem Hauptrepo mit der
//  Bridge (statt direktem `fetch`) und deckt die Offline-Boot-Lücke ab — Swift
//  ruft die Funktion über `_trySpellcheckInit` erneut auf, sobald der Server in
//  der Sitzung erreichbar war.
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
    /// Rechtschreibprüfung — Fragment des Boot-Moduls (s. Kopfdoku).
    static let glueSpellcheckJS = """
              // ── Rechtschreibprüfung (LanguageTool) ──────────────────────────
              // Wiederverwendet den unveränderten Editor-Controller aus dem
              // Hauptrepo (kein Fork). Statt direktem fetch laufen Prüfung +
              // Wörterbuch über die Bridge → Swift-Kern → Server-Proxy. Greift
              // nur, wenn LT serverseitig aktiv ist UND das Bundle den Controller
              // mitliefert; sonst still übersprungen (degradiert sauber, offline
              // ohnehin kein Prüf-Roundtrip — kein Offline-Kern-Inhalt).
              //
              // Idempotent (`if (window.__spellcheck) return`): der Boot ruft
              // sie einmal synchron auf; Swift drückt sie über die
              // Facade-`_trySpellcheckInit` ein ZWEITES Mal nach, sobald der
              // Server in der Sitzung erreichbar war — deckt die Offline-Boot-
              // Lücke: ohne Konnektivität beim Start lief `spellcheckConfig`
              // leer (`{enabled:false}`) zurück, der Controller wurde nie
              // importiert/mounted, und nachher kam keine Konnektivität mehr.
              // Der zweite Aufruf holt das nach; der erste bleibt No-op, falls
              // der Boot schon attached hat. Funktionsdeklaration im try-Block
              // ist gehoisted → die Zuweis ganz oben greift vor jeglichem await.
              //
              // Boot und Swift-Nachzug landen beim Start oft gleichzeitig. Der
              // Attach-Merker `__spellcheck` steht erst nach zwei awaits — darum
              // teilen sich parallele Aufrufe EIN laufendes Promise (sonst hingen
              // zwei Controller mit doppelten Listenern am Root). Ergebnis für
              // Swift: `true` = entschieden (attached oder serverseitig aus),
              // `null` = noch nicht möglich (offline, Editor noch nicht gemountet)
              // → Swift versucht es beim nächsten Sync-Tick erneut. Der Merker
              // hängt an der Facade statt an einem `let`, weil Swift die Funktion
              // schon während des Modul-Imports rufen kann.
              async function initSpellcheckIfEnabled() {
                if (window.__spellcheck) return true;   // schon attached → nichts tun
                if (!fb._spellcheckInitRun) {
                  fb._spellcheckInitRun = initSpellcheckNow()
                    .finally(() => { fb._spellcheckInitRun = null; });
                }
                return fb._spellcheckInitRun;
              }
              async function initSpellcheckNow() {
                let cfg;
                try {
                  cfg = await fb.spellcheckConfig();
                } catch (e) {
                  fb.log?.('Spellcheck-Config nicht abrufbar: ' + (e && e.message ? e.message : e), 'info');
                  return null;
                }
                if (!cfg || !cfg.enabled) return true;
                if (window.__spellcheck) return true;
                try {
                  const mod = await import('./js/cards/editor-spellcheck/controller.js');
                  // Range-Mutation + Caret-Restore aus dem gebündelten Helper
                  // (geteilt mit dem SPA-Dispatcher des Hauptrepos) — keine
                  // Client-Kopie der Caret-Logik. Kommt per OTA-Bundle.
                  const { applySpellcheckReplacement } = await import('./js/editor/shared/apply-replacement.js');
                  const root = document.querySelector('.focus-editor__content');
                  if (mod && typeof mod.createSpellcheckController === 'function' && root) {
                    // Popover-/Status-Strings kommen lokalisiert (de/en) über
                    // die Bridge (cfg.i18n, aus t()) — kein hartkodierter UI-
                    // String. Fallback auf den rohen Key, falls der Controller
                    // einen Key anfragt, den die Bridge (noch) nicht liefert.
                    const I18N = (cfg && cfg.i18n) || {};
                    const ctl = mod.createSpellcheckController({
                      root,
                      scrollContainer: root,            // .focus-editor__content ist Root UND Scroller
                      getHtml: () => root.innerHTML,
                      editorKind: 'focus',
                      getBookLocale: () => 'auto',       // Server löst Locale via bookId auf
                      getBookId: () => currentBookId,
                      getPageId: () => currentPageId,
                      isEnabled: () => true,
                      getDebounceMs: () => Number(cfg.debounceMs) || 1500,
                      i18n: (k) => I18N[k] || k,
                      onApplyReplacement: (range, text) => applySpellcheckReplacement(range, text),
                      // Transport über die Bridge (kein direkter fetch).
                      checkText: async ({ text, language, bookId, pageId }) => {
                        const res = await fb.languagetoolCheck({
                          text, language, bookId,
                          pageId: pageId == null ? null : String(pageId),
                        });
                        if (res && res.disabled) return { disabled: true };
                        return { matches: (res && res.matches) || [] };
                      },
                      addWord: async ({ word, bookId, lang }) => {
                        const res = await fb.dictionaryAdd({ word, bookId, lang });
                        return !!(res && res.ok);
                      },
                    });
                    ctl.attach();
                    window.__spellcheck = ctl;
                    fb.log?.('Rechtschreibprüfung aktiv');
                    return true;
                  }
                  // Kein Controller im (älteren) Bundle → endgültig; fehlt nur
                  // der Root (Editor noch nicht gemountet) → später erneut.
                  return root ? true : null;
                } catch (e) {
                  fb.log?.('Rechtschreibung nicht verfügbar: ' + (e && e.message ? e.message : e), 'info');
                  return null;
                }
              }
              // `_trySpellcheckInit` wurde ganz oben (vor dem ersten await)
              // zugewiesen — siehe die Erläuterung dort.

              // Ruhige Leerfläche ein-/ausblenden (keine Seite offen).
              const showEmpty = () => document.body.classList.add('sw-no-page');
              const hideEmpty = () => document.body.classList.remove('sw-no-page');

        """
}
