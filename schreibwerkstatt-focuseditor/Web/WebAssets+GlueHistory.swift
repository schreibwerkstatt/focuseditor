//
//  WebAssets+GlueHistory.swift
//  schreibwerkstatt-focuseditor
//
//  Der Undo-Teil des Boot-Glues: Undo-Stack der WebView leeren (`resetUndo`) und
//  nennenswerte ⌘Z/⌘⇧Z-Sprünge an Swift melden (`historyEdit`).
//
//  WebKit fasst alles seit dem letzten Mausklick zu EINEM Undo-Schritt zusammen —
//  ein versehentliches ⌘Z kann also einen ganzen Abschnitt entfernen, und der
//  Auto-Save persistiert das still. Darum der Hinweis-Banner.
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
    /// Widerrufen / Wiederherstellen — Fragment des Boot-Moduls (s. Kopfdoku).
    static let glueHistoryJS = """
              // ── Widerrufen / Wiederherstellen (⌘Z / ⌘⇧Z) ────────────────────
              // Die Historie führt der gebündelte Editor selbst (SSoT
              // `shared/edit-history.js`, satzweise Schritte); das Menü löst sie
              // über das `history`-Event aus (s. GlueEvents). WebKits eigener
              // Stack ist GROB (alles seit dem letzten Mausklick ist EIN Schritt)
              // und bleibt nur der Rückfall für ältere Bundles ohne Handle-API.
              //
              // Der Glue meldet jedes History-Ereignis samt Umfang an Swift, das
              // ab einem grösseren Umfang einen Hinweis mit dem Rückweg (⌘⇧Z)
              // zeigt.
              //
              // Zweites Thema hier: der Undo-Stack hängt an der WebView, nicht
              // am Inhalt — nach einem Seitenwechsel muss er geleert werden
              // (`clearUndoSoon`), sonst stehen Einträge der vorigen Seite als
              // wirkungslose „Widerrufen"-Schritte im Menü.

              // Undo-Stack leeren — sofort und (bedingt) kurz danach. Grund fürs
              // Nachfassen: die Fokus-Engine editiert nach dem Mount noch selbst
              // (Schreib-Slot am Seitenende); diese Mutation landet als
              // Undo-Eintrag NACH dem ersten Leeren und bliebe sonst als
              // wirkungsloser Schritt stehen (gemessen).
              //
              // Die Bedingung ist wichtig: hat der Nutzer in der Zwischenzeit
              // schon getippt, wird NICHT mehr geleert — sonst nähme das
              // Nachfassen ihm den Undo-Schritt für seine eigenen ersten
              // Zeichen weg (stiller Verlust der Rücknahme-Möglichkeit).
              let typedSincePageChange = false;
              function clearUndoSoon() {
                typedSincePageChange = false;
                try { fb.resetUndo(); } catch (_) {}
                setTimeout(() => {
                  if (typedSincePageChange) return;
                  try { fb.resetUndo(); } catch (_) {}
                }, 400);
              }

              // Umfang eines History-Ereignisses: Vergleich mit der Textlänge VOR
              // dem Ereignis (`lastTextLen`, läuft bei jedem `input` mit).
              // `resetTextLen()` setzt sie beim Seitenwechsel neu, damit der
              // Wechsel selbst nicht als Riesen-Delta gilt.
              let lastTextLen = -1;
              function contentTextLen() {
                const c = document.querySelector('.focus-editor__content');
                return c && c.textContent ? c.textContent.length : 0;
              }
              function resetTextLen() { lastTextLen = contentTextLen(); }
              function noticeHistoryEdit(e) {
                const now = contentTextLen();
                const prev = lastTextLen < 0 ? now : lastTextLen;
                lastTextLen = now;
                const type = e && e.inputType;
                if (type !== 'historyUndo' && type !== 'historyRedo') {
                  // Echte Eingabe → das bedingte Nachfassen von clearUndoSoon()
                  // darf diesen Undo-Schritt nicht mehr wegräumen.
                  typedSincePageChange = true;
                  return;
                }
                const delta = Math.abs(now - prev);
                if (!delta) return;
                try {
                  fb.reportHistoryEdit(type === 'historyUndo' ? 'undo' : 'redo', delta);
                } catch (_) {}
              }

        """
}
