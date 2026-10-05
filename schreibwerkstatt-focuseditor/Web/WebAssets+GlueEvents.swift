//
//  WebAssets+GlueEvents.swift
//  schreibwerkstatt-focuseditor
//
//  Der Event-Teil des Boot-Glues: Seite laden/wechseln/schliessen, stiller
//  Server-Refresh, Anführungszeichen normalisieren — die Gegenstellen zu den
//  Swift→JS-Events auf dem Bus `window.__focusBridge.on(...)`.
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
    /// Seitenwechsel + Swift→JS-Events — Fragment des Boot-Moduls (s. Kopfdoku).
    static let glueEventsJS = """
              // ── Seitenwechsel / Server-Frische (Swift → JS Event-Bus) ───────
              // Der native Picker (⌘O) und die SyncEngine heben Seiten über die
              // Bridge in den Editor. Ohne diese Abos passiert beim Auswählen
              // einer Seite NICHTS (Event ohne Listener) → kein Seitenwechsel.
              // Inhalt frisch aus dem LocalStore ziehen (offline-first), damit
              // name/bookId/updatedAt konsistent zur loadPage-Logik sind.
              //
              // Rennen (Datenverlust-Schutz): Laden + Sichern sind Bridge-
              // Roundtrips (`load` ggf. sogar übers Netz). Währenddessen bleibt
              // die alte Seite editierbar, und ein zweiter Wechsel kann
              // dazwischenfahren. Darum:
              //  - Sequenz-Token: nur der JÜNGSTE Aufruf darf setPage ausführen;
              //    ein überholter kehrt nach jedem await still zurück.
              //  - Erst laden, DANN sichern: das Sichern ist der letzte await vor
              //    setPage, und es wiederholt sich, solange währenddessen getippt
              //    wurde (setPage verwirft den Autosave-Timer und das DOM).
              //  - Stiller Server-Refresh (`onlyIfClean`): nur, wenn die Seite
              //    noch die offene ist und seit dem Auftrag nicht getippt wurde.
              //    Liefert, ob der Reload übernommen wurde — Swift dreht sonst die
              //    Sync-Basis zurück, damit der nächste Push in den Merge läuft.
              //  - Ein Refresh weicht jedem Seitenwechsel aus (nicht umgekehrt):
              //    er zählt das Token nicht hoch und bricht ab, sobald ein
              //    Wechsel läuft oder dazwischenkommt.
              let applySeq = 0;
              let switchesInFlight = 0;
              async function applyPage(pageId, opts) {
                if (opts.onlyIfClean) return applyPageNow(pageId, opts);
                switchesInFlight++;
                try { return await applyPageNow(pageId, opts); } finally { switchesInFlight--; }
              }
              async function applyPageNow(pageId, { save, focus, onlyIfClean }) {
                const seq = onlyIfClean ? applySeq : ++applySeq;
                const pid = String(pageId);
                const inputAtStart = inputSeq;
                const stillClean = () => switchesInFlight === 0
                  && currentPageId === pid && inputSeq === inputAtStart
                  && !reportedDirty && !(window.__standalone && window.__standalone.host
                    && window.__standalone.host.editDirty);
                if (onlyIfClean && !stillClean()) return false;
                // Hatte die Schreibfläche gerade den Fokus? (für den stillen
                // Server-Refresh: dann Caret in-place wiederherstellen, statt ihn
                // beim setPage-DOM-Tausch lautlos wegspringen zu lassen.)
                const prev = activeContent();
                const wasFocused = !!(prev && prev.contains(document.activeElement));
                let page = null;
                try { page = await fb.load(pid); } catch (_) {}
                if (seq !== applySeq) return false;
                if (onlyIfClean && !stillClean()) return false;
                // Beim Picker-Wechsel den aktuellen Stand zuerst sichern
                // (local-first): setPage verwirft den Autosave-Timer, sonst
                // gingen offene Änderungen der bisherigen Seite verloren.
                if (save) {
                  for (let i = 0; i < 3; i++) {
                    const before = inputSeq;
                    try { await window.__standalone.save(); } catch (_) {}
                    if (seq !== applySeq) return false;
                    if (inputSeq === before) break;
                  }
                }
                // Caret der bisher offenen Seite merken (Session), BEVOR setPage
                // den Content-Knoten austauscht.
                saveCaret(currentPageId);
                hideEmpty();   // wieder eine Seite offen → ruhige Leerfläche weg
                bases.set(pid, page ? (page.updatedAt ?? null) : null);
                currentPageId = pid;
                currentBookId = (page && page.bookId != null) ? Number(page.bookId) : null;
                window.__standalone.setPage({
                  id: pageId,
                  name: (page && (page.pageName || page.title)) || 'Abschnitt',
                  html: (page && page.html != null) ? page.html : '<p><br></p>',
                });
                // Neu eingespielte Seite ist sauber → Swift/Toolbar nachziehen.
                reportEditorState(pid, false);
                // Undo gehört ab jetzt zur NEUEN Seite: WebKits Undo-Stack hängt
                // an der WebView, nicht am Inhalt — die Einträge der vorigen Seite
                // würden sonst als wirkungslose „Widerrufen"-Schritte stehenbleiben.
                clearUndoSoon();
                resetTextLen();
                // Stats nach dem Seitenwechsel neu zählen (setPage feuert kein input).
                try { window.__countStats && window.__countStats(); } catch (_) {}
                // Caret-Strategie:
                //  - Picker-Öffnen (focus:true): aktiv fokussieren, gemerkte
                //    Position wiederherstellen, sonst ans Ende.
                //  - Stiller Server-Refresh (focus undefined): NUR wenn die
                //    Schreibfläche schon den Fokus hatte, Caret in-place
                //    wiederherstellen — kein Fokus-Diebstahl aus Toolbar/anderer
                //    App, aber auch kein lautloses Caret-Wegspringen beim Sync-Tick.
                if (focus || wasFocused) {
                  const stored = caretByPage.get(pid);
                  focusEditor(typeof stored === 'number' ? { caretOffset: stored } : undefined);
                }
                return true;
              }

              // Inline-Formatierung über das Format-Menü (Swift → JS). Spiegelt
              // exakt die nativen ⌘B/⌘I/⌘U des contenteditable-Editors:
              // document.execCommand auf der aktuellen Auswahl. Vorher die aktive
              // Schreibfläche fokussieren, damit der Befehl greift, auch wenn der
              // Fokus formal beim Menü lag (die Textauswahl bleibt dabei erhalten).
              fb.on('format', (p) => {
                const cmd = p && p.command;
                if (!cmd) return;
                try {
                  const content = activeContent();
                  // preventScroll: der Fokus-Rückholer darf die Ansicht nicht
                  // verschieben (WebKit deckt die Auswahl sonst unten-ausgerichtet
                  // auf — ein Sprung mitten im Formatieren).
                  if (content) content.focus({ preventScroll: true });
                  document.execCommand(cmd, false, null);
                } catch (e) { console.error('[focus-bridge] format', e); }
              });

              // ── Widerrufen / Wiederherstellen (Swift → JS) ──────────────────
              // Der gebündelte Editor führt seine EIGENE, entprellte
              // Snapshot-Historie (SSoT `shared/edit-history.js`) und fängt ⌘Z in
              // der Seite selbst ab. In dieser Schale erreicht die Taste die
              // WebView nie — das Menü-Kürzel greift app-weit vorher —, darum
              // löst der Menüpunkt die Aktion über dieses Event aus (wie das
              // Format-Menü). Das Restore feuert selbst ein `input`-Event mit
              // `inputType: historyUndo/historyRedo`; daran hängen Dirty-Flag,
              // Autosave, Statistik und der Hinweis-Banner (s. noticeHistoryEdit).
              //
              // Älteres gecachtes Bundle ohne die Handle-API: dann bleibt nur
              // WebKits grober Stack (`execCommand`) — besser als ein totes ⌘Z.
              // Der nächste Start zieht das neue Bundle und damit die feine
              // Körnung.
              fb.on('history', (p) => {
                const action = p && p.action === 'redo' ? 'redo' : 'undo';
                try {
                  const content = activeContent();
                  if (content) content.focus({ preventScroll: true });
                  const handle = window.__standalone;
                  if (handle && typeof handle[action] === 'function') {
                    handle[action]();
                    return;
                  }
                  document.execCommand(action, false, null);
                } catch (e) {
                  fb.log?.('History-Aktion: ' + (e && e.message ? e.message : e), 'info');
                }
              });

              // ── Anführungszeichen normalisieren (Swift → JS) ────────────────
              // Zieht die typografischen Anführungszeichen der offenen Seite auf
              // den Buch-Stil (de-CH → «», de-DE → „" …). Nutzt die fetch-freien
              // Primitive des gebündelten quote-normalize.js (resolveQuoteStyle +
              // normalizeQuotes); die Buch-Locale kommt aus Swift (Server), weil
              // der modulinterne fetch('/booksettings/…') in der lokalen WebView
              // ins Leere liefe. normalizeQuotes mutiert direkt das DOM (kein
              // input-Event) → danach synthetisch ein input feuern (markiert
              // dirty, treibt Autosave + Stats) und sofort local-first sichern.
              // Fehlt das Modul (älteres gecachtes Bundle), wird still degradiert.
              fb.on('normalizeQuotes', async (p) => {
                if (!currentPageId) return;   // keine echte Seite offen
                try {
                  const content = activeContent();
                  if (!content) return;
                  const mod = await import('./js/editor/shared/quote-normalize.js');
                  if (!mod || typeof mod.normalizeQuotes !== 'function'
                      || typeof mod.resolveQuoteStyle !== 'function') return;
                  const style = mod.resolveQuoteStyle(
                    (p && p.language) || 'de', (p && p.region) || 'CH');
                  mod.normalizeQuotes(content, style);
                  content.dispatchEvent(new InputEvent('input', { bubbles: true }));
                  try { await window.__standalone.save(); } catch (_) {}
                  try { window.__countStats && window.__countStats(); } catch (_) {}
                } catch (e) {
                  fb.log?.('Anführungszeichen: ' + (e && e.message ? e.message : e), 'info');
                }
              });

              // Nativer Picker → andere Seite öffnen (vorher aktuellen Stand sichern).
              fb.on('openPage', (p) => {
                if (!p || p.pageId == null) return;
                applyPage(p.pageId, { save: true, focus: true });
              });
              // Saubere offene Seite wurde serverseitig aktualisiert → still neu
              // laden. Awaitbarer Direktaufruf statt Event-Bus: Swift braucht die
              // Antwort. Swifts Sicht auf „offen + sauber" ist über die IPC
              // immer etwas alt — darum prüft der Editor hier SELBST (Seite noch
              // offen, nicht getippt) und lehnt sonst ab (`false`). `force`
              // (Konflikt „Server übernehmen") ersetzt bewusst auch eine dirty
              // Seite, aber nur, wenn sie noch die offene ist.
              fb._serverUpdate = async (p) => {
                if (!p || p.pageId == null) return false;
                if (p.force) {
                  if (currentPageId !== String(p.pageId)) return false;
                  return await applyPage(p.pageId, { save: false });
                }
                return await applyPage(p.pageId, { save: false, onlyIfClean: true });
              };
              // Seite schliessen (Buchwechsel ODER bewusst über die Toolbar):
              // aktuellen Stand sichern (local-first), die Schreibfläche leeren
              // und die ruhige Leerfläche einblenden. Swift öffnet danach den
              // Picker. Kein Datenverlust — der Stand wurde vorher gespeichert.
              fb.on('closePage', async () => {
                applySeq++;   // ein noch laufender Seitenwechsel darf danach nicht mehr öffnen
                saveCaret(currentPageId);   // Position für späteres Wieder-Öffnen merken
                // currentPageId VOR dem Sichern leeren: savePage meldet den
                // Zustand nur für die offene Seite — sonst meldete der Save die
                // eben geschlossene Seite Swift gegenüber kurz wieder als offen.
                currentPageId = null;
                try { await window.__standalone.save(); } catch (_) {}
                currentBookId = null;
                try {
                  window.__standalone.setPage({ id: '', name: '', html: '<p><br></p>' });
                } catch (_) {}
                // Geschlossene Seite → kein Undo mehr, das in eine leere
                // Schreibfläche hineingreifen könnte.
                clearUndoSoon();
                resetTextLen();
                showEmpty();
                reportEditorState(null, false);
                try { window.__countStats && window.__countStats(); } catch (_) {}
              });

        """
}
