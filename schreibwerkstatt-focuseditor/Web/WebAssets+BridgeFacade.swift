//
//  WebAssets+BridgeFacade.swift
//  schreibwerkstatt-focuseditor
//
//  Die Bridge-Facade (`bridgeFacadeJS`): wird at-document-start in JEDE geladene
//  Seite injiziert (auch ins OTA-Editor-Bundle) und stellt `window.__focusBridge`
//  bereit — das einzige JS-Primitiv, über das die WebView den Swift-Kern erreicht.
//  Bewusst schlank (keine Editor-Logik); der Boot-Glue in `WebAssets+IndexHTML`
//  adaptiert sie auf den standalone-Vertrag.
//

import Foundation

extension WebAssets {
    /// At-document-start injiziert. Definiert `window.__focusBridge.call(op, params)`
    /// → Promise mit dem Swift-Reply. Leitet zusätzlich `console.*` an den
    /// Swift-Logger weiter (Diagnose). Bewusst schlank — keine Editor-Logik.
    static let bridgeFacadeJS = """
    (function () {
      'use strict';
      const handler = window.webkit
        && window.webkit.messageHandlers
        && window.webkit.messageHandlers.\(handlerName);

      if (!handler) {
        console.warn('[focus-bridge] Swift-Handler nicht verfügbar — kein nativer Kontext?');
        return;
      }

      // Einziges Brücken-Primitiv: liefert ein Promise mit dem Swift-Reply.
      const call = (op, params) => handler.postMessage({ op: op, params: params || {} });

      window.__focusBridge = {
        call,
        load: (pageId) => call('load', { pageId }),
        save: (pageId, html, baseUpdatedAt) => call('save', { pageId, html, baseUpdatedAt }),
        list: (bookId) => call('list', bookId == null ? {} : { bookId }),
        log:  (message, level) => call('log', { message: String(message), level: level || 'info' }),

        // Zuletzt geöffnete Seite (gerätelokal, pro Buch) — Boot-Restore.
        // loadPage bevorzugt sie für das aktive Buch, fällt sonst auf die erste
        // Seite des Buchs zurück. Ohne bookId: globaler (legacy) Wert.
        lastOpenPage: (bookId) => call('lastOpenPage', bookId == null ? {} : { bookId }),

        // In der Toolbar gewähltes Buch (gerätelokal, pro Server). loadPage
        // skopiert die initiale Seitenauswahl darauf, damit beim Start nie eine
        // Seite aus einem anderen Buch geladen wird. { bookId } | { bookId: null }.
        activeBook: () => call('activeBook', {}),

        // Editor meldet offene Seite + Dirty-Flag an Swift (Open-Page-Reload/-Schutz).
        // bookId hängt mit, damit Swift die zuletzt geöffnete Seite PRO Buch merkt
        // (Boot-Restore ohne Buch-Verwechslung).
        reportState: (pageId, dirty, bookId) =>
          call('editorState', { pageId: pageId == null ? null : String(pageId),
                                dirty: !!dirty,
                                bookId: bookId == null ? null : Number(bookId) }),

        // Rechtschreibprüfung (LanguageTool) — Proxy über den Swift-Kern. Die
        // WebView macht NIE direkten fetch; Settings (enabled/url/picky/rules)
        // liegen serverseitig und werden vom Proxy angewandt.
        spellcheckConfig: () => call('spellcheckConfig', {}),
        languagetoolCheck: (params) => call('languagetoolCheck', params || {}),
        dictionaryAdd: (params) => call('dictionaryAdd', params || {}),

        // Synonyme (Cmd+Shift+S) — wie die Rechtschreibung über den Swift-Kern,
        // NIE direkter fetch. synonymsThesaurus: OpenThesaurus (synchron, de-only);
        // synonymsAi: KI-Job — der Swift-Kern pollt die Job-Queue fertig und
        // liefert EIN Ergebnis zurück (der Editor muss nicht selbst pollen).
        synonymConfig: () => call('synonymConfig', {}),
        synonymsThesaurus: (params) => call('synonymsThesaurus', params || {}),
        synonymsAi: (params) => call('synonymsAi', params || {}),

        // Lokale Fokus-Granularität (paragraph/sentence/window-3/typewriter-only).
        // Boot-Pull; Live-Umschalten kommt zusätzlich als 'focusGranularity'-Event.
        focusGranularity: () => call('focusGranularity', {}),

        // Lokale Editor-Typografie (Schriftgrösse/Zeilenhöhe/measure/Familie/
        // Papier-Ton) als CSS-fertiges Payload. Boot-Pull; Live-Umschalten kommt
        // zusätzlich als 'editorTypography'-Event.
        editorTypography: () => call('editorTypography', {}),

        // Editor-Verhalten (Auto-Save-Debounce) — Boot-Pull, wird an
        // mountStandaloneFocus({ autosaveMs }) durchgereicht.
        editorBehavior: () => call('editorBehavior', {}),

        // Undo-Stack der WebView leeren. Der Editor rendert einen Seitenwechsel
        // per innerHTML — WebKits Undo-Einträge der VORIGEN Seite bleiben dabei
        // im Stack stehen und würden dort still verpuffen (Menü zeigt
        // „Widerrufen" aktiv, der Klick tut nichts). Nach jedem setPage einmal
        // aufrufen; dann gilt Undo immer nur für die offene Seite.
        resetUndo: () => call('resetUndo', {}),

        // Ein Widerrufen/Wiederherstellen hat gerade Text entfernt bzw. wieder
        // eingesetzt (`input`-Event mit inputType historyUndo/historyRedo).
        // WebKit fasst eine ganze Tippstrecke in EINEN Undo-Schritt zusammen
        // (gemessen: alles seit dem letzten Mausklick) — ein versehentliches ⌘Z
        // kann also viel Text auf einmal entfernen. Swift zeigt darum einen
        // Hinweis mit dem Rückweg (⌘⇧Z), statt es still passieren zu lassen.
        reportHistoryEdit: (kind, chars) =>
          call('historyEdit', { kind: String(kind), chars: Number(chars) || 0 }),

        // Lebende Schreibstatistik (Wörter/Zeichen) der offenen Seite an Swift
        // melden (Live-Stats + Schreibziel + Tages-Delta). Die pageId hängt mit,
        // damit Swift den „heute geschrieben"-Delta korrekt PRO Seite führt
        // (Tagesbaseline pro Seite). Feuert debounced bei Eingabe.
        reportStats: (words, chars, pageId, typed) =>
          call('reportStats', { words, chars, pageId: pageId == null ? null : String(pageId),
                                typed: typed !== false }),

        // Swift→JS Event-Bus. Der Editor-Host abonniert z. B. 'serverUpdate'
        // (saubere offene Seite wurde serverseitig aktualisiert → still neu laden).
        _handlers: {},
        on: function (event, cb) {
          (this._handlers[event] = this._handlers[event] || []).push(cb);
        },
        _receive: function (event, payload) {
          (this._handlers[event] || []).forEach(function (cb) {
            try { cb(payload); } catch (e) { console.error('[focus-bridge] handler', e); }
          });
        },

        // Verzögerter Spellcheck-Nachzieh-Versuch (Boot war offline ⇒
        // LanguageTool nie mounted). Swift ruft diese Funktion über
        // `pushDeferredSpellcheckInit` auf, sobald der Server in der
        // Sitzung erreicht wurde. Platzhalter `null` — das Boot-Modul
        // weist die echte Funktion SEHR früh zu (vor jeglichem await),
        // damit der Aufruf ab dem ersten Boot-Zyklus klappt.
        _trySpellcheckInit: null,

        // 3-Wege-Block-Merge über das gebündelte block-merge.js (ES-Modul,
        // dynamisch geladen). Von Swift via callAsyncJavaScript aufgerufen.
        // Wirft, wenn kein Bundle vorliegt (Dev-Harness) → Swift wertet das als Konflikt.
        _merge3: async function (baseHtml, localHtml, serverHtml) {
          // Gegen die Dokument-URL auflösen, NICHT als nackter relativer
          // Specifier: diese Funktion steht in einem WKUserScript (at-document-
          // start), und ein relativer `import()` aus einem User-Script hat keine
          // Basis-URL — WebKit wirft „Module name … does not resolve to a valid
          // URL", und JEDER 409 degradierte zum harten Konflikt (am laufenden
          // Client nachgemessen). Ein root-absoluter Pfad (/js/…) bräche
          // dagegen, sobald der Cache-Root nicht der Origin-Root ist —
          // `document.baseURI` deckt beides ab (wie die ./js/…-Imports des
          // Boot-Moduls, die relativ zum Dokument laufen).
          const url = new URL('js/editor/shared/block-merge.js', document.baseURI).href;
          const m = await import(url);
          const res = m.mergeBlocks(baseHtml || '', localHtml || '', serverHtml || '');
          return { merged: m.mergedToHtml(res.merged), conflictCount: res.conflicts.length };
        },

        // Offenen Draft sofort persistieren (z. B. bei ⌘S). Der Editor-Autosave
        // läuft entprellt — ein frischer Tastenanschlag liegt also evtl. noch
        // nicht im LocalStore. `__standalone.save()` verwirft den Autosave-Timer
        // und schiebt den aktuellen Stand über die save-Op (→ LocalStore +
        // Outbox). AWAITABLE gehalten (Swift wartet darauf, bevor es den Sync
        // anstösst) — anders als der Fire-and-forget-Event-Bus (`_receive`).
        // Kein offener Editor / kein Bundle → still no-op (kein Wurf).
        _flushSave: async function () {
          const s = window.__standalone;
          if (s && typeof s.save === 'function') { await s.save(); }
          return true;
        },
      };

      // console → Swift-Log (nur Weiterleitung, Original bleibt erhalten).
      ['log', 'info', 'warn', 'error'].forEach((level) => {
        const orig = console[level].bind(console);
        console[level] = (...args) => {
          try { call('log', { level: level === 'warn' ? 'info' : level, message: args.join(' ') }); } catch (_) {}
          orig(...args);
        };
      });
    })();
    """
}
