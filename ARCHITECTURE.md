# Architektur — schreibwerkstatt-focuseditor

Implementierungs-Referenz des macOS-Clients: **welche Typen es gibt, wer wen besitzt, wie die Daten fliessen.** Ergänzt [CLAUDE.md](CLAUDE.md) (Zweck, Verträge, harte Regeln) um die konkrete Code-Struktur. Beschreibt den Ist-Zustand des Codes, nicht den Soll-Plan.

> Querverweise auf den Bridge-Vertrag, die Server-Endpoints und die Sync-Semantik stehen in [CLAUDE.md](CLAUDE.md) — hier wird nicht wiederholt, *was* die Verträge sagen, sondern *wie* der Swift-Code sie umsetzt.

---

## 1. Überblick: drei Welten

```
┌─────────────────────────── macOS-App (Swift, @MainActor) ───────────────────────────┐
│                                                                                       │
│  SwiftUI/AppKit-Shell ── EnvironmentObjects ──┐                                       │
│       (App, ContentView, Toolbar, Settings)   │                                       │
│                                               ▼                                       │
│                                          ┌─────────┐                                  │
│                                          │ AppCore │  app-weiter Singleton-Container   │
│                                          └────┬────┘                                  │
│          ┌───────────────┬──────────────┬────┴──────┬──────────────┬──────────────┐  │
│          ▼               ▼              ▼            ▼              ▼              ▼  │
│     AuthStore      EditorBridge    LocalStore   SyncEngine     ContentAPI   EditorBundle│
│     (Keychain)    (JS⇄Swift, EINE  (GRDB/SQLite)(Poll+Push    (Buch-/Seiten- Store     │
│          │         Kopplungsschicht)     │       +Pull+Merge)  Struktur)    (OTA-Lader)│
│          │               │              │            │              │            │     │
│          └───────────────┴──────────────┴── APIClient ────────────┴────────────┘     │
│                                              (Bearer swd_…)                            │
└──────────────────────────────────────────────┬───────────────────────────────────────┘
                                                │ HTTPS
                          ┌─────────────────────┴───────────────────────┐
                          ▼                                             ▼
                  WKWebView (swk-app://)                      schreibwerkstatt-Server
                  lädt NUR lokalen Cache                      (Express, :3737 / NGINX)
```

Drei strikt getrennte Welten:

1. **SwiftUI/AppKit-Shell** — Fenster, Toolbar, Picker, Settings, Vollbild. Kennt keinen Server, keinen WebView-Inhalt; spricht nur mit den Kern-Objekten über `@EnvironmentObject`.
2. **Swift-Kern** — die einzigen Objekte, die Netzwerk machen (`APIClient`) und Zustand halten (`LocalStore`, `SyncEngine`, `AuthStore`). Instanziiert in `AppCore`.
3. **WebView** — lädt **ausschliesslich** den lokalen OTA-Cache über das Custom-Scheme `swk-app://`. Jeder Server-Kontakt läuft durch den Swift-Kern, nie durch die WebView (harte Regel, [CLAUDE.md](CLAUDE.md)).

Die **EditorBridge** ist die einzige Naht zwischen WebView und Swift-Kern.

---

## 2. Komposition: AppCore als Wurzel

[AppCore.swift](schreibwerkstatt-focuseditor/AppCore.swift) — `@MainActor final class AppCore: ObservableObject` — ist der app-weite Container. Die Instanziierungsreihenfolge ist bewusst (jede Zeile hängt von der vorigen ab):

| Reihenfolge | Objekt | Abhängt von | Zweck |
|---|---|---|---|
| 1 | `AuthStore` | — | Auth-State, Token, vorkonfigurierter `APIClient` |
| 2 | `LocalStore` | — | `GRDBLocalStore` bevorzugt, In-Memory-Fallback bei Öffnungsfehler |
| 3 | `EditorBridge` | store, auth.api | einzige WebView⇄Swift-Kopplung |
| 4 | `ContentAPI` | auth.api | Lesezugriff auf Buch-/Kapitel-/Seiten-Struktur |
| 5 | `LibraryStore` | content, store, bridge | Buch-/Seitenauswahl-State |
| 6 | `EditorBundleStore` | auth.api | OTA-Bundle-Download/Cache |
| 7 | `SyncEngine` | auth.api, content, store | Poll/Push/Pull; danach `sync.editor = bridge` (Rückkopplung) |
| 8 | `BookExportController` | auth.api, store, library | Buch als Markdown sichern (Server-Export `GET /export/book/:id/md`, online-only; Vorlauf Flush + Sync) |
| 9 | `PageAdminController` | auth.api, store, library | Seiten anlegen/umbenennen/löschen (online, `POST`/`PUT`/`DELETE /content/pages`) |
| 10 | `PageRevisionStore` | auth.api | frühere Fassungen der offenen Seite (Liste/Vorschau/Restore) |

**Schlüsselentscheidung:** `LocalStore` und `EditorBridge` sind **app-weit, nicht pro Fenster**. So sehen `SyncEngine` (schreibt Server-Deltas) und die WebView-Bridge (schreibt User-Edits) **denselben** Spiegel. `sync.editor = bridge` verdrahtet die zwei nachträglich, weil beide vorher existieren müssen.

`bootstrap()` macht zwei Dinge: `await auth.bootstrap()` (Token aus Keychain validieren) und `sync.start()` (Poll-Loop).

Der **Umbau im laufenden Betrieb** (Server-Namespace wechseln, lokale Daten nach Konto-Löschung verwerfen) liegt getrennt in [AppCore+ServerSwitch.swift](schreibwerkstatt-focuseditor/AppCore+ServerSwitch.swift) — eigenes Thema mit eigener Reihenfolge-Empfindlichkeit (Sync anhalten VOR dem Store-Tausch; aufräumen VOR dem Abmelden), das sich in derselben Datei wie der Aufbau wie dessen Fortsetzung las.

### App-Einstieg & Scene-Graph

[schreibwerkstatt_focuseditorApp.swift](schreibwerkstatt-focuseditor/schreibwerkstatt_focuseditorApp.swift) — `@main`. Hält 6 `@StateObject` (`core` + 5 Controller) und injiziert sie als `EnvironmentObject` in drei Scenes:

- **WindowGroup** → `ContentView` (Hauptfenster)
- **Window** `"shortcuts-help"` → `ShortcutsHelpView` (⌘?)
- **Settings** → `SettingsView` (⌘,)

Der `.task`-Block verdrahtet die Controller an die Bridge (`focus.bind`, `typography.bind`, `writingStats.attach`), ruft `core.bootstrap()` und zieht nach Login den Server-Default für die Fokus-Stufe (`.onReceive(core.auth.$state)`). `.onChange(of: scenePhase)` reicht den aktiven Zustand an `sync.setActive(_:)` (Polling nur im Vordergrund).

---

## 3. Web-Schicht: WebView, Bridge, OTA-Bundle

Alle Dateien unter [Web/](schreibwerkstatt-focuseditor/Web/).

### EditorBridge — die einzige Kopplungsschicht

`@MainActor final class EditorBridge: NSObject, WKScriptMessageHandlerWithReply, EditorCoordinating` — auf sechs Dateien verteilt (eine Datei = eine Verantwortung, Vorbild `SyncEngine[+Push/+Pull]`):

| Datei | Inhalt |
|---|---|
| [EditorBridge.swift](schreibwerkstatt-focuseditor/Web/EditorBridge.swift) | Kern: Abhängigkeiten, Zustand/Callbacks, Message-Handler, Dirty-Tracking, `BridgeError` |
| [EditorBridge+Ops.swift](schreibwerkstatt-focuseditor/Web/EditorBridge+Ops.swift) | `route(op:params:)` + alle Ops (JS → Swift) + `fetchAndMirror` |
| [EditorBridge+Events.swift](schreibwerkstatt-focuseditor/Web/EditorBridge+Events.swift) | Swift → JS: `evaluateJS`/`callJS`/`emit`, Events, `flushDraftSave`, `merge3` |
| [EditorBridge+Params.swift](schreibwerkstatt-focuseditor/Web/EditorBridge+Params.swift) | Validierung der WebView-Parameter + Grenzwerte + `encode(_ page:)` |
| [EditorBridge+Recents.swift](schreibwerkstatt-focuseditor/Web/EditorBridge+Recents.swift) | gerätelokale Merker: zuletzt geöffnete Seite, MRU-Historie, aktives Buch |
| [EditorBridge+Proxies.swift](schreibwerkstatt-focuseditor/Web/EditorBridge+Proxies.swift) | Server-Proxys (LanguageTool, Wörterbuch, Synonyme) + lokale Prefs |

**JS → Swift** (über `WKScriptMessageHandlerWithReply`, Dispatch in `route(op:params:)`). Implementierte Ops: `load`, `save`, `list`, `activeBook`, `lastOpenPage`, `editorState`, `log`, `focusGranularity`, `editorTypography`, `editorBehavior`, `reportStats`, `spellcheckConfig`, `languagetoolCheck`, `dictionaryAdd`, `synonymConfig`, `synonymsThesaurus`, `synonymsAi`. (Vertrag + Payloads: [CLAUDE.md](CLAUDE.md) „Bridge-Vertrag".)

- `load` ist **local-first**: erst Store, dann Online-Fallback (`fetchAndMirror`).
- `editorState` pflegt über `applyEditorState(pageId:dirty:)` die `openPageId` (triggert `onOpenPageChange`/`onPageOpened`) und den Dirty-Zustand — der Editor hält genau eine Seite offen, also enthält `dirtyPages` höchstens sie.
- `languagetoolCheck`/`dictionaryAdd` proxyen über `APIClient`; lokale `SpellcheckPrefs` (UserDefaults) können vor dem Roundtrip abkürzen.
- `console.log/info/warn/error` werden in der Facade abgefangen und über `log` ins OS-Log gespiegelt (einzeilig + gekürzt).

**Swift → JS** (über `callAsyncJavaScript` in `contentWorld: .page`, Ziel `window.__focusBridge._receive`): `openPage`, `closePage`, `focusGranularity`, `editorTypography`, `format`, `normalizeQuotes`, `synonyms`. Plus die awaitbaren Direktaufrufe `reloadPage(…, force:) -> Bool` (`_serverUpdate`, der stille Server-Refresh — mit Antwort, weil Swift bei Ablehnung die Sync-Basis zurückdreht), `flushDraftSave()` (⌘S-Vorlauf) und `merge3(base:local:server:)`, das `window.__focusBridge._merge3(...)` aufruft (lädt `block-merge.js` dynamisch) und `MergeOutcome { merged, conflictCount }` zurückgibt.

**Härtung** (die WebView ist eine nicht vertrauenswürdige Quelle — sie führt fremden Editor-Code aus dem OTA-Bundle aus):

1. Der Message-Handler nimmt nur den eigenen Kanal, den **Haupt-Frame** und eine **lokale Origin** an (`http(s)`/`ws`/`ftp` werden abgewiesen).
2. Jeder Parameter läuft durch `+Params` — Pflichtfelder werfen, optionale degradieren still zu `nil`; Längen-Deckel (HTML/Prüftext/Wort/Log), Zahlen-Klemmen (kein NaN/±∞/negativ in Store, Sync-Basis oder Statistik), Seiten-IDs nur ohne Steuerzeichen/Pfadtrenner/`..` (sie landen in URL-Pfaden, Defaults-Keys, Logs).
3. **Kein Swift→JS-Aufruf ohne Timeout** (`jsCallTimeout` 5 s, Merge 8 s): ein hängendes JS darf den awaitenden Swift-Pfad (⌘S-Flush, Lektorats-Vorlauf, 409-Merge) nicht einfrieren.
4. Event-Skripte nutzen Optional-Chaining (nicht gebootete Seite = stilles No-op) und `emit` filtert `nil`-Felder heraus (`callAsyncJavaScript` akzeptiert nur JSON-Werte).

**Callbacks nach aussen:** `onOpenPageChange`/`onPageOpened` (→ `LibraryStore`/`SyncEngine`), `onOpenDirtyChange` (Save-Indikator), `onStats` (→ `WritingStatsStore`), `onActivity` (→ `WritingTimeTracker`), `onSaveResult` (Save-Fehler-Banner). Lese-Properties für den Boot-Pull: `focusGranularity`, `typography` (gesetzt von den Controllern).

### EditorCoordinating — Entkopplung Sync ⇄ WebView

[EditorCoordinating.swift](schreibwerkstatt-focuseditor/Web/EditorCoordinating.swift) — Protokoll mit `openPageId`, `isDirty(_:)`, `reloadPage(...)`, `merge3(...)`. Die `SyncEngine` kennt die WebView **nur** über dieses Protokoll — sie weiss nichts von `WKWebView`. Das macht den Datenverlust-Schutz (offene/dirty Seite nicht überschreiben) und den 3-Wege-Merge testbar und entkoppelt.

### FocusWebView — der WKWebView-Host

[FocusWebView.swift](schreibwerkstatt-focuseditor/Web/FocusWebView.swift) — `NSViewRepresentable`. In `makeNSView`:

1. Injiziert `WebAssets.bridgeFacadeJS` at-document-start.
2. Registriert `bridge` als Script-Message-Handler.
3. Registriert `AppSchemeHandler` für `swk-app://` (nur wenn ein Bundle vorhanden ist).
4. Macht den WebView transparent (private KVC `setDrawsBackground:false`, abgesichert per `responds(to:)` → degradiert still), damit `BrandColor` durchscheint.
5. Lädt `swk-app://local/index.html` — oder, ohne Bundle, `WebAssets.devHarnessHTML` als Diagnose-Seite.

Die Navigation-Policy erlaubt **nur** `swk-app:`, `file:`, `about:` und schemenlose URLs; `http(s)`/`mailto` werden `.cancel`'t (kein versehentliches Laden von Server-URLs).

### AppSchemeHandler — eine Origin für ES-Module

[AppSchemeHandler.swift](schreibwerkstatt-focuseditor/Web/AppSchemeHandler.swift) — `WKURLSchemeHandler`. Liefert den Cache unter **einer** Origin `swk-app://local`. Grund: `file://` gibt jeder Datei eine eigene opake Origin, woran ES-Modul-`import` als CORS scheitert. Path-Traversal-Schutz über `standardizedFileURL` + `hasPrefix(webRoot)`. Setzt korrekte MIME-Types (`.js` → `text/javascript`, sonst ES-Module brechen) und `Cache-Control: no-cache`.

### EditorBundleStore + MiniZip — OTA

[EditorBundleStore.swift](schreibwerkstatt-focuseditor/Web/EditorBundleStore.swift) — `ObservableObject`, `@Published var state: BundleState` (`.idle/.refreshing/.ready/.failed`).

- `ensureReady()`: mit Cache → sofort `.ready` + stiller Hintergrund-Refresh; ohne Cache → blockierender Erst-Download.
- `refresh(silent:)`: `api.getRaw(...)` mit `If-None-Match`-ETag → **304** (`regenerateIndexHTMLFromCache`) oder neues ZIP (`installBundle`).
- `installBundle`: entpackt via `MiniZip.entries`, schreibt in ein Staging-Verzeichnis (`web-cache.staging-<UUID>`, mit Path-Traversal-Guard), generiert `index.html` aus `WebAssets.indexHTML(cssFiles:sourceCommit:)` + Manifest, dann **atomarer Swap** über `FileManager.replaceItemAt`.
- Refresh greift bewusst erst beim **nächsten** Start (kein Hot-Swap mitten im Schreiben).

Cache-Ort: `~/Library/Application Support/schreibwerkstatt-focuseditor/web-cache/` + `web-cache.meta.json` (ETag + sourceCommit).

[MiniZip.swift](schreibwerkstatt-focuseditor/Web/MiniZip.swift) — `enum MiniZip`, bordeigener ZIP-Reader (~160 LoC, **keine SPM-Dependency**, sandbox-tauglich). Parst EOCD → Central Directory → Local File Headers; DEFLATE über Apples `Compression`-Framework (`compression_decode_buffer`, `COMPRESSION_ZLIB`). Lehnt ZIP64 ab.

### WebAssets — Bridge-Facade + Boot-Glue

[WebAssets.swift](schreibwerkstatt-focuseditor/Web/WebAssets.swift) — drei In-Source-Strings:

- **`bridgeFacadeJS`**: definiert `window.__focusBridge` (Methoden + Event-Bus `on`/`_receive` + `_merge3` + console-Forwarding). At-document-start injiziert.
- **`indexHTML(cssFiles:sourceCommit:)`**: Client-Glue, das `EditorBundleStore` in den Cache schreibt. Enthält die FOUC-sichere `prefers-color-scheme → data-theme`-Brücke, mountet `focus/standalone.js` über einen Bridge-Adapter, abonniert die Swift→JS-Events, betreibt die debounced Live-Wortzählung (`reportStats`) und verdrahtet den (unveränderten) Spellcheck-Controller über injizierte `checkText`/`addWord`-Callbacks.
- **`devHarnessHTML`**: eigenständige Diagnose-Seite, wenn noch kein Bundle da ist.

---

## 4. Store-Schicht: lokaler Spiegel + Outbox

[Store/LocalStore.swift](schreibwerkstatt-focuseditor/Store/LocalStore.swift) definiert das `@MainActor protocol LocalStore` und die Modelle:

- `StoredPage` — `id, html, title?, pageName?, bookId?, chapterId?, updatedAt (Epoch-ms), baseUpdatedAt? (Server-Basis als ms)`.
- `OutboxEntry` — `pageId, html, baseUpdatedAt?, queuedAt`.
- `PageSummary` — leichte Listenzeile (ohne HTML); `displayName` bevorzugt `pageName` über `title`.
- `PageStats` / `PageMetrics` ([Store/PageMetrics.swift](schreibwerkstatt-focuseditor/Store/PageMetrics.swift)) — Zeichen-/Wortzahl einer Seite, aus dem HTML gescannt (ein Durchgang über die Unicode-Skalare, kein Regex). Spiegelt bewusst die Editor-Zählung in der WebView (`countAndReport`, Leerraum-Läufe kollabieren, Blocktags = eine Zeilengrenze), damit Picker und Toolbar für die offene Seite dieselbe Zahl zeigen. `chars == 0` heisst verlässlich „unbeschrieben" (auch beim leeren Editor-Absatz `<p><br></p>`) — daran hängt das „leer"-Badge im Picker.

Protokoll-Methoden mit ihrer Semantik:

| Methode | Semantik |
|---|---|
| `page(id:)` | eine Seite voll laden |
| `list(bookId:)` | `PageSummary[]`, ohne HTML, neueste zuerst |
| `pageStats(bookId:)` | `[pageId: PageStats]` für den Picker — nur Seiten, deren Inhalt lokal vorliegt (fehlende zeigt der Picker als „—", nicht als 0) |
| `save(id:html:baseUpdatedAt:)` | **local-first**: upsert Seite **+ Outbox-Eintrag** |
| `pendingOutbox()` | offene Pushes, älteste zuerst |
| `markPushed(id:queuedAt:serverUpdatedAtMillis:)` | quittiert Push — droppt Outbox-Eintrag **nur wenn `queuedAt` unverändert** (sonst liegt eine neuere Edit vor) |
| `applyServerPage(...)` | Pull-Merge: setzt `updatedAt` **und** `baseUpdatedAt` auf Server-Stand, **kein** Outbox-Eintrag |
| `deletePage(id:)` | räumt Seite + Outbox |

Zwei Implementierungen:

- [GRDBLocalStore.swift](schreibwerkstatt-focuseditor/Store/GRDBLocalStore.swift) — produktiv, SQLite via GRDB. Migration `v1_pages_outbox`: Tabellen `page` (PK `id TEXT`) + `outbox` (PK `pageId TEXT`) + Index `page_on_bookId`. DB unter `…/localstore.sqlite`. Reads auf der Lese-Queue, Writes in `dbQueue.write {}`. Abgeleitete Werte (FTS-Eintrag + Zählwerte `charCount`/`wordCount`, Migration `v5_page_counts`) pflegt `upsertDerived` in DERSELBEN Transaktion wie den Seiten-Write; Alt-Bestand mit `charCount IS NULL` trägt `backfillPageStatsIfNeeded` beim Öffnen in 200er-Häppchen nach. Gerechnet wird also beim Schreiben — der Picker liest nur Zahlen, nie HTML.
- `InMemoryLocalStore` (in `LocalStore.swift`) — Fallback/Test, JSON-Snapshot, verhaltensgleich.

> GRDB-Records sind `nonisolated` deklariert (MainActor-Default-Isolation des Projekts erzwingt das für Typ **und** Conformance) — siehe Memory `grdb-nonisolated-conformance`.

---

## 5. Sync-Schicht: Poll, Push, Pull, Merge

Alle Dateien unter [Sync/](schreibwerkstatt-focuseditor/Sync/). Kern ist die `@MainActor final class SyncEngine`, aus Lesbarkeitsgründen über vier Dateien gesplittet (ein Typ, `extension`-Aufteilung, kein Verhaltensunterschied): [SyncEngine.swift](schreibwerkstatt-focuseditor/Sync/SyncEngine.swift) (Typen · State · Lifecycle · Durchlauf `syncNow` · Generation-Token beim Server-Wechsel), [SyncEngine+Push.swift](schreibwerkstatt-focuseditor/Sync/SyncEngine+Push.swift) (`pushOutbox` · Auto-Merge · Basis-Reparatur), [SyncEngine+Pull.swift](schreibwerkstatt-focuseditor/Sync/SyncEngine+Pull.swift) (Pull · Delete-Reconcile · Reload der offenen Seite mit Basis-Rückdrehung) und [SyncEngine+Conflicts.swift](schreibwerkstatt-focuseditor/Sync/SyncEngine+Conflicts.swift) (manuelle Konflikt-Auflösung · Übernahme nach Revision-Restore; im Test-Target explizit eingetragen). Weil `private` in Swift dateiweit ist, sind die von den Extensions geteilten Member `internal` statt `private` (Single-Module — nichts außerhalb referenziert `SyncEngine`).

### Poll-Loop

Getrieben von Scene-Phase (`setActive(_:)`) + Reachability:

- `setActive(true)` → sofortiger `requestSync()` + `startPolling()`. Hintergrund → `stopPolling()`.
- `startPolling()` läuft `Task.sleep(for: interval)` in Schleife; `interval` aus `pollMode` ([SyncPreferences.swift](schreibwerkstatt-focuseditor/Sync/SyncPreferences.swift): `.active` ~5 s / `.relaxed` ~30 s / `.manual` = nil).
- [Reachability.swift](schreibwerkstatt-focuseditor/Sync/Reachability.swift) (`NWPathMonitor`) → bei Online-Übergang sofort ein Tick.
- `isRunning` verhindert parallele Ticks; `isPaused` (transient) und `pollMode` (persistiert) steuern UI/Verhalten.

Ein Tick macht Push, dann Pull, dann gedrosselt Delete-Reconcile (`reconcileInterval = 60 s`).

### Push — `PUT /content/pages/:id`

`pushOutbox()` iteriert die Outbox. Pro Eintrag:

- Überspringt unaufgelöste Konflikte und Seiten **ohne Server-Basis** (PUT legt nicht an — neue Seiten via `POST`, nicht hier).
- Sendet `PushRequest { html, expected_updated_at, source:"macapp" }`. `expected_updated_at` ist der **exakte Server-ISO-String** aus `SyncState.serverBaseISO` (nie aus Epoch-ms rekonstruiert).
- **200** → Basis auf `resp.updated_at` vorrücken, `markPushed`. **409** → `resolveConflict`. **423** → überspringen (gesperrt). **404** → Basis verwerfen, Inhalt lokal behalten. **401** → ganzen Sync abbrechen.

### 409 → 3-Wege-Block-Merge

`resolveConflict` holt frisches Server-HTML (`GET /content/pages/:id`) und ruft `editor.merge3(base:local:server:)` (in der WebView, `block-merge.js`):

- `base` = Merge-Ancestor aus dem LocalStore (`store.serverBaseHtml(id:)`, Spalte `page.serverBaseHtml`), `local` = Outbox-HTML, `server` = frisch geholt.
- `conflictCount == 0` → gemergtes HTML mit neuer Basis erneut pushen (still), Store mergen, offene Seite reloaden.
- `conflictCount > 0` → echter Konflikt: `recordConflict(...)` (→ `@Published conflicts`). Die Toolbar (`SyncStatusLabel`) zeigt sie und öffnet pro Seite die **`ConflictResolutionView`** ([Conflict/](schreibwerkstatt-focuseditor/Conflict/)): ein Sheet, das lokalen + frischen Server-Stand (`SyncEngine.conflictContents`) **nebeneinander** mit absatzweisem Diff (`ConflictDiff`, pure `CollectionDifference`) zeigt — informierte Wahl „mein Stand"/„Server-Stand" statt blindem Dropdown. Die Auflösung selbst macht weiter `resolveConflict(pageId:keepLocal:)`.
- Netzfehler beim Merge-Fetch setzt **keinen** klebrigen Konflikt — Eintrag bleibt in der Outbox, nächster Tick versucht erneut.

### Pull — `GET /content/books/:id/sync`

`pullDeltas` → Bücherliste (`GET /content/books`) → `pullBook(_:)` je Buch mit Keyset-Cursor (`since` + `since_id`, `limit=200`), paginiert bis `has_more == false`. Pro eingehender Seite:

- **Lokale Änderung offen** (pending Outbox **oder** `editor.isDirty`) → überspringen (Datenverlust-Schutz), Cursor trotzdem vorrücken.
- **Keine Server-Basis** (`updated_at == nil`) → überspringen.
- **Echo des eigenen Edits** (`serverBaseISO[pid] == updated_at`) → nicht neu mergen/reloaden (Flacker-Schutz), nur Cursor vorrücken.
- Sonst → `applyServerPage(...)`; ist es die offene saubere Seite → `editor.reloadPage(...)`.

Cursor-Stagnation und leere Antworten brechen die Schleife (Endlos-Schutz).

### Delete-Reconcile

`/sync` meldet keine Löschungen. `reconcileDeletesIfDue` (≤1×/60 s) vergleicht Server-Soll (`content.pickerRows` aus dem Tree) gegen lokales Ist (`store.list`). Seiten im Ist, nicht im Soll, werden gelöscht — **ausser** sie sind in der Outbox oder dirty. Ein **leerer** Server-Tree löst **nichts** aus (verdächtig → könnte transienter 200 sein).

### SyncState — persistente Koordinaten

[SyncState.swift](schreibwerkstatt-focuseditor/Sync/SyncState.swift): `bookIds`, `cursors[bookId]`, `serverBaseISO[pageId]` (exakter ISO-String für `expected_updated_at`). JSON-Snapshot in Application Support, geschrieben auf einer `ioQueue` (blockiert MainActor nicht). Decoder ist tolerant gegen fehlende Keys (Rückwärtskompatibilität).

**Kein HTML im Snapshot.** `mutate` kodiert immer den GANZEN Snapshot neu, und der Pull schreibt pro Buch pro Tick den (oft unveränderten) Cursor zurück. Solange der Merge-Ancestor hier als `serverBaseHtml[pageId]` lag, hiess das: 3096 Seiten × volles HTML = 20 MB, alle ~5 s neu kodiert und geschrieben (~50 % CPU-Spitzen, ~4 MB/s SSD-Dauerlast — messbar als zähes Tippen). Der Ancestor lebt darum als Spalte `page.serverBaseHtml` im LocalStore (Row-Update statt Voll-Rewrite); `legacyServerBaseHtml` liest Alt-Snapshots nur noch ein, `encode(to:)` schreibt es nie zurück, und `SyncEngine.migrateLegacyAncestors()` zieht die Werte einmalig um. Zusätzlich schreibt `persist()` nur bei echter Änderung (`SyncState: Equatable`) — der No-op-Tick löst keinen Write mehr aus. Gemessen danach: 115 KB Snapshot, 0,3 % CPU im Leerlauf. **Regel: nichts Inhaltsgrosses in den `SyncState` legen** — Seiten-Inhalte gehören in den LocalStore.

[SyncModels.swift](schreibwerkstatt-focuseditor/Sync/SyncModels.swift): DTOs (`BookDTO`, `SyncPageDTO`, `SyncCursorDTO`, `BookSyncResponse`, `PushRequest/Response`, `ConflictBody`) + `ISOTime` (ISO↔Epoch-ms, tolerant gegen Millis/plain).

---

## 6. Auth-Schicht: Device-Token + Keychain

Alle Dateien unter [Auth/](schreibwerkstatt-focuseditor/Auth/).

- [AuthStore.swift](schreibwerkstatt-focuseditor/Auth/AuthStore.swift) — `@MainActor`, State `.unknown/.signedOut/.validating/.signedIn`. `bootstrap()` validiert ein vorhandenes Token gegen `GET /me/device-tokens` (funktioniert mit Device-Token; nur das Ausstellen ist serverseitig gesperrt). Offline-Fehler → optimistisch `.signedIn` (Inhalte nie verwerfen). `signIn(...)` normalisiert URL + Token, probt, speichert ins Keychain. 401 zur Laufzeit → `handleUnauthorized` (Token löschen, Re-Login).
- [APIClient.swift](schreibwerkstatt-focuseditor/Auth/APIClient.swift) — HTTP-Client. Setzt `Authorization: Bearer swd_…` aus dem `tokenProvider` (Keychain) auf jeden Request. `send`/`sendVoid` (JSON), `postExpectingJSON` (4xx fachlich durchreichen — z.B. LanguageTool-404), `getRaw` (Binär/ZIP, behandelt **304 nicht als Fehler**). 401 → `onUnauthorized`-Callback + `AuthError.unauthorized`. Timeout 30 s, `waitsForConnectivity = false`.
- [Keychain.swift](schreibwerkstatt-focuseditor/Auth/Keychain.swift) — `SecItem`-Wrapper, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (nicht in Backups/iCloud). Token **nur** hier, nie in UserDefaults/Logs/Bridge.
- [DeviceToken.swift](schreibwerkstatt-focuseditor/Auth/DeviceToken.swift) — Format `swd_` + 64 Hex (lowercase), `isValidFormat`/`normalize` (trimmt Copy-Paste-Reste). DTOs der Token-Liste (ohne Klartext).
- [ServerConfig.swift](schreibwerkstatt-focuseditor/Auth/ServerConfig.swift) — Base-URL in UserDefaults (`server.baseURL`), Default `http://127.0.0.1:3737` (IPv4-Zwang, da Dev-Server nur IPv4 bindet). `normalizedURL` trimmt, prüft Schema/Host, erzwingt IPv4 für `localhost`.
- [AuthError.swift](schreibwerkstatt-focuseditor/Auth/AuthError.swift) — `LocalizedError` mit deutschen Texten (`.malformedToken/.unauthorized/.invalidServerURL/.network/.server/.decoding`).
- [LoginView.swift](schreibwerkstatt-focuseditor/Auth/LoginView.swift) — Card-UI: Server-URL + Token-`SecureField` → `auth.signIn(...)`.
- [AccountDeletionController.swift](schreibwerkstatt-focuseditor/Auth/AccountDeletionController.swift) — `@MainActor ObservableObject`, Phasen `.idle/.deleting/.done(purgeAt:)/.unsupported/.failed`. `DELETE /me/account` mit `{ confirm: "DELETE" }` über `APIClient.sendExpectingJSON` (Status selbst deuten: `404` **ohne** `error_code` = Route fehlt → `.unsupported` → Browser-Fallback). Nur bei `2xx` läuft `onDeleted` — in `AppCore` verdrahtet auf `purgeLocalDataForCurrentServer()` (→ [Store/LocalDataPurge.swift](schreibwerkstatt-focuseditor/Store/LocalDataPurge.swift): Namespace-Ordner + `…​.<slug>`-Defaults weg, frische DB, Sync/Library neu) **und danach** `auth.signOut()`. UI: [Settings/AccountDeletionSection.swift](schreibwerkstatt-focuseditor/Settings/AccountDeletionSection.swift) (Tipp-Bestätigung im Sheet).

---

## 7. Content-API: Buch-/Seitenstruktur

[Content/ContentAPI.swift](schreibwerkstatt-focuseditor/Content/ContentAPI.swift) — Lesezugriff auf die Server-Struktur (Soll-Bestand), getrennt vom Sync-Inhalts-Pfad. `books()` (`GET /content/books`), `tree(bookId:)` (`GET /content/books/:id/tree`), `pickerRows(bookId:)` = `tree` + `flatten`. Die DTOs (`TreeChapterDTO`, `BookTreeDTO`, …) dekodieren defensiv (`?? []`). `flatten` ist eine pure, depth-first-Funktion → `PagePickerRow { id, name, chapterName?, depth }` für Picker und Delete-Reconcile.

---

## 8. Library: Buch-/Seitenauswahl

[Library/LibraryStore.swift](schreibwerkstatt-focuseditor/Library/LibraryStore.swift) — `@MainActor ObservableObject`. Hält `books`, `activeBookId` (persistiert), `pages` (des aktiven Buchs), `openPageId`. Empfängt die offene Seite über `bridge.onOpenPageChange`. `refreshPages` ist **offline-first**: erst Server-`pickerRows`, bei Fehler lokaler Fallback aus `store.list`. `openPage(id:)` setzt sofort `openPageId` (Toolbar) und ruft `bridge.openPage(...)`.

- [Library/BookPicker.swift](schreibwerkstatt-focuseditor/Library/BookPicker.swift) — minimales `Menu` in der Toolbar (Buchwechsel ist selten).
- [Library/PagePickerOverlay.swift](schreibwerkstatt-focuseditor/Library/PagePickerOverlay.swift) — modales Such-Overlay (⌘O): TextField + gefilterte Liste, Tastatur-Navigation (↑/↓/⏎ via `NSEvent`-Monitor), ⎋ schliesst. Pro Zeile zusätzlich der Umfang (`pickerMetric`: Zeichen/Wörter/beides/aus, `@AppStorage "picker.metric"`), ein „leer"-Badge bei 0 Zeichen und ein goldener Punkt für Seiten mit offenem Outbox-Eintrag; unten die Summenzeile über die aktuelle Trefferliste (`PagePickerModel.Summary`, memoisiert in `recompute()` — nicht pro Render).
- Zahlen-Quelle des Pickers ist der **lokale Spiegel**, nicht der Server-Tree (`/tree` liefert keine Zählwerte): `LibraryStore.refreshPageStats()` liest `store.pageStats(bookId:)` + `store.pendingOutbox()` in `pageStats` / `unsavedPageIds`, aufgerufen am Ende jedes `refreshPages()`. Eine Seite, deren Body noch nie gepullt wurde, fehlt bewusst → „—" statt einer erfundenen 0.

---

## 9. UI-Shell

- [ContentView.swift](schreibwerkstatt-focuseditor/ContentView.swift) — Auth-State-Maschine: `.unknown/.validating` → Loading/Login, `.signedOut` → Login, `.signedIn` → `EditorHostView`. Der Host prüft `editorBundle.state` (ready → Editor, refreshing → Loading, failed → Retry-UI), bindet das Fenster (`WindowAccessor`), steuert die Auto-Hide-Toolbar (Hover-Streifen + Offset + `allowsHitTesting`), und blendet das `PagePickerOverlay` ein.
- [AppToolbar.swift](schreibwerkstatt-focuseditor/AppToolbar.swift) — `BookPicker` · Breadcrumb (Kapitel › Seite) · ⌘O-Button · `WritingStatsLabel` · `SyncStatusLabel` (Konflikte orange) · Überlauf-Menü (Darstellung + Abmelden). Hintergrund: `WindowDragArea` + `.ultraThinMaterial` + `BrandColor`. Im nativen Vollbild (= ablenkungsfrei) ausgeblendet.
- [WindowChromeController.swift](schreibwerkstatt-focuseditor/WindowChromeController.swift) — `@MainActor ObservableObject` + `WindowAccessor`. Konfiguriert die Fenster-Titelleiste (titellos + transparent, Ampel-Buttons sichtbar) und beobachtet die **nativen** Vollbild-Notifications (`isNativeFullscreen`). Bewusst **ohne** `fullSizeContentView`: damit lag die schwere, transparente `WKWebView` über der eigenen Toolbar und verschluckte sie optisch — mit normaler Titelleiste sitzt der Inhalt (Toolbar + WebView) verlässlich darunter. Die Toolbar bleibt **immer** sichtbar (auch im Vollbild); ablenkungsfreies Ausblenden macht allein die Auto-Hide-Option.
- [ShortcutsHelpView.swift](schreibwerkstatt-focuseditor/ShortcutsHelpView.swift) — SSoT der Nutzer-Hilfe (⌘?). Bei jeder Shortcut-Änderung mitpflegen (harte Regel).
- [Settings/SettingsView.swift](schreibwerkstatt-focuseditor/Settings/SettingsView.swift) — `TabView` mit 7 Tabs (Allgemein/Darstellung/Typografie/Schreiben/Sync/Rechtschreibung/Konto). Alle Werte gerätelokal (UserDefaults/AppStorage).

---

## 10. Controller: lokale Einstellungen → Editor (über die Bridge)

Alle vier sind `@MainActor ObservableObject`, persistieren in UserDefaults und fliessen als **CSS/Werte über die Bridge** in den Editor (kein Fork). Muster: `bind(bridge)` setzt den Boot-Pull-Wert; `apply()` pusht live via Swift→JS-Event.

| Controller | Datei | Wirkung |
|---|---|---|
| `AppearanceController` | [Theme/AppearanceController.swift](schreibwerkstatt-focuseditor/Theme/AppearanceController.swift) | Light/Dark/System → `NSApp.appearance` (wirkt app-weit + auf `prefers-color-scheme` der WebView) |
| `TypographyController` | [Theme/TypographyController.swift](schreibwerkstatt-focuseditor/Theme/TypographyController.swift) | Schrift/Grösse/Zeilenhöhe/Spaltenbreite/Papier-Ton → CSS-Payload → `bridge.pushTypography()` |
| `FocusController` | [Focus/FocusController.swift](schreibwerkstatt-focuseditor/Focus/FocusController.swift) | Fokus-Granularität → CSS-Klasse `focus-mode--<raw>` → `bridge.pushFocusGranularity()`; Server-Seeding nur ohne lokalen Override |
| `WritingStatsStore` | [Writing/WritingStatsStore.swift](schreibwerkstatt-focuseditor/Writing/WritingStatsStore.swift) | **inbound**: hört `bridge.onStats`; Wort-/Zeichenzahl, Tages-Delta (Baseline je Seite/Tag), Lesezeit, Schreibziel |

Plus [Theme/BrandColor.swift](schreibwerkstatt-focuseditor/Theme/BrandColor.swift) (appearance-dynamische `NSColor`s aus Hex, spiegelt die Token-CSS des Hauptrepos) und [Theme/BrandFont.swift](schreibwerkstatt-focuseditor/Theme/BrandFont.swift) (System-Serif/Sans).

`FocusController` und `WritingStatsStore` zeigen die zwei Flussrichtungen: Fokus/Typografie **gehen raus** (Swift → Editor), Stats **kommen rein** (Editor → Swift via `reportStats`-Callback).

---

## 11. Drei durchgehende Datenflüsse

**A — OTA-Bundle laden:**
`EditorBundleStore.refresh` → `APIClient.getRaw(If-None-Match)` → 304 *oder* ZIP → `MiniZip.entries` → Staging + `WebAssets.indexHTML` → atomarer Swap → `AppSchemeHandler` liefert `swk-app://local/*` → WebView mountet `focus/standalone.js`.

**B — Eine Seite schreiben (local-first):**
Editor `input` → JS `save` → `EditorBridge` → `LocalStore.save` (Seite **+ Outbox**) → später Poll-Tick → `SyncEngine.pushOutbox` → `PUT /pages/:id` mit `expected_updated_at` → 200 → `markPushed` + neue Basis. UI wartet **nie** aufs Netz.

**C — Fremde Änderung empfangen (Cross-Session):**
Poll-Tick → `pullBook` → `GET …/sync` (Cursor) → pro Seite `applyServerPage`; ist es die offene **saubere** Seite → `editor.reloadPage` (still neu laden). Offene **dirty** Seite wird nie überschrieben → Konflikt erst beim nächsten Push (409 → `merge3`).

---

## 11b. Nebenwege ohne WebView-Beteiligung

Drei Funktionen laufen bewusst **komplett an der Bridge vorbei** — sie berühren
den Editor nicht, und ein Bridge-Op wäre nur ein Umweg mit zusätzlichem
Kopplungspunkt:

| Funktion | Weg | Warum kein Bridge-Op |
|---|---|---|
| Seiten anlegen/umbenennen/löschen ([PageAdminController](schreibwerkstatt-focuseditor/Library/PageAdminController.swift)) | Swift → Server → `store` → `library.refreshPages()` | Verwaltung von Datensätzen, kein Editor-Inhalt. Die offene Seite wird nur beim Löschen berührt (`library.closePage()`). |
| Frühere Fassungen ([PageRevisionStore](schreibwerkstatt-focuseditor/Revisions/PageRevisionStore.swift)) | Swift → Server; vorher `prepare` (Draft sichern + pushen), nach Restore `sync.adoptServerStateAfterRestore` | Der Server schreibt die alte Fassung zurück; der Client übernimmt sie VERBINDLICH (wie „Server übernehmen": Outbox-Eintrag droppen, Basis setzen, Reload mit `force`). Ein gewöhnlicher Pull übersprünge eine dirty Seite bzw. eine mit Outbox-Eintrag — und der lokale Stand drehte die Wiederherstellung per Merge zurück. |
| Buch-Export ([Export/](schreibwerkstatt-focuseditor/Export/)) | Swift → Server (`GET /export/book/:id/md`) → `NSSavePanel` | Der Server exportiert seinen eigenen Stand. Darum vorher `prepare` = `bridge.flushDraftSave()` + `sync.syncNow(manual:)`; was danach noch in der Outbox (`store`) liegt, weist das Banner als ungesynct aus. |

Gemeinsames Muster: **Server-Erfolg zuerst, lokale Wirkung danach.** Beim Löschen
ist das der Unterschied zwischen „Text weg, Seite lebt am Server weiter" und
einem sauberen Abbruch, bei dem nichts passiert ist.

## 12. Wo was hingehört (Entscheidungshilfe)

- **Editor-Bug/-Feature (Logik, CSS, Block-Merge)** → Hauptrepo, **nicht hier**. Client zieht das Bundle beim nächsten Start.
- **Neue Bridge-Op** → erst `WebAssets.bridgeFacadeJS` (JS) + `route(op:params:)` in [EditorBridge+Ops.swift](schreibwerkstatt-focuseditor/Web/EditorBridge+Ops.swift) (Swift, Parameter über die Validierer in `+Params`), dann Vertrag in [CLAUDE.md](CLAUDE.md) dokumentieren.
- **Neue Server-Interaktion** → `APIClient` + passender Store/Engine; nie aus der WebView.
- **Neue lokale Einstellung mit Editor-Wirkung** → Controller (`bind`/`apply`-Muster) + Settings-Tab; als CSS/Wert über die Bridge.
- **Neues Tastaturkürzel** → Code **und** [ShortcutsHelpView.swift](schreibwerkstatt-focuseditor/ShortcutsHelpView.swift) im selben Schritt.
- **Schema-Änderung am lokalen Spiegel** → neue GRDB-Migration in `GRDBLocalStore`.
- **Neuer Ausstiegspfad aus dem Editor** (Fenster, Szene, Beenden, Modus-Wechsel) → an einen Draft-Flush hängen, sonst kostet er bis zu 5 s Text (s. CLAUDE.md, harte Regeln).
- **Neuer nutzersichtbarer String** → `t("key")` + **beide** Kataloge; `LocalizationCatalogTests` hält das fest.
- **Neuer JS-Glue im Boot** → `WebAssetsSyntaxTests` parst ihn beim nächsten Testlauf mit (`node --check`); Verträge zusätzlich als `contains`-Test in `WebAssetsTests`.
- **Neuer Netz-Store** → über `MockURLProtocol` testbar halten: Session in den `APIClient` injizierbar lassen, Timing/Verzeichnisse nicht hart verdrahten (Vorbild `LektoratJobStore(pollInterval:maxPolls:)`, `EditorBundleStore(baseDirectory:)`).

Harte Regeln (kein Fork, WebView nur lokal, local-first, Token nur Keychain, Konflikte über Block-Merge, Datenverlust-Schutz) stehen verbindlich in [CLAUDE.md](CLAUDE.md).
