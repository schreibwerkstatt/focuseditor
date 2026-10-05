# schreibwerkstatt-focuseditor (macOS-Client)

Nativer macOS-Client für den **Focus-Editor** der Schreibwerkstatt: eine SwiftUI/AppKit-Shell mit `WKWebView`, die ein **lokal gecachtes Build** des bestehenden Focus-Editors lädt. Das Build wird **zur Laufzeit per OTA vom Server gezogen** (statt zur Build-Zeit gebündelt) und im App-Support gecacht. Schreiben geht zuerst in einen lokalen SQLite-Spiegel; eine Sync-Engine schiebt Änderungen bei Konnektivität an den Server und zieht Deltas zurück.

**Zweck:** ablenkungsfreies Schreiben auf genau einer Seite, voll offline-fähig. Kein Buchorganizer, keine Analyse-Karten, keine KI-Jobs — nur der Schreibmodus.

## Über dieses Projekt

Die **Schreibwerkstatt** ist eine Web-Plattform zum strukturierten Schreiben von Büchern (Express-Server, Editor, Buch-/Kapitel-Organisation, Lektorat, Analyse-Karten, KI-Jobs). Dieser **Focus-Editor-Client** ist eine eigenständige, abgespeckte native macOS-App, die *nur* den Schreibmodus der Plattform herausschält: eine Seite, kein Drumherum, voll offline-fähig. Er ersetzt die Web-Plattform nicht, sondern ist ein fokussierter Schreib-Frontend für dieselben Inhalte — Seiten, die hier entstehen, leben über den Sync im selben Datenbestand wie die Web-App.

**Verhältnis zum Mutterprojekt:** Der Editor-Code (JS/CSS, Block-Merge) wird **nicht** kopiert, sondern zur Laufzeit als OTA-Bundle vom Server gezogen — die Schreibwerkstatt bleibt Single Source of Truth (Details unten unter „Quellprojekt"). Dieser Client liefert nur die native Hülle: Shell, Bridge, Offline-Store, Sync, Auth, OTA-Lader.

**Repositories:**
- **Mutterprojekt (Schreibwerkstatt, SSoT):** GitHub [`schreibwerkstatt/schreibwerkstatt`](https://github.com/schreibwerkstatt/schreibwerkstatt) (public) · lokal `/Users/bd/ClaudeProjects/schreibwerkstatt`
- **Dieser Client:** GitHub [`schreibwerkstatt/focuseditor`](https://github.com/schreibwerkstatt/focuseditor) (public) · lokal `/Users/bd/xcode-projects/schreibwerkstatt-focuseditor`

## Quellprojekt (Single Source of Truth)

- Hauptrepo: `/Users/bd/ClaudeProjects/schreibwerkstatt`
- Der Editor-Code wird **nicht geforkt** und **nicht zur Build-Zeit kopiert**. Der Server bündelt die unveränderte ES-Modul-Import-Closure (ab `public/js/editor/focus.js` / `focus/standalone.js` / `shared/editor-host.js` / `shared/block-merge.js`) + die Focus-Editor-CSS als **OTA-ZIP** und liefert sie über `GET /content/editor-bundle.zip` aus ([lib/editor-bundle.js](../../ClaudeProjects/schreibwerkstatt/lib/editor-bundle.js)). Der Client zieht das ZIP zur Laufzeit und cacht es lokal. SSoT bleibt das Hauptrepo — hier liegt **kein** kopierter Editor-Code, nur Bridge + Shell + Sync + Auth + OTA-Lader.
- Bei Editor-Bugs/-Features: Fix gehört ins Hauptrepo. Der nächste Start des Clients zieht das aktualisierte Bundle automatisch (ETag-getrieben). Niemals den gecachten Output von Hand patchen.
- **Das `index.html` (Boot/Bridge) ist NICHT im Server-Bundle** — es ist Client-Glue (adaptiert `window.__focusBridge` auf den standalone-Vertrag) und liegt in [Web/WebAssets+IndexHTML.swift](schreibwerkstatt-focuseditor/Web/WebAssets+IndexHTML.swift) (`indexHTML(cssFiles:sourceCommit:)`). Der Client schreibt es beim Entpacken aus dem Manifest in den Cache. Das Boot-**Modul** (über 1000 Zeilen JS) liegt als Fragment-Konstanten in `Web/WebAssets+Glue*.swift` (Spellcheck · Caret · History · Events · Typography · Stats · Mount · Synonyms) und wird von `indexHTML` in fester Reihenfolge zusammengesetzt: die Fragmente teilen sich EINEN JS-Scope, sind also **nicht** unabhängig — Reihenfolge und Einrückung sind bindend. [WebAssetsSyntaxTests.swift](schreibwerkstatt-focuseditorTests/WebAssetsSyntaxTests.swift) lässt `node --check` über das zusammengesetzte Ergebnis laufen.

## Architektur

> **Detaillierte Implementierungs-Referenz: [ARCHITECTURE.md](ARCHITECTURE.md)** — konkrete Typen, Besitzverhältnisse (`AppCore`-Komposition), Datenflüsse und „wo was hingehört". Dieser Abschnitt gibt den Überblick; ARCHITECTURE.md geht in den Code.

```
AppKit/SwiftUI-Shell
  └─ WKWebView  ──lädt (swk-app://)──>  web-cache/  (lokal gecachtes Focus-Editor-Build)
        │  WKScriptMessageHandler-Bridge (JS ⇄ Swift)
        ▼
  Swift-Kern
     ├─ LocalStore         (GRDB / SQLite-Spiegel der Seiten)
     ├─ Outbox             (Schreib-Queue, immer erst lokal)
     ├─ SyncEngine         (Scene-Phase-getriebenes Polling ~5 s + Reachability-Trigger; Push + Pull)
     ├─ EditorBundleStore  (OTA: zieht/cacht das Editor-Bundle, ETag-getrieben)
     └─ Auth               (Device-Token im Keychain)
                 │ HTTPS Bearer swd_…
                 ▼
        schreibwerkstatt-Server  (Express, Port 3737 / NGINX HTTPS)
```

**Offline-Kern-Prinzip:** Der WebView lädt **immer** den lokalen Cache, **nie** eine Server-URL. Die WebView kennt keinen Server — sie spricht ausschließlich über die Bridge mit dem Swift-Kern. Netzwerk macht nur der Swift-Kern (Sync **und** OTA-Bundle-Refresh). Nach dem ersten erfolgreichen Bundle-Download arbeitet die App vollständig offline; nur der **allererste** Start braucht Netz (der Device-Token-Login ist ohnehin online).

## Bridge-Vertrag (JS ⇄ Swift)

Der Focus-Editor ruft heute Root-Methoden über `window.__app.*` und liest Root-Props. Im Bundle ersetzt eine **schlanke Bridge-Facade** diese Aufrufe — statt HTTP ruft sie über die WKWebView-Bridge den Swift-Kern.

Zu überbrückende Methoden:
- `startEdit` / `cancelEdit`
- `_flushDraftSaveNow` — Draft sofort persistieren
- `_markEditDirty` — Dirty-Flag setzen
- `_editCounterCtx` — Counter-/Kontext-Lieferant
- `_syncPageStatsAfterSave` — Stats nach Save aktualisieren

Zu liefernde Props (lesend für den Editor):
- `currentPage`, `renderedPageHtml`, `focusGranularity`, `editDirty`

Bridge-Nachrichten **JS → Swift** (`WKScriptMessageHandlerWithReply`, je `{ op, params }`):
- `load { pageId }` → Seite aus LocalStore (`{ id, html, updatedAt, baseUpdatedAt? }`)
- `save { pageId, html, baseUpdatedAt? }` → LocalStore + Outbox (`{ id, updatedAt }`)
- `list { bookId? }` → Seitenliste aus LocalStore (optional buch-gefiltert)
- `log { level?, message }` → JS-Diagnose ins Swift-Log
- `editorState { pageId, dirty, bookId? }` → meldet offene Seite + Dirty-Flag (steuert Open-Page-Reload/-Schutz im Sync). Merkt nebenbei die zuletzt geöffnete Seite gerätelokal — **pro Buch** (UserDefaults `editor.lastOpenByBook.<server>`, Dict `bookId→pageId`, via `bookId`) **und** global (Legacy-Key `editor.lastOpenPageId.<server>`); nur echte Seiten. Zusätzlich wächst daraus die **MRU-Historie** der letzten fünf Seiten pro Buch (`editor.recentPagesByBook.<server>`, Dict `bookId→[pageId]`, `EditorBridge.pushRecentPageId`) — sie speist die Gruppe „Zuletzt geöffnet" ganz oben im Seiten-Picker (`LibraryStore.recentPageRows()` löst gegen die Seitenliste des aktiven Buchs auf; eine Seite steht dann zweimal in der Liste, darum die sektions-qualifizierte Zeilen-Identität `RowKey` in [PagePickerModel.swift](schreibwerkstatt-focuseditor/Library/PagePickerModel.swift)).
- `lastOpenPage { bookId? }` → `{ pageId }` (zuletzt geöffnete Seite, gerätelokal; mit `bookId` **buch-skopiert**, ohne den globalen Legacy-Wert; `null` wenn für das Buch nie geöffnet). Boot-Pull: der Editor-Glue (`loadPage` in [WebAssets.swift](schreibwerkstatt-focuseditor/Web/WebAssets.swift)) bevorzugt sie **nur für das aktive Buch** und nur, falls noch in dessen Seitenliste — sonst erste Seite. **Ohne aktives Buch** (Erststart-Race) wird **nie** restauriert (verhinderte den „falsches Buch geöffnet"-Bug).
- `spellcheckConfig {}` → `{ enabled, debounceMs }` (aus `GET /config`, in der Bridge gecacht)
- `languagetoolCheck { text, language?, pageId?, bookId? }` → `{ matches: [...] }` | `{ disabled: true }` (Proxy `POST /languagetool/check`; `404` = serverseitig aus). **Lokale Overrides** (UserDefaults, `SpellcheckPrefs` in [EditorBridge+Proxies.swift](schreibwerkstatt-focuseditor/Web/EditorBridge+Proxies.swift)): `spellcheck.localEnabled=false` → `{ disabled: true }` ohne Roundtrip; `spellcheck.languageOverride` (≠ „auto") übersteuert die gesendete Sprache.
- `dictionaryAdd { word, lang?, bookId? }` → `{ ok }` (Proxy `POST /dictionary`, User-Wörterbuch)
- `synonymConfig {}` → `{ enabled, i18n }` (Synonym-Hilfe lokal an/aus + lokalisierte UI-Strings; `SynonymPrefs` in [EditorBridge+Proxies.swift](schreibwerkstatt-focuseditor/Web/EditorBridge+Proxies.swift))
- `synonymsThesaurus { word, bookId? }` → `{ synonyme: [{wort, hinweis}], disabled }` (Proxy `GET /openthesaurus/synonyms`; nur Deutsch, sonst `disabled`)
- `synonymsAi { wort, satz, bookId?, pageId? }` → `{ synonyme: [{wort, hinweis}] }` | `{ error }` | `{ disabled }` (KI-Synonyme: `POST /jobs/synonym`, danach **serverseitig fertig gepollt** via `GET /jobs/:id` → EIN awaitbares Ergebnis; `error`-Werte sind i18n-Keys des Controllers)
- `focusGranularity {}` → `{ granularity }` (lokale Fokus-Stufe, Boot-Pull)
- `editorTypography {}` → CSS-fertiges Payload `{ fontSize, lineHeight, measure, fontFamily, paperBg?, paperText?, focusDim? }` (lokale Typografie inkl. Fokus-Abdunklung, Boot-Pull; vom `TypographyController`, [Theme/TypographyController.swift](schreibwerkstatt-focuseditor/Theme/TypographyController.swift))
- `editorBehavior {}` → `{ autosaveMs }` (lokales Editor-Verhalten, Boot-Pull; an `mountStandaloneFocus({ autosaveMs })` durchgereicht, `EditorBehaviorPrefs` in [EditorBridge+Proxies.swift](schreibwerkstatt-focuseditor/Web/EditorBridge+Proxies.swift))
- `reportStats { words, chars, pageId?, typed }` → `null` (JS meldet Live-Wort-/Zeichenzahl der offenen Seite; treibt Toolbar-Stats, Schreibziel und den Tages-Delta im `WritingStatsStore`, [Writing/WritingStatsStore.swift](schreibwerkstatt-focuseditor/Writing/WritingStatsStore.swift)). `typed:false` = Zählung ohne Eingabe (Seitenwechsel, stiller Server-Refresh): zählt weder als Schreibzeit-Aktivität noch in „heute geschrieben" — sonst buchte eine Änderung von einem anderen Gerät als eigene Arbeit.
- `resetUndo {}` → `null` (Undo-Stack der WebView leeren: `webView.undoManager?.removeAllActions()`). Seit der Editor seine eigene Historie führt (s. „Widerrufen / Wiederherstellen") ist WebKits Stack nur noch Beifang, den nichts mehr anspricht — geleert wird er weiterhin, damit ihn kein anderer Weg (Diktat, Systemgeste) doch noch grob zurückrollt. Ruft der Glue nach **jedem** `setPage` (Seitenwechsel, stiller Server-Refresh, Seite schliessen) — WebKits Undo-Stack hängt an der WebView, nicht am Inhalt, sonst blieben die Einträge der vorigen Seite als wirkungslose „Widerrufen"-Schritte stehen. Der Glue fasst 400 ms später **bedingt** nach (`clearUndoSoon`), weil die Fokus-Engine nach dem Mount noch selbst editiert (Schreib-Slot) — hat der Nutzer inzwischen getippt, wird nicht mehr geleert (sonst verlöre er die Rücknahme seiner ersten Zeichen).
- `historyEdit { kind, chars }` → `null` (`kind` = `undo`|`redo`; Umfang in Zeichen). Der Glue meldet jedes `input`-Event mit `inputType` `historyUndo`/`historyRedo`; ab 40 Zeichen zeigt der `LibraryStore` einen kurzen Hinweis über der Schreibfläche ([Library/HistoryNoticeBanner.swift](schreibwerkstatt-focuseditor/Library/HistoryNoticeBanner.swift)) mit dem Rückweg ⌘⇧Z.

**Rechtschreibprüfung (LanguageTool):** Der unveränderte Editor-Controller (`public/js/cards/editor-spellcheck/controller.js` im Hauptrepo) wird ins OTA-Bundle gezogen und im Boot ([WebAssets.swift](schreibwerkstatt-focuseditor/Web/WebAssets.swift) `indexHTML`) verdrahtet; statt direktem `fetch` laufen Prüfung + Wörterbuch über die obigen Bridge-Ops. Settings (enabled/url/picky/rules) liegen **serverseitig** in `app_settings` und werden vom Proxy angewandt — der Client liefert nur Text + `bookId`/`pageId`. **Locale:** Client sendet `language:"auto"` + `bookId`; serverseitig gewinnt `getBookLocale(bookId)` → `de-CH`. Online-only (kein Offline-Kern-Inhalt); offline/`404` degradiert still. Voraussetzung im Hauptrepo (SSoT): `controller.js` macht seine zwei `fetch` über injizierbare `checkText`/`addWord`-Callbacks (Default bleibt `fetch`), und `lib/editor-bundle.js` nimmt `controller.js` + `css/editor/spellcheck.css` + `icons.svg` ins OTA-Bundle auf (im Hauptrepo erledigt).

**Offline-Boot-Lücke (Spellcheck-Nachzug):** Der Spellcheck-Controller wird beim Boot einmal initialisiert (`initSpellcheckIfEnabled`, im Boot-Glue selegriert); schlägt `spellcheckConfig` dabei fehl (App startete offline / Server nicht erreichbar → `{enabled:false}`), wird der Controller nie importiert/mounted — und ohnehin nie später im laufenden Boot-Modul nachgezogen. Deswegen hängt der Boot die Funktion früh an `window.__focusBridge._trySpellcheckInit` (vor jeglichem `await`) und Swift ruft sie über `EditorBridge.pushDeferredSpellcheckInit()` erneut auf, sobald `SyncEngine.onServerReached` feuert (am Ende jedes erfolgreichen `syncNow`-Durchlaufs). JS-seitig idempotent (`if (window.__spellcheck) return`), Swift-seitig über das Flag `spellcheckDeferredDone` vor Retry-Spam geschützt; der Hook ist einschüssig pro Server-Sitzung und wird in `AppCore.switchServer()` zurückgesetzt, damit ein Serverwechsel einen frischen Versuch gegen den neuen Server erlaubt. Boot-Race-sicher: ist die FN beim ersten Versuch noch nicht registriert (Boot-Modul noch nicht gelaufen), liefert der JS-Aufruf `null` zurück und Swift setzt das Flag NICHT — der nächste Sync-Tick versucht erneut.

**Synonyme (⌘⇧S):** Analog zur Rechtschreibung — ein **eigenständiger, Alpine-freier** Synonym-Controller (`public/js/cards/editor-synonyme/controller.js` im Hauptrepo, `export createSynonymController`) wird ins OTA-Bundle gezogen und im Boot ([WebAssets.swift](schreibwerkstatt-focuseditor/Web/WebAssets.swift) `indexHTML`) verdrahtet. Trigger ist **⌘⇧S** auf einem Wort; der Controller baut Menü + Picker selbst (kein Fork der SPA-Alpine-Karte). Statt direktem `fetch` laufen Thesaurus + KI über die Bridge-Ops `synonymsThesaurus`/`synonymsAi`; die Ersetzung nutzt den geteilten `apply-replacement.js`-Helper (markiert die Seite dirty). UI-Strings kommen lokalisiert über `synonymConfig.i18n` (de/en). Online-only; offline/leeres Ergebnis degradiert still. Quellen: OpenThesaurus (synchron, nur Deutsch) + KI-Job (`POST /jobs/synonym`, der Swift-Kern pollt fertig). Voraussetzung im Hauptrepo (SSoT): der Controller ist dort als eigenes Bundle-Modul aus der Alpine-Karte (`editor-synonyme-card.js`) zu `createSynonymController` mit injizierbaren `lookupThesaurus`/`lookupAi`/`onApplyReplacement`/`i18n`-Callbacks refaktoriert und in `lib/editor-bundle.js` (`ENTRY_MODULES` + `css/editor/synonym-menu.css`) aufgenommen (im Hauptrepo erledigt). Fehlt das Modul (älteres gecachtes Bundle), überspringt der Client-Boot den Import still (try/catch wie Spellcheck) — die App bleibt lauffähig, die Funktion ist inaktiv.

Bridge-Kanal **Swift → JS** (`callAsyncJavaScript` in `contentWorld: .page`): Die Facade stellt einen Event-Bus `window.__focusBridge.on(event, cb)` / `_receive(event, payload)` bereit. Swift sendet:
- `serverUpdate { pageId, html, baseUpdatedAt, force }` → offene Seite wurde serverseitig aktualisiert → still neu laden. **Awaitbarer Direktaufruf** `window.__focusBridge._serverUpdate(payload)` (kein Event-Bus), Antwort `true` = übernommen. Der Glue prüft SELBST, ob die Seite noch offen und unberührt ist (Swifts `openPageId`/`isDirty` sind über die IPC immer etwas alt) und lehnt sonst ab; dann dreht `SyncEngine.reloadOpenPageOrRevertBase` Basis + Ancestor zurück, damit der nächste Push per 409 merged statt die Server-Änderung zu überschreiben. `force:true` (Konflikt „Server übernehmen", Revision wiederhergestellt) ersetzt auch eine dirty Seite, solange sie offen ist.
- `openPage { pageId, html, baseUpdatedAt }` → nativer Picker hat eine Seite gewählt → im Editor öffnen.
- `closePage {}` → Buchwechsel: offene Seite schliessen → der Editor-Glue sichert den aktuellen Stand (local-first) und leert die Schreibfläche, damit der Text des alten Buchs nicht stehenbleibt. Der Swift-Kern öffnet danach den Seiten-Picker (`LibraryStore.selectBook` bei echtem Wechsel → `pickerOpenRequest`).
- `focusGranularity { granularity }` → Fokus-Stufe live umgeschaltet (CSS-Klasse `focus-mode--<value>`).
- `editorTypography { … }` → Typografie live umgeschaltet; der Boot-Glue setzt CSS-Custom-Properties auf `:root` + injiziert EIN `<style id="sw-native-typography">`, das `.focus-editor__content` überschreibt (Override-Schicht über dem unveränderten Editor-CSS — kein Fork).
- `history { action }` → `undo`|`redo`: Widerrufen/Wiederherstellen in der Historie des gebündelten Editors (`window.__standalone.undo()/redo()`, SSoT `shared/edit-history.js`). Ausgelöst vom Bearbeiten-Menü (`HistoryMenuCommands`), weil das Menü-Kürzel ⌘Z vor der WebView greift; Whitelist in `EditorBridge.applyHistory`. Älteres Bundle ohne Handle-API → stiller Fallback auf `document.execCommand`.
- `normalizeQuotes { language, region }` → Anführungszeichen der offenen Seite auf den Buch-Stil ziehen (Toolbar-Icon `quote.opening`). Der Glue importiert das gebündelte `quote-normalize.js` (SSoT-Modul, kein Fork) und nutzt dessen **fetch-freie** Exports `resolveQuoteStyle(language, region)` + `normalizeQuotes(rootEl, style)` (de-CH → «», de-DE → „", en → "" …); danach ein synthetisches `input`-Event (dirty + Autosave) und ein sofortiger local-first `save()`. Die Buch-Locale liefert der Swift-Kern über `GET /booksettings/:id` (`EditorBridge.bookQuoteLocale`, `LibraryStore.normalizeQuotes()` → `bridge.normalizeQuotes()`), weil der modulinterne `fetch('/booksettings/:id')` in der lokalen WebView (swk-app://) ins Leere liefe; ohne Server-Antwort Fallback de/CH. Fehlt das Modul (älteres gecachtes Bundle), degradiert der Glue still. Voraussetzung im Hauptrepo (SSoT): `quote-normalize.js` ist als Entry in `lib/editor-bundle.js` (`ENTRY_MODULES`) aufgenommen, damit es ins OTA-Bundle kommt (im Hauptrepo erledigt).
- `synonyms { x?, y? }` → Synonym-Hilfe für das Wort unter Auswahl/Caret öffnen — der klickbare Zwilling zu ⌘⇧S: Toolbar-Icon `text.book.closed` (`LibraryStore.openSynonyms()`) **und** Eintrag im Kontextmenü der Schreibfläche ([Web/FocusEditorWebView.swift](schreibwerkstatt-focuseditor/Web/FocusEditorWebView.swift), `willOpenMenu` an einer `WKWebView`-Subklasse — WebKit baut das Menü selbst). Der gebündelte Synonym-Controller (SSoT) exportiert **keinen** programmatischen Trigger, nur `attach/detach` — der Glue feuert darum synthetisch dessen ⌘⇧S-`keydown` am Editor-Root, statt die Wort-/Selektions-Logik zu forken. `x`/`y` (CSS-Viewport, nur vom Kontextmenü) setzen vorher den Caret via `caretRangeFromPoint`, weil der Rechtsklick ihn im contenteditable nicht zuverlässig verschiebt; eine bestehende Auswahl, in die geklickt wurde, bleibt. Swift macht die WebView vor dem Aufruf wieder zum First Responder (der Klick in der Titelleiste nimmt ihr Fokus + Caret). Sichtbar nur bei offener Seite und lokal aktiver Synonym-Hilfe.

Block-Merge (409): `window.__focusBridge._merge3(base, local, server)` lädt das gecachte `block-merge.js` dynamisch und liefert `{ merged, conflictCount }`. Der Swift-Kern ruft das beim 409-Push: `conflictCount == 0` → gemergtes HTML mit neuer Basis erneut pushen (still); `> 0` → Konflikt erfassen (Editor-Konflikt-UI). Merge-Ancestor (`base`) hängt als Spalte `page.serverBaseHtml` am LocalStore (`serverBaseHtml(id:)` / `setServerBaseHtml(_:id:)`) — **nicht** im `SyncState`-Snapshot: dort kodierte jede Mutation das volle HTML aller Seiten neu (gemessen 20 MB alle ~5 s, ~50 % CPU-Spitzen). Alt-Snapshots werden von `SyncEngine.migrateLegacyAncestors()` einmalig umgezogen.

**Widerrufen / Wiederherstellen (⌘Z / ⌘⇧Z):** Die Historie liegt im **Hauptrepo** (SSoT `public/js/editor/shared/edit-history.js`): eine entprellte Snapshot-Historie (HTML + Caret-Offset) mit satzweisen Schritten, die der gebündelte Focus-Editor selbst führt. **Kein Client-eigener History-Stack** (das wäre ein Editor-Fork) — der Client liefert nur den Menü-Weg dorthin.

- **Warum überhaupt nicht WebKits Undo:** In der WKWebView fasst WebKit im contenteditable **alles seit dem letzten Mausklick in EINEN Schritt** zusammen; Pfeiltasten, Enter, Backspace, Auto-Save, Fokuswechsel, Fenster-Deaktivierung, JS-Selektionsänderungen und selbst die nativen AppKit-Kommandos `moveLeft:`/`moveRight:` trennen **nicht** (alle einzeln nachgemessen, Sonde: WKWebView + generiertes `index.html` + gestubbte Bridge + echte Tastenanschläge). Ein versehentliches ⌘Z entfernte damit den ganzen Abschnitt — genau dieser Fall ist in der Praxis passiert. Deshalb sind die AppKit-Standardeinträge **ersetzt** (`CommandGroup(replacing: .undoRedo)` → `HistoryMenuCommands`).
- **Warum über die Bridge und nicht über das Editor-Kürzel:** Der gebündelte Editor fängt ⌘Z in der Seite selbst ab (`focus/listeners.js`), aber in diesem Client erreicht die Taste die WebView nie — ein Menü-Kürzel greift app-weit vorher. Der Menüpunkt löst darum das `history`-Event aus (wie das Format-Menü ⌘B/⌘I/⌘U) und der Glue ruft `window.__standalone.undo()/redo()`.
- **Routing nach First Responder:** ⌘Z gilt app-weit und muss auch im Picker-Suchfeld und in den Einstellungen wirken. `HistoryMenuCommands` prüft, ob der Fokus in der `WKWebView` liegt → Bridge; sonst `NSApp.sendAction("undo:")`, also dorthin, wo die ersetzten Standardeinträge gelandet wären. Die Menüpunkte sind bewusst **immer aktiv**: ein deaktivierter Eintrag würde das Kürzel nicht verbrauchen, und ⌘Z fiele auf WebKits groben Stack zurück.
- **Älteres gecachtes Bundle** (ohne `undo()` am Standalone-Handle): der Glue fällt still auf `document.execCommand('undo')` zurück — grobe Körnung statt totem ⌘Z; der nächste Start zieht das neue Bundle.
- **Hinweis-Banner bleibt:** Das Restore der SSoT feuert ein `input`-Event mit `inputType: historyUndo`/`historyRedo` (harter Vertrag) — daran hängen Dirty-Flag, Autosave, Live-Statistik und der Umfang-Hinweis (`historyEdit`, s. oben).
- **Bestehender Text ist sicher:** per `innerHTML` gerenderter Inhalt ist in WebKit ohnehin nicht undo-bar, und die SSoT-Historie startet pro Seite mit einer Baseline (`setPage` → `reset`), die sie nie unterschreitet.
- **Notausgang** (Historie leer, App neu gestartet): die Seiten-Revisionen des Servers (`page_revisions`) — **in der App** über „Frühere Fassungen …" (⌘⇧R, s. unten).

Spellcheck-Nachzug (Offline-Boot-Lücke): `window.__focusBridge._trySpellcheckInit` (Platzhalter `null` in der at-document-start-Facade; der Boot weist die echte `initSpellcheckIfEnabled`-Fn vor jeglichem `await` zu) wird von `EditorBridge.pushDeferredSpellcheckInit()` direkt aufgerufen, sobald `SyncEngine.onServerReached` feuert — kein `_receive`-Event-Bus-Subscriber, weil der direkte Aufruf Race-sicherer gegen „FN noch nicht registriert" ist (Swift wertet `null` als „noch nicht bereit" und versucht im nächsten Tick erneut). Siehe „Offline-Boot-Lücke (Spellcheck-Nachzug)" oben.

**Regel:** Die Facade ist die **einzige** Kopplungsschicht. Kein direkter `fetch` aus dem gebündelten Editor-Code. Wenn der Editor eine neue Root-Methode braucht, wird sie zuerst in der Facade ergänzt und der Bridge-Vertrag hier dokumentiert.

## Server-Schnittstelle

Basis-URL konfigurierbar (Default Prod-Host). Auth über **Device-Token** (Bearer `swd_…`), nicht OIDC.

### Auth (Device-Token)
- Einmaliger Online-Login: Browser-OAuth-Flow am Server → User stellt im `/me`-Bereich ein Device-Token aus → Klartext (`swd_<64 hex>`, serverseitig SHA256-gehasht) **genau einmal** sichtbar.
- **Kein Self-Minting:** Der Client kann ein Token **nicht selbst ausstellen** — `POST /me/device-tokens` lehnt mit `403 DEVICE_TOKEN_SELF_MINT_FORBIDDEN` ab, wenn der Request selbst per Device-Token läuft ([routes/usersettings.js](../../ClaudeProjects/schreibwerkstatt/routes/usersettings.js)). Der Login-Flow ist darum **Copy-Paste**: User stellt das Token in der Web-`/me`-Ansicht aus und fügt es im Client ein. Validierung im Client über `GET /me/device-tokens` (funktioniert mit Device-Token, nur das Ausstellen ist gesperrt).
- Client cached das Token im **macOS Keychain** (nie in UserDefaults/Plist).
- Jeder Request: `Authorization: Bearer swd_…`. Der Server löst auf den echten User + dessen echte Rolle auf und respektiert das Status-Gate (suspended/deleted → 401).
- Token-Verwaltung am Server: `GET/POST /me/device-tokens`, `POST /me/device-tokens/:id/revoke`, `DELETE /me/device-tokens/:id`.
- 401 → Token ungültig/widerrufen: Client muss neu authentifizieren (Token aus Keychain löschen, Re-Login anstoßen). Ungespeicherte lokale Inhalte **nie** verwerfen.

### Editor-Bundle (OTA) — `GET /content/editor-bundle.zip`

*(Server: erledigt, [routes/content.js](../../ClaudeProjects/schreibwerkstatt/routes/content.js) + [lib/editor-bundle.js](../../ClaudeProjects/schreibwerkstatt/lib/editor-bundle.js))*
- **Auth nötig** (Bearer `swd_…`, globaler Guard wie alle `/content`-Routen).
- Liefert ein **DEFLATE-ZIP** (JSZip) mit der JS-Import-Closure (`js/…`), den Focus-Editor-CSS (`css/…`) und `bundle-manifest.json` (`{ sourceCommit, jsFiles[], cssFiles[] }`). **Kein `index.html`** (Client-Glue, s. o.).
- **ETag** (`"sha256…"` über Commit + sortierte Datei-Hashes) + `If-None-Match` → **304** ohne Body. Der Client fragt bei jedem Online-Start konditional an.
- **Client-Seite:** [Web/EditorBundleStore.swift](schreibwerkstatt-focuseditor/Web/EditorBundleStore.swift) lädt (ETag aus Sidecar), entpackt mit [Web/MiniZip.swift](schreibwerkstatt-focuseditor/Web/MiniZip.swift) (bordeigener ZIP/DEFLATE-Reader — App ist sandboxed, kein `Process`/`unzip`, keine SPM-Dependency), schreibt `index.html` aus dem Manifest und tauscht den Cache **atomar**. Cache-Ort: `Application Support/schreibwerkstatt-focuseditor/web-cache/` (+ `web-cache.meta.json` für ETag/Commit).
- **Refresh-Timing:** Mit vorhandenem Cache startet der Editor sofort; der Refresh läuft still im Hintergrund und greift erst beim **nächsten** Start (kein Hot-Swap mitten im Schreiben → Datenverlust-Schutz). Ohne Cache: blockierender Erst-Download (UI-Lade-/Fehlerzustand in [ContentView.swift](schreibwerkstatt-focuseditor/ContentView.swift)).

### Sync (Polling: Pull + Push)

Der Sync hält den lokalen Spiegel **aktuell, auch wenn eine Seite in einer anderen Session geändert wird** (Web-App, anderes Gerät). Mechanismus ist **Polling** des bestehenden Server-Endpoints — kein SSE/WebSocket-Push.

**Pull (Deltas ziehen) — `GET /content/books/:book_id/sync`** *(Server: erledigt, [routes/content.js](../../ClaudeProjects/schreibwerkstatt/routes/content.js) `GET /books/:book_id/sync`)*
- **Buch-skopiert** (braucht ein gewähltes `book_id`), nicht seiten-global. Ein `/sync/delta`-Endpoint existiert **nicht** — das war ein veralteter Plan.
- Query: `since=<ISO-8601>` + `since_id=<page_id>` + `limit=<n≤200>`. Ohne `since` = Voll-Pull (Baseline) des ganzen Buchs.
- **Keyset-Cursor `(updated_at, page_id)`:** Antwort liefert `cursor: { since, since_id }` (Position NACH der letzten gelieferten Seite) + `has_more`. Solange `has_more=true`, mit dem zurückgegebenen Cursor weiterpagen, bis erschöpft. Cursor **lokal persistieren** (since + since_id), monoton vorrücken.
- Antwort-Seiten tragen vollen HTML-Body: `{ page_id, page_name, chapter_id, updated_at, html }` + `now` (Server-Stempel).
- **Enthält eigene Edits** (anders als `/content/books/:id/changes`, das self-exkludiert + ohne HTML ist — das ist der Web-Collab-Toast-Pfad, nicht für uns). Der Client kann darum jeden Server-Stand übernehmen, auch von anderen eigenen Geräten/Sessions.

**Cross-Session-Frische (Polling-Loop):** Die SyncEngine pollt periodisch (Richtwert 5 s) `…/sync` mit dem gespeicherten Cursor — **nur solange App/Fenster aktiv** (Scene-Phase `.active` über `setActive(_:)`; im Hintergrund pausieren, beim Reaktivieren sofort einen Tick). Zusätzlicher Trigger: Reachability (Netz wieder erreichbar → sofort ein Tick). Eingehende Seiten in den LocalStore mergen, `baseUpdatedAt = Server-updated_at` setzen. Ist die **im Editor offene Seite** betroffen:
  - Editor **sauber** (nicht dirty) → Inhalt in der WebView still neu laden (Bridge-`load`), neuer `baseUpdatedAt` = Server-`updated_at`.
  - Editor **dirty** → lokalen Stand **nicht** überschreiben (Datenverlust-Schutz). Konflikt wird erst beim nächsten Push aufgelöst (409 → Block-Merge, s.u.).

**Push** — `PUT /content/pages/:id` mit `expected_updated_at` ([routes/content.js](../../ClaudeProjects/schreibwerkstatt/routes/content.js) `PUT /pages/:page_id`, Backend `savePage`). **Wichtig:** `expected_updated_at` ist der **exakte Server-ISO-String** (`WHERE updated_at = ?`, atomar) — nie aus Epoch-ms rekonstruieren, sonst bricht der Match. Der Client führt die ISO-Basis darum getrennt vom Epoch-ms-Store (`Sync/SyncState.swift`).
  - `200` → übernommen, Server-`updated_at` als neue Basis speichern, Outbox-Eintrag droppen.
  - `409 PAGE_CONFLICT` → Server liefert `server_updated_at` + `server_editor_email/name`. Client zieht den frischen Server-Stand (Pull der einen Seite) und löst per **3-Wege-Block-Merge** (`block-merge.js`, `data-bid`-basiert) in der WebView auf: kollisionsfrei → still mergen + erneut pushen; echte Block-Kollision → Konflikt-Modal des Editors.
  - `404 PAGE_NOT_FOUND` → **PUT updated nur, legt nicht an.** Neue Seiten entstehen über `POST /content/pages`, nicht über den Push. Ohne Server-Basis (Seite nie gepullt) wird darum **nicht** gepusht.
  - `423 PAGE_LOCKED` → Seite ist serverseitig gesperrt (Lektorats-Lock); später erneut versuchen, lokalen Stand behalten.

**Deletes:** `/sync` meldet nur geänderte/neue Seiten, **keine Löschungen**. Gelöschte Seiten reconciled der Client über `GET /content/books/:book_id/tree` (Soll-Bestand abgleichen).

**Ort des Codes:** [Sync/](schreibwerkstatt-focuseditor/Sync/) (Engine + State + Reachability + Models). Der konkrete Ablauf (Push/409-Merge/Pull/Delete-Reconcile, `applyServerPage`/`markPushed`-Semantik, Scene-Phase-Verdrahtung) steht in [ARCHITECTURE.md](ARCHITECTURE.md) §5.

- Inhalte fließen ausschließlich über die Content-Store-Semantik des Servers — kein Voll-Buch-`.swbook` für den Live-Sync (zu grob).

### Schreibzeit — `POST /history/writing-time`

Native Entsprechung zum Schreibzeit-Heartbeat der Web-Plattform (`public/js/book/writing-time.js`). Der [WritingTimeTracker](schreibwerkstatt-focuseditor/Writing/WritingTimeTracker.swift) misst die im Editor verbrachte **Wall-Clock-Zeit** und meldet sie alle ~15 s als `{ book_id, seconds }`; der Server addiert pro (User, Buch, Tag) auf (Tabelle `writing_time`). **Kein Bridge-Op** — direkter Swift→Server-Call (Auth wie alles über Bearer-Token). Gezählt wird, solange **Fenster aktiv** (Scene-Phase `.active`, `setActive(_:)` wie der Sync-Poll) **und eine Seite im aktiven Buch offen** ist (Kontext-Bedingung wie die Web-Seite: `(editMode||focusActive) && selectedBookId && visible`). **Zusätzlich** (anders als die Web-Plattform) eine **Idle-Erkennung**: liegt das Tippen länger als `idleThreshold` (fest 120 s) zurück, pausiert die Schreibzeit — anrechenbar ist nur Zeit bis `letzte Aktivität + 120 s`. „Aktivität" ist jede `reportStats`-Meldung der WebView (debounced bei `input` → echtes Tippen), über `bridge.onActivity` → `WritingTimeTracker.notifyActivity()`; ein frischer Segment-Start (Seite geöffnet / Fenster aktiviert) zählt ebenfalls als Aktivität. Pro Ping auf 3600 s gedeckelt (Uhrsprung-Schutz wie serverseitig). **Best-effort**, aber **persistent gepuffert**: `pending` (Sekunden je Buch) und die Tages-Summe liegen server-skopiert in den UserDefaults (`writingtime.pending.<slug>` / `writingtime.today.<slug>`), sodass Offline-Phasen **und** ein App-Neustart sie nicht verlieren; beim Beenden (`NSApplication.willTerminate`) wird das laufende Segment noch abgeschlossen (⌘Q liefert keinen verlässlichen Scene-Phasen-Wechsel). Inhalte/Outbox sind nie betroffen. Eingangs-Signale (aktives Buch + offene Seite) kommen über `LibraryStore.onWritingContextChange` → `updateContext(bookId:hasOpenPage:)`. Für Tests sind Uhr (`now`) und `UserDefaults` injizierbar und der Heartbeat-Rumpf als `heartbeatTick()` aufrufbar (s. `WritingTimeTrackerTests`).

### Lektorat der offenen Seite — `POST /jobs/check` + `GET /jobs/:id`

Toolbar-Knopf (Icon `checkmark.seal`, nur bei offener Seite) startet den **serverseitigen** Lektorats-Job für die offene Seite — dasselbe Job-Backend wie in der Web-App ([routes/jobs/lektorat.js](../../ClaudeProjects/schreibwerkstatt/routes/jobs/lektorat.js), `POST /jobs/check` mit `{ page_id, book_id?, page_name? }` → `{ jobId, existing? }`). **Kein Bridge-Op** — direkter Swift→Server-Call ([Lektorat/LektoratJobStore.swift](schreibwerkstatt-focuseditor/Lektorat/LektoratJobStore.swift)); die WebView ist an diesem Feature nicht beteiligt.

Ablauf: **erst sichern + pushen**, dann Job. Der Server lektoriert den **Server-Stand** der Seite, darum flusht der Store vor dem Anlegen den offenen Draft und fährt einen Sync-Durchlauf (`prepare`-Closure, in `AppCore` auf `bridge.flushDraftSave()` + `sync.syncNow(manual:)` verdrahtet = ⌘S-Semantik, nur awaitbar). Danach pollt der Swift-Kern `GET /jobs/:id` (1,5 s, Deckel ~6 min) und leitet daraus die Phasen `preparing → running(progress) → done(count)/failed` ab; „Abbrechen" (Klick auf den laufenden Knopf) stoppt den Poll und storniert per `DELETE /jobs/:id`. Server-Zustände: `403` = fehlende `lektor`-Rolle am Buch, `404` = Seite/Buch weg, `job.error` = i18n-Key des Server-Katalogs (nur ins Log, dem Nutzer eine generische Meldung).

Die **Beanstandungen selbst bleiben serverseitig** (Lektorats-Karte der Web-App) — dieser Client zeigt nur Anzahl + Fehlerzustand in einem Banner über der Schreibfläche ([Lektorat/LektoratToolbarButton.swift](schreibwerkstatt-focuseditor/Lektorat/LektoratToolbarButton.swift)) plus einen Deep-Link `#book/<bookId>/page/<pageId>` in den Standard-Browser. Bewusst kein Findings-UI im Client: das wäre ein Editor-Fork (Karte + Replace-Logik) und widerspricht „nur der Schreibmodus". Online-only; offline degradiert es als Fehler-Banner (lokale Inhalte sind nie betroffen).

### Seiten anlegen/umbenennen/löschen — `POST`/`PUT`/`DELETE /content/pages`

Ablage ▸ „Neue Seite …" (⌘N) sowie Umbenennen/Löschen im Kontextmenü des Seiten-Pickers. **Kein Bridge-Op** — direkter Swift→Server-Call ([Library/PageAdminController.swift](schreibwerkstatt-focuseditor/Library/PageAdminController.swift)).

- **Anlegen:** `POST /content/pages` mit `{ book_id, chapter_id?, name }` → die geladene Seite. **ONLINE-ONLY, bewusst.** Der Sync-Push kennt nur `PUT /content/pages/:id` und der ist update-only (404 ohne Seite); eine offline angelegte Seite hätte keine echte ID, müsste mit einem Platzhalter durch Outbox, Recents, `lastOpenPage` und den Editor-Glue wandern und beim ersten Sync überall umgeschrieben werden — genau die Sorte Zustand, in der Datenverlust entsteht. Der Dialog sagt das vorher (Offline-Hinweis), statt hinterher zu scheitern. **Geschrieben wird nie offline** — nur das Anlegen braucht Netz.
- **Umbenennen:** `PUT /content/pages/:id` mit `{ name }` und **ohne** `expected_updated_at` (der Server trennt Rename vom Body und bewahrt den letzten Text-Autor). Der Rename bewegt `updated_at` → die Antwort liefert die neue Basis, die der Client sofort übernimmt; sonst liefe der nächste Body-Push in einen 409, den der Nutzer selbst ausgelöst hat.
- **Löschen:** `DELETE /content/pages/:id` (Papierkorb am Server), **erst danach** lokal (`store.deletePage`). Umgekehrt wäre der Text weg, während die Seite serverseitig weiterlebt.
- Nach jedem Erfolg wird der lokale Spiegel sofort nachgezogen (`applyServerPage`/`deletePage`) statt auf den nächsten Poll-Tick zu warten. Fehlerfälle: `403` = fehlendes Editor-Recht am Buch, `404` = Seite weg, `423` = Lektorats-Lock.

### Frühere Fassungen — `GET/POST /content/pages/:id/revisions[/:rev[/restore]]`

Ablage ▸ „Frühere Fassungen …" (⌘⇧R, nur bei offener Seite) — Liste, Klartext-Vorschau, Wiederherstellen ([Revisions/PageRevisionStore.swift](schreibwerkstatt-focuseditor/Revisions/PageRevisionStore.swift) + [RevisionsView.swift](schreibwerkstatt-focuseditor/Revisions/RevisionsView.swift)). **Kein Bridge-Op** — direkter Swift→Server-Call.

Warum das trotz „nur der Schreibmodus" hierher gehört: es ist der Notausgang aus dem einen Datenverlust-Pfad, den die App nicht selbst beherrscht (WebKit-Undo verklumpt, s. „Widerrufen / Wiederherstellen"). Ohne ihn endete der `HistoryNoticeBanner` bei „öffne die Web-App".

Bewusst **kein Diff und kein zweiter Editor** — die Ansicht beantwortet „welche Fassung will ich zurück", nicht „was genau hat sich geändert" (das wäre ein Editor-Fork). Das Wiederherstellen macht der Server (`POST …/restore` schreibt die alte Fassung als NEUE Revision zurück → selbst widerrufbar); der Client zieht danach `SyncEngine.pullPage`, was die saubere offene Seite still neu lädt. Online-only; offline zeigt die Ansicht einen Hinweis statt einer leeren Liste.

### Buch exportieren (Markdown) — `GET /export/book/:id/md`

Ablage ▸ „Buch exportieren …" schreibt das aktive Buch als EINE Markdown-Datei ([Export/](schreibwerkstatt-focuseditor/Export/): `BookExportController` (Server-Call + Save-Panel) + `BookExportBanner`). **Server-Export:** der Client ruft `GET /export/book/:id/md` auf (dieselben Export-Builder wie die Web-App, kein zweiter Konverter im Client) und fragt **erst danach** nach dem Zielort — offline wählt niemand eine Datei, um hinterher den Fehler zu sehen. Der Server exportiert seinen **eigenen** Stand, darum läuft vorher derselbe Vorlauf wie beim Lektorat (`prepare` = `bridge.flushDraftSave()` + `sync.syncNow(manual:)`, in `AppCore` verdrahtet); was danach noch in der Outbox liegt (409-Konflikt, Lektorats-Lock), weist das Banner als „N Seiten mit ungesyncten Änderungen“ aus, statt still einen alten Stand als vollständiges Backup auszugeben. Server-Fehler werden auf lokalisierte Sätze abgebildet (`export.error.*`). **Online-only** — bewusst aufgegeben gegenüber dem früheren lokalen Export. **Bewusst ohne Tastenkürzel:** das naheliegende ⌘⇧E gehört der Fokus-Umschaltung im Editor, und ein Menü-Kürzel nähme ihr die Taste vor der WebView weg.

### Konto löschen (in-app) — `DELETE /me/account`

App-Store-Guideline 5.1.1(v) verlangt das Löschen des Kontos **in der App**. Einstellungen → Konto → „Konto löschen …" ([Settings/AccountDeletionSection.swift](schreibwerkstatt-focuseditor/Settings/AccountDeletionSection.swift)) öffnet ein Sheet mit den Folgen + Tipp-Bestätigung (`LÖSCHEN`/`DELETE`, lokalisiert); der Request selbst trägt immer den konstanten Protokollwert `{ "confirm": "DELETE" }`. **Kein Bridge-Op** — direkter Swift→Server-Call ([Auth/AccountDeletionController.swift](schreibwerkstatt-focuseditor/Auth/AccountDeletionController.swift)).

Server-Vertrag (implementiert im Hauptrepo: [routes/usersettings.js](../../ClaudeProjects/schreibwerkstatt/routes/usersettings.js) `DELETE /account` + [lib/account-delete.js](../../ClaudeProjects/schreibwerkstatt/lib/account-delete.js), Doku [docs/clients.md](../../ClaudeProjects/schreibwerkstatt/docs/clients.md)): `200 { ok: true }` = gelöscht, alle Tokens des Kontos sofort tot (**keine** Karenzfrist → kein `scheduled_purge_at`; das Feld bleibt client-seitig optional, falls es später kommt) · `400 CONFIRM_REQUIRED` · `403 ACCOUNT_DELETE_FORBIDDEN` (ENV-Admin / letzter aktiver Admin) · `404 USER_NOT_FOUND` · `500 ACCOUNT_DELETE_FAILED` (Retry ist idempotent) · `404 **ohne** error_code` = Route existiert auf diesem Server nicht → der Client zeigt den Browser-Fallback (`…/#profil`) statt einer Sackgasse. **Demo-Konto:** derselbe Aufruf **setzt es zurück** statt es zu löschen (`200 { ok: true, demo_reset: true }`, Tokens bleiben gültig) — der Client behandelt es bewusst wie jede Löschung (lokal aufräumen + abmelden), damit der App-Review den vollen Ablauf sieht und die Demo nutzbar bleibt.

**Erst nach bestätigter Server-Löschung** räumt der Client lokal auf (`AppCore.purgeLocalDataForCurrentServer()` → [Store/LocalDataPurge.swift](schreibwerkstatt-focuseditor/Store/LocalDataPurge.swift)): Sync anhalten, Namespace-Ordner `servers/<slug>/` (SQLite-Spiegel + `syncstate.json`) löschen, server-skopierte UserDefaults (`…​.<slug>`) entfernen, frische leere DB öffnen, dann abmelden (Keychain-Token weg → Login-Screen). Das gecachte Editor-Bundle bleibt (App-Assets, keine Nutzerinhalte; ein Neu-Download wäre ohne Token unmöglich). **Einziger Pfad, der lokale Inhalte verwirft** — überall sonst gilt „Datenverlust-Schutz vor allem": bei jedem Fehler (403/404/offline/401) bleibt alles unangetastet.

## Verzeichnislayout

App-Sources unter [schreibwerkstatt-focuseditor/](schreibwerkstatt-focuseditor/), nach Verantwortung gruppiert. Die Datei-für-Datei-Karte (welcher Typ wo, wer wen besitzt) steht in [ARCHITECTURE.md](ARCHITECTURE.md) §2–§10.

```
schreibwerkstatt-focuseditor/        App-Sources (Swift)
  *App.swift · AppCore.swift[+ServerSwitch] · ContentView.swift · AppToolbar.swift · WindowChromeController.swift
  AppLog.swift    Alle Logger (Subsystem + Kategorien) an einer Stelle
  Shortcuts.swift SSoT aller Tastaturkürzel (Menü-Bindung UND Hilfe-Liste)
  Web/        WKWebView-Host + Bridge + OTA-Lader (EINZIGE Kopplungsschicht WebView ⇄ Swift)
  Store/      GRDB-LocalStore + Outbox + PageMetrics (Zeichen-/Wortzahl je Seite) + LocalDataPurge (lokales Aufräumen nach Konto-Löschung)
  Sync/       SyncEngine + Reachability + SyncState + SyncModels + SyncPreferences
  Auth/       Keychain + Device-Token + Login + APIClient + ServerConfig + AccountDeletionController + ServerNamespace/ServerScopedKeys (die `…​.<slug>`-Defaults-Schlüssel)
  Content/    ContentAPI (Lese-Zugriff Buch-/Kapitel-Struktur, Server-Soll)
  Library/    LibraryStore + native Picker (BookPicker, PagePickerOverlay[+Rows/+Keyboard]) + PagePickerModel (PURE Filter-/Gruppierungs-/Summen-Logik des Seiten-Pickers, getestet). Zeichen-/Wortzahl je Zeile und die Summenzeile kommen aus dem LOKALEN Spiegel (`LibraryStore.pageStats` ← `store.pageStats(bookId:)`), weil der Server-Tree keine Zählwerte liefert; nie gepullte Seiten zeigen „—".
  Theme/      Appearance + Typography (Controller) + BrandColor + BrandFont + NoticeBanner (die EINE Bannerform über der Schreibfläche) + ServerSeededChoice („lokale Wahl gewinnt, sonst folgt der Server")
  Jobs/       JobPolling (GET /jobs/:id abwarten — geteilt von Lektorat + KI-Synonymen)
  Focus/      FocusController (lokale Fokus-Granularität)
  Writing/    WritingStatsStore (Live-Wortzahl/Lesezeit/Schreibziel/Tages-Delta) + WritingTimeTracker (Schreibzeit-Heartbeat → POST /history/writing-time)
  Conflict/   ConflictDiff (HTML→Absätze + absatzweiser Diff) + ConflictResolutionView (Nebeneinander-Sheet, informierte 409-Auflösung)
  Revisions/  PageRevisionStore (frühere Fassungen der offenen Seite: Liste/Vorschau/Restore) + RevisionsView (⌘⇧R)
  Export/     BookExportController (Server-Call + Save-Panel) + BookExportBanner
  Diagnostics/ DiagnosticsReport (PURER Zustandsbericht für Support-Anfragen; ohne Token, ohne Manuskript-Text)
  Lektorat/   LektoratJobStore (Server-Lektorat der offenen Seite: POST /jobs/check + Poll) + LektoratToolbarButton/-ResultBanner
  Update/     UpdaterController (Sparkle-Auto-Update, NUR im DMG-Target hinter `#if SPARKLE`; Config in Config/Info.plist + Config/Focuseditor.entitlements)
  Settings/   SettingsView (⌘, — 7 Tabs)
  Localization/  Zweisprachigkeit de/en: Localization.swift (t()/tn() + L10nStore + LocalizationController) + mac-de.json/mac-en.json (gebündelt) + I18nBundleStore (OTA-Override)
```

**Einstellungen (alle gerätelokal, UserDefaults):** App-Sprache (de/en/System) + Server-URL + Lieblingsbuch (Allgemein) · Hell/Dunkel/System + Fokus-Granularität + Auto-Hide-Toolbar (Darstellung) · Schriftgrösse/-art, Zeilenhöhe, Spaltenbreite (measure), Papier-Ton (Typografie) · Wortzahl-Anzeige + Zählwert im Seiten-Picker (`picker.metric`: Zeichen/Wörter/beides/aus) + Wort-Ziel pro Seite (Schreiben) · Poll-Kadenz/Pause/manueller Sync (Sync) · LanguageTool an-aus + Sprach-Override (Rechtschreibung) · Abmelden + App-Version/Update (Sparkle) + Editor-Bundle-Version/Update + Cache leeren + Diagnose kopieren + Konto löschen (Konto). Editor-wirksame Werte (Typografie, Fokus) fliessen über die Bridge als CSS — **kein Editor-Fork**.

Der App-Sources-Ordner ist eine `PBXFileSystemSynchronizedRootGroup` (Xcode 16+) → neue Swift-Dateien kommen **automatisch** ins Target (kein pbxproj-Edit nötig).

**Editor-Cache (Laufzeit, nicht im Repo):** Das Editor-Build liegt **nicht** mehr im App-Paket, sondern wird per OTA gezogen und unter `~/Library/Application Support/schreibwerkstatt-focuseditor/web-cache/` gecacht (s. „Editor-Bundle (OTA)"). Es gibt **keinen** Build-Step und **kein** `web/`-Verzeichnis mehr.

## Harte Regeln

- **Kein Editor-Fork.** Editor-Logik, CSS und `block-merge.js` kommen aus dem Hauptrepo via OTA-Bundle (`GET /content/editor-bundle.zip`). Hier nur Bridge + Shell + Sync + Auth + OTA-Lader. Gecachten Output nie von Hand editieren.
- **WebView lädt nur lokal.** Niemals eine Server-URL in den `WKWebView` laden — die WebView liest ausschließlich aus dem lokalen Cache (`AppSchemeHandler`). Server-Kontakt (Sync **und** Bundle-Download) ausschließlich im Swift-Kern. **Einzige Ausnahme:** vom Nutzer angeklickte `http(s)`-Links (z. B. „Regel-Info" im LanguageTool-Popover, `<a target="_blank">`) — die Navigation wird in der WebView weiterhin abgelehnt, die URL aber via `NSWorkspace.open` an den Standard-Browser übergeben ([FocusWebView.swift](schreibwerkstatt-focuseditor/Web/FocusWebView.swift), `decidePolicyFor`).
- **Local-first Writes.** Jeder Save geht zuerst in LocalStore + Outbox, erst danach (bei Konnektivität) zum Server. UI nie auf Netzwerk warten lassen.
- **Token nur im Keychain.** Device-Token niemals in UserDefaults, Plist, Logs oder Bridge-Messages an die WebView leaken. Die WebView braucht das Token nicht — Netzwerk macht Swift. **Einzige Ausnahme:** der Demo-Zugang (Login-Knopf „Demo öffnen") liegt bewusst als Info.plist-Key im Binary — zur Build-Zeit aus der gitignorierten `Config/Demo.xcconfig` injiziert (`Version.xcconfig` zieht sie per `#include?`, `Auth/DemoAccess.swift` liest sie). Dort darf **nur** das Wegwerf-Demo-Konto stehen, nie ein persönliches Token; fehlt die Datei, ist der Knopf aus. Werte/Setup: `scripts/demo.env` + [SIGNING.md](SIGNING.md) „Demo-Instanz".
- **Konflikte über Block-Merge.** 409-Auflösung läuft über `block-merge.js` (3-Wege, `data-bid`), nicht über naives Last-Write-Wins. `data-bid`-Attribute nie strippen.
- **Datenverlust-Schutz vor allem.** Bei Auth-/Sync-Fehlern lokale Inhalte behalten; kein automatisches Verwerfen, kein Überschreiben ohne Merge.
- **Jeder Weg aus dem Editor flusht den Draft.** Der Editor-Autosave läuft entprellt (500–5000 ms) — zwischen letztem Tastenanschlag und Autosave-Tick liegt der Text NUR im DOM der WebView. Wer einen neuen Ausstiegspfad baut (Fenster, Szene, Beenden, Modus-Wechsel), muss ihn an einen Flush hängen. Bestand: Fenster-Schliessen (`windowChrome.onWillClose`), ⌘S/manueller Sync (`syncManually`), Lektorats-Vorlauf, Buch-Export — Swift-seitig; ⌘Q über [AppTerminationGuard.swift](schreibwerkstatt-focuseditor/AppTerminationGuard.swift) (`applicationShouldTerminate` → `.terminateLater`, 2-s-Frist); Fenster-Deaktivierung/App-Wechsel JS-seitig über `blur`/`pagehide`/`visibilitychange` im Boot-Glue (nur wenn wirklich dirty, sonst schriebe jeder Toolbar-Klick einen Outbox-Eintrag).
- **Tastaturkürzel nur über den Katalog.** Jedes Kürzel, das für den Nutzer im Client greift, steht in [Shortcuts.swift](schreibwerkstatt-focuseditor/Shortcuts.swift) — die nativ deklarierten (SwiftUI-Menü) genauso wie die, die der OTA-Editor, macOS oder der Seiten-Picker behandelt (`owner: .native/.system/.editor/.picker`). Menüs binden ausschliesslich über `.keyboardShortcut(Shortcuts.…)`, und [ShortcutsHelpView.swift](schreibwerkstatt-focuseditor/ShortcutsHelpView.swift) (Help-Menü → „Tastaturkürzel", ⌘?) rendert die Liste vollständig daraus — auch die Tasten-Capsules leitet der Katalog aus `key`/`modifiers` ab (macOS-Reihenfolge ⌃⌥⇧⌘). [ShortcutCatalogTests.swift](schreibwerkstatt-focuseditorTests/ShortcutCatalogTests.swift) setzt das durch: kein Kürzel am Katalog vorbei (`.cancelAction`/`.defaultAction` in Sheets ausgenommen), kein doppelt belegtes Menü-Kürzel, und **kein nativer Menübefehl, der ein Editor-/Picker-Kürzel verdeckt**. Letzteres ist real passiert: „Buch exportieren" hatte ⌘⇧E belegt, das der Editor für die Fokus-Umschaltung nutzt — ein Menü-Kürzel greift VOR der WKWebView, der Umschalter war also tot, während die Hilfe ihn weiter bewarb. Der Export hat seitdem bewusst **kein** Kürzel.
- **Lokalisierung (de/en) — kein hartkodierter UI-String.** Jeder nutzersichtbare Text läuft über `t("key")` (Plural: `tn(count, "baseKey")`) aus [Localization/Localization.swift](schreibwerkstatt-focuseditor/Localization/Localization.swift). Neue/geänderte Strings **immer** in **beide** gebündelten Kataloge [mac-de.json](schreibwerkstatt-focuseditor/Localization/mac-de.json) **und** [mac-en.json](schreibwerkstatt-focuseditor/Localization/mac-en.json) (Namespace `macclient.*`, flach, `{param}`-Platzhalter wie die Web-i18n). Fallback-Kette: `OTA[locale] → bundled[locale] → bundled["de"] → key`. Markennamen (z. B. „Schreibwerkstatt") bleiben literal. **Terminologie wie im Mutterprojekt (seit v4.18.0):** die Gliederungseinheit heisst im UI **«Abschnitt» / «section»**, nie «Seite»/«page» — «Seite» nur für Webseiten (z. B. „Token-Seite"). Code, Keys, API, Bridge-Ops und UserDefaults-Schlüssel bleiben bei `page` (Protokoll-/Persistenzbegriffe, nicht umbenennen). Die gebündelten Kataloge sind der Offline-Pflicht-Fallback; der Server-Override (`GET /content/macclient-i18n.json`, `I18nBundleStore`) ist optional und greift wie das Editor-Bundle erst beim **nächsten** Start. Die aktive Sprache: lokale Wahl (Settings → Allgemein) gewinnt; ohne lokale Wahl seedet `LocalizationController.seedFromServerIfNeeded()` aus dem Server-Profil (`/config` → `userSettings.locale`), sonst Systemsprache. Code-Kommentare auf Deutsch (wie Hauptrepo).
- **Sparkle nur hinter `#if SPARKLE`.** Jeder Zugriff auf `UpdaterController` oder das Sparkle-Modul muss in `#if SPARKLE … #endif` stehen — die Condition setzt ausschließlich das DMG-Target. Ohne Guard bricht der App-Store-Build (s. „Zwei Distributionswege"), und ein Sparkle-Artefakt im Store-Bundle ist ein Ablehnungsgrund. Neue nutzersichtbare Update-UI braucht auch einen `#else`-Zweig, damit der Store-Build keine Lücke zeigt.
- **Info-Plist-Parität (DMG ⇄ App Store).** Die zwei Zusatz-Plists [Config/Info.plist](Config/Info.plist) und [Config/Info-MAS.plist](Config/Info-MAS.plist) dürfen sich **ausschließlich** um die vier `SU*`-Sparkle-Keys unterscheiden. Jeder neue Schlüssel (URL-Schema, Usage-Description, …) gehört im selben Schritt in **beide** Dateien — sonst verliert ein Kanal die Funktion still. Abgesichert durch [DistributionTargetsTests.swift](schreibwerkstatt-focuseditorTests/DistributionTargetsTests.swift); ein bewusst DMG-exklusiver Key wird dort in `sparkleOnlyKeys` eingetragen. Derselbe Test hält auch die Target-Konfiguration fest (MAS ohne Sparkle-Produkt/`SPARKLE`/Entitlements-Datei, gleiche Bundle-ID, geteilte Quell-Gruppe, `Version.xcconfig` projektweit).
- **Nach jeder Swift-Änderung builden.** Nach jeder Anpassung an Swift-Code den Build laufen lassen (s. „Build & Run") und Fehler/Warnings zurückmelden, bevor es weitergeht. Nicht ungeprüft mehrere Änderungen stapeln.
- **Datei-Größe prüfen (Test).** Nach jeder Änderung an Swift-Quelldateien (neue Datei, Datei deutlich gewachsen) den Datei-Größen-Guard [SourceFileSizeTests.swift](schreibwerkstatt-focuseditorTests/SourceFileSizeTests.swift) laufen lassen (s. „Build & Run"). Er hält jede `.swift`-Datei unter **800 Zeilen** (Richtwert/Ziel eher 300–500). Schlägt er an → aufteilen (in Swift meist per `extension` über mehrere Dateien, Vorbild `SyncEngine[+Push/+Pull]`; ein großer String lässt sich als Fragment-Konstanten aufteilen, Vorbild `WebAssets+Glue*.swift`) **oder**, wenn die Größe bewusst gewollt ist, mit Begründung in die `allowedOverLimit`-Allowlist im Test aufnehmen — die ist derzeit **leer** und sollte es bleiben. Neue App-Dateien, die eine getestete Datei als Abhängigkeit braucht, müssen ins Test-Target (explizite Membership im pbxproj, s. [ARCHITECTURE.md](ARCHITECTURE.md) / `xctest`-Hinweis).

## Zwei Distributionswege (DMG + App Store)

Ein Quellcode, zwei Build-Rezepte. Beide Targets teilen dieselbe
`PBXFileSystemSynchronizedRootGroup` — neue Swift-Dateien landen **automatisch**
in beiden, es gibt keine zweite Codebasis und keinen Fork.

| | `schreibwerkstatt-focuseditor` (DMG) | `Focuseditor-MAS` (App Store) |
|---|---|---|
| Sparkle | gelinkt, `SWIFT_ACTIVE_COMPILATION_CONDITIONS` enthält `SPARKLE` | **nicht** gelinkt, kein `SPARKLE` |
| Info.plist | `Config/Info.plist` (mit `SU*`-Keys) | `Config/Info-MAS.plist` (ohne `SU*`) |
| Entitlements | `Config/Focuseditor.entitlements` (mach-lookup-Exception für Sparkles Installer-XPC) | **keine Datei** — Xcode synthetisiert `app-sandbox` + `network.client` + `files.user-selected` aus den `ENABLE_*`-Settings |
| Updates | Sparkle, Appcast als GitHub-„latest"-Asset | App Store |
| Bundle-ID | identisch — Umsteiger behalten Keychain-Token, UserDefaults und den lokalen SQLite-Spiegel |

**Warum getrennt:** Ein eigener Update-Mechanismus ist im App Store verboten, und
`com.apple.security.temporary-exception.mach-lookup.global-name` (von Sparkles
Installer-XPC gebraucht) wird für App-Store-Profile praktisch nicht mehr erteilt —
der Store-Build würde schon an der Validierung scheitern.

**Prüfen, dass der Store-Build sauber ist** (nach Änderungen an Sparkle-Code,
Plists oder der Projektdatei):

```bash
APP=build/mas/Build/Products/Release/Focuseditor.app
codesign -d --entitlements :- "$APP"   # nur app-sandbox / network.client / files.user-selected
ls "$APP/Contents/Frameworks" "$APP/Contents/XPCServices"   # kein Sparkle, kein XPC
plutil -p "$APP/Contents/Info.plist" | grep '"SU'           # leer
```

Diese Checks brauchen ein gebautes Archiv und laufen darum erst beim Release
(automatisch in [scripts/archive-mas.sh](scripts/archive-mas.sh)). **Früher** —
ohne Build, in jedem Testlauf — greift der statische Guard
[DistributionTargetsTests.swift](schreibwerkstatt-focuseditorTests/DistributionTargetsTests.swift):
er liest die zwei Plists und die `project.pbxproj` (OpenStep-Plist, Auflösung
über Target-**Namen**, nicht über UUIDs) und schlägt an, wenn ein Plist-Key nur
in einem Kanal landet, das MAS-Target Sparkle/Entitlements bekommt, die
Bundle-IDs auseinanderlaufen, ein Target die geteilte Quell-Gruppe verliert oder
`Version.xcconfig` nicht mehr projektweit hängt.

**Automatisiert im Arbeitsablauf:** Die Hooks in [.claude/settings.json](.claude/settings.json)
merken sich per [scripts/hooks/mark-changed.sh](scripts/hooks/mark-changed.sh),
was angefasst wurde, und [scripts/hooks/verify-build.sh](scripts/hooks/verify-build.sh)
fährt am Rundenende die Test-Suite — **plus** den Release-Build des Targets
`Focuseditor-MAS`, sobald die Projektdatei, eine Info-Plist, die Entitlements,
`Version.xcconfig`, etwas unter `Update/` oder ein Edit mit Sparkle-Bezug dabei
war. Der Hook-Build nutzt `build/mas-hook` (nicht `build/mas` — das gehört
`archive-mas.sh`; zwei xcodebuild-Läufe auf demselben `derivedDataPath` scheitern
an der gesperrten `build.db`) und überspringt sich per Lock, solange schon eine
Verifikation läuft. Logs: `/tmp/swk-focuseditor-test.log` bzw.
`/tmp/swk-focuseditor-mas.log`.

Der Demo-Zugang (`SWDemoHost`/`SWDemoDeviceToken`) bleibt im Store-Build bewusst
drin: der App-Review braucht einen Ein-Klick-Zugang, weil der normale Login ein
Device-Token per Copy-Paste verlangt.

**Release:** ein Bump für beide Kanäle (dieselbe `Version.xcconfig`), danach
`UPLOAD=1 scripts/archive-mas.sh` für das App-Store-`.pkg`
([scripts/archive-mas.sh](scripts/archive-mas.sh)) bzw. `scripts/release-dmg.sh`
für das DMG. Der Slash-Command `/release` wählt den Kanal
(`appstore` | `dmg` | `beide`, **Default `appstore`**) — Details in
[SIGNING.md](SIGNING.md) „App Store".

**Der App Store ist der Hauptkanal**, das DMG bleibt aber vollwertig: die
Sparkle-Bestandsnutzer wechseln **nicht** von selbst in den Store, ihre
Installation prüft weiter das GitHub-Appcast. Ein Release, das alle erreichen
soll, läuft darum als `/release beide`; ein reines `/release` versorgt nur die
Store-Nutzer. Updates im Store verteilt Apple selbst (Auto-Update-Einstellung des
Nutzers) — die App hat dafür bewusst keinen eigenen Mechanismus, im Store-Build
zeigt der Einstellungen-Tab „Konto" nur die Version + den Hinweis
`settings.account.appUpdateHintStore`. Editor-Änderungen brauchen ohnehin kein
Store-Release (OTA-Bundle).

## Build & Run

- Xcode-Projekt: `schreibwerkstatt-focuseditor.xcodeproj`. **Zwei App-Targets** auf demselben Quellcode (s. „Zwei Distributionswege"): `schreibwerkstatt-focuseditor` (DMG, mit Sparkle) und `Focuseditor-MAS` (App Store, ohne Sparkle).
- **Kein Bundle-Build-Step nötig** — das Editor-Build wird zur Laufzeit per OTA gezogen (s. „Editor-Bundle (OTA)"). Zum Testen muss der Server (Default `localhost:3737`) erreichbar und ein gültiges Device-Token eingeloggt sein.
- Abhängigkeiten: GRDB (SQLite) *(integriert, SPM `groue/GRDB.swift`, `upToNextMajor` ab 7.11.0)*; Sparkle (Auto-Update, **integriert, aber nur im DMG-Target**, SPM `sparkle-project/Sparkle`, `upToNextMajor` ab 2.6.0 — gekapselt in [Update/UpdaterController.swift](schreibwerkstatt-focuseditor/Update/UpdaterController.swift); Appcast via GitHub-„latest"-Release-Asset, Schlüssel/Flow s. [SIGNING.md](SIGNING.md) „Auto-Update (Sparkle)"). ZIP-Entpacken bewusst **ohne** Dependency (`MiniZip.swift` + `Compression`-Framework, sandbox-tauglich).
- **Build-Check nach jeder Swift-Änderung** (Pflicht, s. Harte Regeln):

  ```bash
  xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug build
  ```

  Für kompakte Ausgabe `-quiet` anhängen. Verifiziert lauffähig am 2026-06-14 (`** BUILD SUCCEEDED **`).

  **Beide Targets bauen**, sobald `#if SPARKLE`, die Info.plists oder die Projektdatei betroffen sind — der App-Store-Build fällt sonst unbemerkt aus (eigener `-derivedDataPath`, sonst überschreiben sich die gleichnamigen Produkte):

  ```bash
  xcodebuild -scheme Focuseditor-MAS -configuration Release -derivedDataPath build/mas build -quiet
  ```

  Verifiziert grün am 2026-08-01. Den Store-Build baut der Stop-Hook bei genau diesen Änderungen automatisch mit (s. „Zwei Distributionswege"), der manuelle Aufruf bleibt trotzdem gültig.
- **Distributions-Guard (statisch, kein Build):**

  ```bash
  xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug test \
    -only-testing:schreibwerkstatt-focuseditorTests/DistributionTargetsTests
  ```

  Plist-Parität + Target-Konfiguration der zwei Kanäle (s. Harte Regeln „Info-Plist-Parität"). Verifiziert grün am 2026-08-03 (7 Tests).
- **Datei-Größen-Guard (Pflicht bei Source-Änderungen, s. Harte Regeln):**

  ```bash
  xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug test \
    -only-testing:schreibwerkstatt-focuseditorTests/SourceFileSizeTests
  ```

  Prüft, dass keine `.swift`-Datei das 800-Zeilen-Limit überschreitet (Allowlist im Test). Die ganze Suite läuft mit `test` ohne `-only-testing`. Verifiziert grün am 2026-10-04 (284 Tests; die 5 `SyncIntegrationTests` brauchen einen laufenden Dev-Server auf `localhost:3737` und schlagen ohne ihn fehl — alle 279 offline-Tests grün).
- **JS-Syntax-Guard:** [WebAssetsSyntaxTests.swift](schreibwerkstatt-focuseditorTests/WebAssetsSyntaxTests.swift) schneidet die `<script>`-Blöcke aus dem generierten `index.html` (plus Bridge-Facade und Dev-Harness) und lässt `node --check` darüberlaufen. Der Glue ist über 1000 Zeilen JavaScript in Swift-String-Literalen, die der Compiler als Text durchwinkt — ein fehlendes `}` fiel bisher erst zur Laufzeit in der WKWebView auf, und dort still. Fehlt `node`, überspringt sich der Test (Entwickler-Bequemlichkeit, kein Release-Gate).
- **i18n-Guard:** [LocalizationCatalogTests.swift](schreibwerkstatt-focuseditorTests/LocalizationCatalogTests.swift) hält die zwei Kataloge deckungsgleich (gleiche Keys, gleiche `{param}`-Platzhalter je Key), prüft jeden literalen `t("…")`-Key im Code gegen den Katalog und verlangt zu jedem `tn(…)`/`NumberText.plural(…)` beide Plural-Formen. Ein einseitig gepflegter Key fiel sonst nur auf, wenn man die App in der Sprache benutzte (die Fallback-Kette liefert still den deutschen Text).

  **Test-Target-Mitgliedschaft:** Das Bundle ist non-hosted (kein `@testable import`, s. [ARCHITECTURE.md](ARCHITECTURE.md)) — getestete App-Quellen sind explizit im pbxproj eingetragen. Aktuell zusätzlich zu den Sync-/Auth-/Web-Dateien: `WritingTimeTracker.swift`, `LibraryStore.swift`, `GRDBLocalStore.swift` (dafür hängt auch das **GRDB**-Paketprodukt am Test-Target), `PagePickerModel.swift`, `WebAssets+DevHarness.swift`, `DiagnosticsReport.swift`, `EditorBundleStore.swift`, `LektoratJobStore.swift`, `AccountDeletionController.swift`. Eine neue getestete Datei braucht denselben Eintrag, sonst fehlt sie im Test-Build.

**Netz-Pfade testen:** `MockURLProtocol` (in [APIClientTests.swift](schreibwerkstatt-focuseditorTests/APIClientTests.swift)) fängt alle Requests einer Test-Session ab — der `APIClient` nimmt die Session im Initializer entgegen. So laufen `EditorBundleStore` (OTA-Fehlerpfade), `LektoratJobStore` (Poll-Zyklus) und `AccountDeletionController` ohne Server. Damit das geht, sind drei Dinge injizierbar, die sonst hart verdrahtet wären: `EditorBundleStore(baseDirectory:)` (statt Application Support), `LektoratJobStore(pollInterval:maxPolls:)` (sonst liefe eine Timeout-Probe echte sechs Minuten) und `LektoratJobStore(prepare:)`. ZIP-Eingaben baut [ZipFixture.swift](schreibwerkstatt-focuseditorTests/ZipFixture.swift) von Hand (geteilt mit `MiniZipTests`) — eine fremde ZIP-Bibliothek würde die Annahme umgehen, die `MiniZip` prüfen soll.
