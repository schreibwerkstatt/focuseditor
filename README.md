# schreibwerkstatt-focuseditor

Nativer **macOS-Client** für den Focus-Editor der [Schreibwerkstatt](https://github.com/schreibwerkstatt/schreibwerkstatt). Eine SwiftUI/AppKit-Shell mit `WKWebView`, die ein lokal gecachtes Build des bestehenden Focus-Editors lädt — voll offline-fähig, ablenkungsfrei, genau eine Seite.

[![Download on the Mac App Store](https://img.shields.io/badge/Download-on_the_Mac_App_Store-blue.svg)](https://apps.apple.com/app/id6797073919)

> **Zweck:** ablenkungsfreies Schreiben auf einer Seite. Kein Buchorganizer, keine Analyse-Karten, keine KI-Jobs — nur der Schreibmodus.

## Funktionsweise

- Das Editor-Build wird **zur Laufzeit per OTA** vom Server gezogen (`GET /content/editor-bundle.zip`) und im App-Support gecacht — nicht zur Build-Zeit gebündelt.
- Der `WKWebView` lädt **immer** den lokalen Cache (`swk-app://`), **nie** eine Server-URL. Netzwerk macht ausschließlich der Swift-Kern.
- Schreiben geht zuerst in einen lokalen SQLite-Spiegel (GRDB). Eine Sync-Engine schiebt Änderungen bei Konnektivität an den Server und zieht Deltas zurück.
- Nach dem ersten erfolgreichen Bundle-Download arbeitet die App vollständig offline; nur der **allererste** Start braucht Netz.

## Architektur

```
AppKit/SwiftUI-Shell
  └─ WKWebView  ──lädt (swk-app://)──>  web-cache/  (lokal gecachtes Focus-Editor-Build)
        │  WKScriptMessageHandler-Bridge (JS ⇄ Swift)
        ▼
  Swift-Kern
     ├─ LocalStore         (GRDB / SQLite-Spiegel der Seiten)
     ├─ Outbox             (Schreib-Queue, immer erst lokal)
     ├─ SyncEngine         (Polling ~5 s + Reachability-Trigger; Push + Pull)
     ├─ EditorBundleStore  (OTA: zieht/cacht das Editor-Bundle, ETag-getrieben)
     └─ Auth               (Device-Token im Keychain)
                 │ HTTPS Bearer swd_…
                 ▼
        schreibwerkstatt-Server  (Express, Port 3737 / NGINX HTTPS)
```

Der Editor-Code wird **nicht geforkt**. Bei Editor-Bugs/-Features: Fix gehört ins [Hauptrepo](https://github.com/schreibwerkstatt/schreibwerkstatt) — der nächste Client-Start zieht das aktualisierte Bundle automatisch (ETag-getrieben). Hier liegt nur Bridge + Shell + Sync + Auth + OTA-Lader.

## Projektstruktur

```
schreibwerkstatt-focuseditor/
  schreibwerkstatt_focuseditorApp.swift   @main, Scene/Window
  ContentView.swift                       Shell-Root (WebView-Host + Lade-/Fehlerzustand)
  AppCore.swift                           app-weite Instanziierung (LocalStore, Sync, …)
  Web/                                    WKWebView-Host + Bridge
    EditorBundleStore.swift               OTA-Lader: Download + Entpacken + Cache-Swap + ETag
    MiniZip.swift                         bordeigener ZIP/DEFLATE-Reader (sandbox-tauglich)
    WebAssets.swift                       Bridge-Facade-JS + index.html-Boot (Client-Glue)
    AppSchemeHandler.swift                liefert den Cache unter swk-app:// an die WebView
    EditorBridge.swift / FocusWebView.swift
  Store/                                  GRDB-LocalStore + Outbox
  Sync/                                   SyncEngine + Reachability + SyncState + SyncModels
  Auth/                                   Keychain + Device-Token + Login-Flow + APIClient
  Library/                                Buch-/Seiten-Picker
  Theme/                                  Brand-Farben/-Fonts + Dark Mode
```

Der App-Sources-Ordner ist eine `PBXFileSystemSynchronizedRootGroup` (Xcode 16+) — neue Swift-Dateien kommen **automatisch** ins Target.

## Authentifizierung (Device-Token)

Auth läuft über **Device-Token** (Bearer `swd_…`), nicht OIDC:

1. Einmaliger Online-Login am Server → User stellt im `/me`-Bereich ein Device-Token aus (genau einmal sichtbar).
2. Token per Copy-Paste in den Client einfügen — der Client kann ein Token **nicht selbst ausstellen**.
3. Client cacht das Token im **macOS Keychain** (nie in UserDefaults/Plist/Logs).

Bei `401` (Token widerrufen): neu authentifizieren, lokale Inhalte **nie** verwerfen.

## Voraussetzungen

- Xcode 16+ (macOS-Target, SwiftUI-App-Lifecycle)
- GRDB (SQLite) — integriert via SPM (`groue/GRDB.swift`, ab 7.11.0)
- Erreichbarer schreibwerkstatt-Server (Default `localhost:3737`) + gültiges Device-Token

ZIP-Entpacken bewusst **ohne** Dependency (`MiniZip.swift` + `Compression`-Framework, sandbox-tauglich).

## Build & Run

```bash
xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug build
```

`-quiet` für kompakte Ausgabe anhängen. **Kein Bundle-Build-Step nötig** — das Editor-Build wird zur Laufzeit per OTA gezogen.

## Harte Regeln

- **Kein Editor-Fork.** Editor-Logik, CSS und `block-merge.js` kommen via OTA aus dem Hauptrepo. Gecachten Output nie von Hand editieren.
- **WebView lädt nur lokal.** Niemals eine Server-URL in den `WKWebView` laden. Server-Kontakt nur im Swift-Kern.
- **Local-first Writes.** Jeder Save geht zuerst in LocalStore + Outbox, erst danach zum Server. UI nie auf Netzwerk warten lassen.
- **Token nur im Keychain.** Niemals in UserDefaults, Plist, Logs oder Bridge-Messages leaken.
- **Konflikte über Block-Merge.** 409-Auflösung läuft über `block-merge.js` (3-Wege, `data-bid`), nicht über Last-Write-Wins.
- **Datenverlust-Schutz vor allem.** Bei Auth-/Sync-Fehlern lokale Inhalte behalten — kein automatisches Verwerfen.

## Weitere Dokumentation

Architektur, Bridge-Vertrag (JS ⇄ Swift), Server-Schnittstelle und Sync-Semantik sind ausführlich in [CLAUDE.md](CLAUDE.md) dokumentiert.
