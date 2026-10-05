//
//  WebAssets+GlueCaret.swift
//  schreibwerkstatt-focuseditor
//
//  Der Caret-Teil des Boot-Glues: Position merken/wiederherstellen, Schreibfläche
//  fokussieren, Anker halten, während das Layout sich setzt.
//
//  Der Standalone-Editor mountet direkt im Fokus-Modus, setzt aber selbst KEINEN
//  Caret (im Web-SPA kommt der Nutzer schon mit gesetztem Cursor aus dem
//  Edit-Modus). Diese Hülle übernimmt das, damit eine frisch geöffnete Seite
//  sofort beschreibbar ist.
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
    /// Caret-Handling — Fragment des Boot-Moduls (s. Kopfdoku).
    static let glueCaretJS = """
              // ── Caret-Handling (Client-Glue) ───────────────────────────────
              // Der Standalone-Editor mountet direkt im Fokus-Modus, setzt aber
              // selbst KEINEN Caret (im Web-SPA kommt der Nutzer schon mit
              // gesetztem Cursor aus dem Edit-Modus). Diese Hülle übernimmt das
              // Caret-Setzen, damit eine frisch geöffnete Seite sofort
              // beschreibbar ist — ohne erst hineinzuklicken.

              // Aktive Schreibfläche (oder die einzige, falls noch nicht „is-active").
              function activeContent() {
                return document.querySelector('.focus-editor.is-active .focus-editor__content')
                  || document.querySelector('.focus-editor__content');
              }

              // Zeichen-Offset des Carets relativ zum Anfang des Inhalts — robust
              // gegen DOM-Umbau (Block-Knoten, Formatierung), weil rein über die
              // sichtbare Textlänge gemessen. Gerätelokal & nur für die Session.
              const caretByPage = new Map();   // pageId → Zeichen-Offset

              function caretCharOffset(content) {
                try {
                  const sel = document.getSelection();
                  if (!sel || sel.rangeCount === 0) return null;
                  const r = sel.getRangeAt(0);
                  if (!content.contains(r.startContainer)) return null;
                  const pre = document.createRange();
                  pre.selectNodeContents(content);
                  pre.setEnd(r.startContainer, r.startOffset);
                  return pre.toString().length;
                } catch (_) { return null; }
              }

              // Caret der offenen Seite vor einem Seitenwechsel/Refresh sichern.
              function saveCaret(pageId) {
                if (pageId == null) return;
                const content = activeContent();
                if (!content) return;
                const off = caretCharOffset(content);
                if (off != null) caretByPage.set(String(pageId), off);
              }

              // Caret an einen Zeichen-Offset setzen — in den passenden Textknoten
              // hinein (nicht an die Element-Grenze der Root, was den ersten
              // Tastendruck aus dem Absatz fallen liesse). Übersteigt der Offset
              // den Inhalt (Server-Stand kürzer geworden) → ans Ende.
              function placeCaretAtOffset(content, offset) {
                const sel = document.getSelection();
                if (!sel) return false;
                const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, null);
                let remaining = offset, node, last = null;
                while ((node = walker.nextNode())) {
                  last = node;
                  const len = node.nodeValue.length;
                  if (remaining <= len) {
                    const range = document.createRange();
                    range.setStart(node, remaining);
                    range.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(range);
                    return true;
                  }
                  remaining -= len;
                }
                if (last) {
                  const range = document.createRange();
                  range.setStart(last, last.nodeValue.length);
                  range.collapse(true);
                  sel.removeAllRanges();
                  sel.addRange(range);
                  return true;
                }
                return false;
              }

              // Caret ans Ende des Inhalts — in den letzten Textknoten hinein
              // (bzw. in den letzten Block bei leerer Seite), nicht an die Root-
              // Grenze (contenteditable-Falle: Tippen landete sonst ausserhalb
              // eines Absatzes).
              function placeCaretAtEnd(content) {
                const sel = document.getSelection();
                if (!sel) return;
                const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, null);
                let last = null, n;
                while ((n = walker.nextNode())) last = n;
                const range = document.createRange();
                if (last) {
                  range.setStart(last, last.nodeValue.length);
                  range.collapse(true);
                } else {
                  // Kein Textknoten (leerer Absatz <p><br></p>) → in den letzten Block.
                  range.selectNodeContents(content.lastElementChild || content);
                  range.collapse(true);
                }
                sel.removeAllRanges();
                sel.addRange(range);
              }

              // Typewriter-Geometrie aus dem OTA-Bundle (SSoT) — dieselben
              // Funktionen, mit denen die Engine beim Tippen scrollt. Lazy und
              // gecacht; fehlt das Modul (älteres Bundle), degradiert das
              // Anker-Ziehen still (try/catch wie bei Spellcheck/Synonymen).
              let twModPromise = null;
              function typewriterModule() {
                if (!twModPromise) {
                  twModPromise = import('./js/editor/focus/typewriter.js').catch(() => null);
                }
                return twModPromise;
              }

              // Rect der Caret-Zeile, mit Block-Fallback. Der Schreib-Slot am
              // Seitenende ist regelmässig ein LEERER `<p><br></p>` — dort liefert
              // `getCaretRect` null (keine Textknoten, collapsed Range). Dann zählt
              // das Block-Rect; bei einem Ein-Zeilen-Absatz sind beide deckungs-
              // gleich (dieselbe Wahl trifft die SSoT in scrollEntryTargetToAnchor).
              function caretLineRect(tw, content) {
                const direct = tw.getCaretRect(content);
                if (direct) return direct;
                try {
                  const sel = document.getSelection();
                  if (!sel || sel.rangeCount === 0) return null;
                  const n = sel.getRangeAt(0).startContainer;
                  const el = n.nodeType === 1 ? n : n.parentElement;
                  const block = el && el.closest
                    ? el.closest('p, h1, h2, h3, h4, h5, h6, blockquote, li, pre')
                    : null;
                  return (block || el) ? (block || el).getBoundingClientRect() : null;
                } catch (_) { return null; }
              }

              // Schreibzeile auf die Schreiblinie (Typewriter-Anker) ziehen.
              //
              // Der frühere Weg — `scrollIntoView({block:'center'})`, und das nur
              // falls der Caret ausserhalb des Viewports liegt — war doppelt falsch:
              //  1) `content.focus()` OHNE `preventScroll` lässt WebKit die Auswahl
              //     selbst „aufdecken", und zwar UNTEN-ausgerichtet. Danach liegt die
              //     Zeile knapp im Viewport → die Bedingung greift nicht mehr, die
              //     Zentrierung blieb aus. Gemessen: Seite öffnet mit scrollTop 5014
              //     statt 5479 (max 5499), letzter Absatz klebt bei 934–967 px in
              //     einem 971-px-Fenster statt auf der Linie bei ~485 px — knapp eine
              //     halbe Bildschirmhöhe Scrollweg blieb unbenutzt („man kommt nicht
              //     bis zum letzten Absatz").
              //  2) „Mitte der Scroll-Box" ist nicht der Anker: der Typewriter hält
              //     die Zeile auf `--focus-anchor` (Default 0.5, konfigurierbar).
              //     Zwei Geometrien für dieselbe Linie driften auseinander.
              // Darum jetzt exakt die SSoT-Geometrie (`typewriterScroll`, Schwelle 0)
              // — dieselbe Strecke, die die Engine beim Tippen fährt.
              async function anchorCaretLine(threshold) {
                const tw = await typewriterModule();
                const content = activeContent();
                if (!tw || !content) return;
                try {
                  const rect = caretLineRect(tw, content);
                  // `undefined` als Anker → die SSoT normalisiert auf den Default
                  // (0.5); ein eigener Wert wäre eine zweite Wahrheit neben
                  // `--focus-anchor`.
                  if (rect) tw.typewriterScroll(content, rect, null, threshold || 0, undefined);
                } catch (_) {}
              }

              // Anker-Ziehen, solange sich das Layout noch setzt. Beim Öffnen ist es
              // ~1 s lang in Bewegung: Typografie-Override (font-size/line-height),
              // Webfont-Ladung und `--focus-vh` (Fenster-/Toolbar-Geometrie steht
              // erst nach dem ersten Layout — gemessen bei ~720 ms von 976 auf
              // 971 px). Ein einzelner Schuss beim Öffnen landet darum auf einer
              // Höhe, die es gleich danach nicht mehr gibt (oder wird am dann noch
              // kürzeren Scroll-Ende geklemmt). Schwelle 2 px: steht das Layout,
              // sind die Wiederholungen No-ops. Jede echte Nutzer-Aktion (Rad,
              // Klick, Taste) bricht ab — nachgezogen wird nur ungefragt, solange
              // niemand selbst navigiert.
              let anchorToken = 0;
              let anchorAbort = null;
              function anchorCaretWhileSettling() {
                const token = ++anchorToken;
                // Lauf-Ende räumt die Abbruch-Listener ab (ein AbortController pro
                // Lauf, der vorige wird beendet) — sonst sammelte jeder
                // Seitenwechsel drei nie gefeuerte Listener an.
                anchorAbort?.abort();
                const ctl = new AbortController();
                anchorAbort = ctl;
                const stop = () => { if (anchorToken === token) anchorToken++; ctl.abort(); };
                const opts = { capture: true, passive: true, signal: ctl.signal };
                window.addEventListener('wheel', stop, opts);
                window.addEventListener('pointerdown', stop, opts);
                window.addEventListener('keydown', stop, { capture: true, signal: ctl.signal });
                // Erster Zug SYNCHRON (nicht über setTimeout): das Setzen der
                // Auswahl lässt WebKit die Zeile selbst aufdecken — unten-
                // ausgerichtet. Ein Task später wäre dieser falsche Stand schon
                // einmal gemalt (gemessen: ein Frame mit dem letzten Absatz am
                // unteren Rand). Weil das Typewriter-Modul vorgeladen ist, läuft
                // das `await` nur bis zum Microtask-Checkpoint — also vor dem Paint.
                anchorCaretLine(0);
                const delays = [60, 150, 400, 800, 1400];
                delays.forEach((ms, i) => setTimeout(() => {
                  if (anchorToken !== token) return;
                  anchorCaretLine(2);
                  if (i === delays.length - 1) ctl.abort();   // Fenster zu
                }, ms));
              }

              // Schreibfläche fokussieren + Caret platzieren. Wartet (gestaffelte
              // rAF) auf den Content-Knoten, weil enterFocusMode im $nextTick läuft
              // — ein einzelnes rAF konnte zu früh feuern, dann öffnete die Seite
              // ohne Caret (man musste hineinklicken). `caretOffset` (optional):
              // gemerkte Position wiederherstellen, sonst ans Ende.
              function focusEditor(opts) {
                const caretOffset = opts && typeof opts.caretOffset === 'number' ? opts.caretOffset : null;
                let tries = 0;
                const tick = () => {
                  const content = activeContent();
                  if (!content) {
                    if (tries++ < 30) requestAnimationFrame(tick);
                    return;
                  }
                  try {
                    // `preventScroll` ist Pflicht: ohne das deckt WebKit die
                    // Auswahl selbst auf — UNTEN-ausgerichtet, also eine halbe
                    // Bildschirmhöhe unter der Schreiblinie (dieselbe Ausrichtung
                    // überschrieb die korrekte Einstiegs-Position der Engine,
                    // `_focusInstall` fokussiert deshalb ebenfalls mit
                    // preventScroll). Positioniert wird danach über den Anker.
                    content.focus({ preventScroll: true });
                    if (caretOffset == null || !placeCaretAtOffset(content, caretOffset)) {
                      placeCaretAtEnd(content);
                    }
                    anchorCaretWhileSettling();
                  } catch (_) {}
                };
                requestAnimationFrame(tick);
              }

              // Offene Seite + Dirty-Flag an den Swift-Kern melden (`editorState`).
              // Treibt die Seiten-Anzeige in der Toolbar UND die Sync-Logik:
              // Open-Page-Reload der sauberen offenen Seite + Datenverlust-Schutz
              // der dirty offenen Seite (SyncEngine liest openPageId/isDirty). Ohne
              // diesen Aufruf bliebe die Bridge-seitige openPageId immer null.
              // Nur bei echtem Zustandswechsel posten (keine Keystroke-Flut).
              let reportedPageId;
              let reportedDirty;
              // Zählt jede Eingabe (input-Event am Mount). Wer über einen await
              // hinweg wissen muss, ob inzwischen getippt wurde (Save-Roundtrip,
              // Seitenwechsel, stiller Server-Refresh), vergleicht den Stand.
              let inputSeq = 0;
              function reportEditorState(pageId, dirty) {
                const pid = pageId == null ? null : String(pageId);
                if (pid === reportedPageId && dirty === reportedDirty) return;
                reportedPageId = pid;
                reportedDirty = dirty;
                try { fb.reportState(pid, dirty, currentBookId); } catch (_) {}
              }

              // Lokale Fokus-Granularität: beim Boot aus dem Swift-Kern ziehen
              // (UserDefaults-Wert), damit das initiale Mount schon die richtige
              // CSS-Klasse setzt. Live-Umschalten kommt später als Event.
              let initialGranularity = 'paragraph';
              try {
                const fc = await fb.focusGranularity();
                if (fc && fc.granularity) initialGranularity = fc.granularity;
              } catch (_) {}

              const bridge = {
                granularity: initialGranularity,
                loadPage: async () => {
                  // Auf das in der Toolbar gewählte Buch beschränken — sonst lüde
                  // die global gemerkte lastOpenPage (pro Server, nicht pro Buch)
                  // eine Seite aus einem anderen Buch, und der Editor zeigte ein
                  // anderes Buch als die Toolbar. Ohne aktives Buch (Erststart):
                  // ungefiltert wie bisher.
                  let bookId = null;
                  try {
                    const ab = await fb.activeBook();
                    if (ab && ab.bookId != null) bookId = ab.bookId;
                  } catch (_) {}
                  let pages = [];
                  try { pages = bookId != null ? await fb.list(bookId) : await fb.list(); } catch (_) {}
                  // Zuletzt geöffnete Seite bevorzugen (gerätelokal, PRO Buch
                  // gemerkt) — nur für das aktive Buch und nur, wenn sie noch in
                  // dessen Seitenliste steht (sonst gelöscht). Ohne aktives Buch
                  // (Erststart-Race, bevor die Toolbar ein Buch gewählt hat) NIE
                  // restoren — sonst öffnete sich eine Seite aus einem anderen
                  // Buch. Fallback: erste Seite des Buchs.
                  let id = null;
                  if (bookId != null) {
                    try {
                      const last = await fb.lastOpenPage(bookId);
                      if (last && last.pageId != null) {
                        const lid = String(last.pageId);
                        if (Array.isArray(pages) && pages.some((p) => String(p.id) === lid)) id = lid;
                      }
                    } catch (_) {}
                  }
                  if (id == null) {
                    const first = Array.isArray(pages) && pages.length ? pages[0] : null;
                    id = first ? first.id : 'default';
                  }
                  let page = null;
                  try { page = await fb.load(id); } catch (_) {}
                  if (page) {
                    bases.set(String(page.id), page.updatedAt ?? null);
                    currentPageId = String(page.id);
                    currentBookId = (page.bookId != null) ? Number(page.bookId) : null;
                    bootHadPage = true;
                    return { id: page.id, name: page.pageName || page.title || 'Abschnitt', html: page.html || '<p><br></p>' };
                  }
                  bases.set('default', null);
                  currentPageId = 'default';
                  currentBookId = null;
                  bootHadPage = false;
                  return { id: 'default', name: 'Neuer Abschnitt', html: '<p><br></p>' };
                },
                savePage: async ({ id, html }) => {
                  // „Geschlossene" (leere) Seite nach einem Buchwechsel nie
                  // persistieren — sonst legte ein Autosave-Tick einen Junk-
                  // Eintrag mit leerer id an. Ebenso die 'default'-Platzhalter-
                  // Seite (Boot-Fallback bei leerem/ungesynctem Buch): sie ist
                  // kein echter Datensatz, hat kein Buch & keine Server-Basis →
                  // würde sonst als nie-pushbarer „default"-Konflikt landen.
                  if (id == null || id === '' || id === 'default') return null;
                  const base = bases.get(String(id)) ?? null;
                  const seqAtSave = inputSeq;
                  const res = await fb.save(id, html, base);
                  if (res && res.updatedAt != null) bases.set(String(id), res.updatedAt);
                  // Gespeichert → sauber, AUSSER es wurde während des Roundtrips
                  // weitergetippt (der Stand im DOM ist dann neuer als der
                  // gesicherte). Nur für die offene Seite melden: beim Schliessen
                  // ist currentPageId schon leer — sonst meldete der Save die
                  // geschlossene Seite Swift gegenüber wieder als offen.
                  if (String(id) === currentPageId) {
                    reportEditorState(id, inputSeq !== seqAtSave);
                  }
                  return res;
                },
              };

              // Auto-Save-Debounce (lokale Vorliebe) beim Mount durchreichen.
              // mountStandaloneFocus nutzt den Editor-Default (1500 ms), wenn
              // autosaveMs fehlt — darum nur setzen, wenn ein gültiger Wert kommt.
              let autosaveMs;
              try {
                const eb = await fb.editorBehavior();
                if (eb && Number.isFinite(Number(eb.autosaveMs))) autosaveMs = Number(eb.autosaveMs);
              } catch (_) {}

              // Typewriter-Geometrie vorladen (fire-and-forget): das erste
              // Anker-Ziehen beim Öffnen muss VOR dem ersten Paint fahren, sonst
              // blitzt der von WebKit unten-ausgerichtete Stand auf. Mit
              // aufgelöstem Modul-Promise bleibt das `await` ein Microtask.
              typewriterModule();

              const mountOpts = { mount: document.getElementById('mount'), bridge };
              if (autosaveMs != null) mountOpts.autosaveMs = autosaveMs;
              window.__standalone = await mountStandaloneFocus(mountOpts);
              status.remove();

              // quickSave des Editors (SSoT) überspringt den Save, wenn der Inhalt
              // dem geladenen Stand gleicht (Tippen + wieder Löschen) — dann ruft
              // er savePage nie, und das gemeldete Dirty-Flag bliebe auf true
              // stehen (Toolbar „ungesichert", Server-Refresh der Seite gesperrt).
              // Darum nach JEDEM quickSave den echten Zustand nachmelden. Der
              // Autosave-Timer ruft `host.quickSave()` über die Eigenschaft,
              // erreicht also diese Hülle.
              try {
                const host = window.__standalone.host;
                const quickSave = host.quickSave.bind(host);
                host.quickSave = async () => {
                  const seqAtSave = inputSeq;
                  await quickSave();
                  if (currentPageId && inputSeq === seqAtSave && !host.editDirty) {
                    reportEditorState(currentPageId, false);
                  }
                };
              } catch (_) {}
              fb.log?.('Standalone-Focus gemountet');

              // Initial geöffnete Seite (loadPage) an Swift melden → Toolbar-Titel
              // steht ab Boot, nicht erst nach dem ersten Picker-Wechsel. Ohne
              // echte Seite (leeres/ungesynctes Buch) startet die App in der
              // ruhigen Leerfläche statt mit einer leeren Schreibfläche.
              if (bootHadPage) {
                reportEditorState(currentPageId, false);
                focusEditor();   // Cursor in die geladene Seite setzen
              } else {
                currentPageId = null;
                showEmpty();
                reportEditorState(null, false);
              }
              // Tastatureingaben markieren die offene Seite dirty (Datenverlust-
              // Schutz im Sync). Listener am Mount-Container (überlebt setPage,
              // das den Content-Knoten austauscht); 'input' bubbelt aus dem
              // contenteditable hoch.
              const mountEl = document.getElementById('mount');
              if (mountEl) mountEl.addEventListener('input', (e) => {
                inputSeq++;
                if (currentPageId) reportEditorState(currentPageId, true);
                noticeHistoryEdit(e);
              });

              // Fenster verliert den Fokus / Dokument wird abgebaut → offenen
              // Draft SOFORT sichern, statt auf den entprellten Autosave (bis
              // 5 s) zu warten. Deckt den Weg ab, den Swift nicht sieht: Klick
              // in ein anderes Fenster, Fenster schliessen, App-Wechsel. ⌘Q
              // fängt zusätzlich AppTerminationGuard auf der Swift-Seite ab.
              //
              // Nur bei WIRKLICH dirty (`reportedDirty`) — sonst schriebe jeder
              // Toolbar-Klick (der nimmt der WebView den Fokus) einen Save samt
              // Outbox-Eintrag und damit einen überflüssigen PUT.
              function flushIfDirty() {
                if (!reportedDirty || !currentPageId) return;
                try { fb._flushSave(); } catch (_) {}
              }
              window.addEventListener('blur', flushIfDirty);
              window.addEventListener('pagehide', flushIfDirty);
              document.addEventListener('visibilitychange', () => {
                if (document.hidden) flushIfDirty();
              });

        """
}
