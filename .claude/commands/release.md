---
description: Version bumpen, builden, committen + veröffentlichen — als App-Store-Paket (Default) und/oder als notarisiertes .dmg (GitHub-Release inkl. Sparkle-Appcast)
---

Führe den kompletten Release-Workflow für **schreibwerkstatt-focuseditor** (nativer macOS-Client) aus. Dieser Command ist die **gezielte Freigabe** des Users — wenn er aufgerufen wird, den ganzen Ablauf ohne weitere Rückfrage durchziehen (außer ein Build-/Notarisierungs-Schritt schlägt fehl, dann stoppen und melden).

## Argumente (`$ARGUMENTS`, Reihenfolge egal, beide optional)

- **Bump-Höhe:** `patch` | `minor` | `major`. Fehlt sie, aus den seit dem letzten Tag liegenden Änderungen ableiten — neue nutzersichtbare Features → `minor`, sonst `patch`, im Zweifel `patch`.
- **Kanal:** `appstore` (Default) | `dmg` | `beide`.

```
/release                  → App Store, Bump-Höhe abgeleitet
/release minor            → App Store, Minor-Bump
/release dmg              → nur DMG (GitHub-Release + Sparkle-Appcast)
/release minor dmg        → DMG, Minor-Bump
/release beide            → ein Bump, danach DMG-Release UND App-Store-Upload
```

Es gibt **zwei Distributionswege auf einem Quellcode** (Hintergrund: [CLAUDE.md](CLAUDE.md) „Zwei Distributionswege"). Der App Store ist der **Hauptkanal**; das DMG bleibt vollwertig, weil die Bestandsnutzer aus der Sparkle-Welt weiter versorgt werden müssen (sie wechseln **nicht** von selbst in den Store) — es wird nur nicht mehr automatisch mitgezogen. Wenn ein Release beide Nutzergruppen erreichen soll, ist `beide` der richtige Aufruf. Den Kanal gibt allein das Argument vor — nicht mitten im Ablauf nachfragen; lief nur `appstore`, in der Abschluss-Zusammenfassung **erwähnen**, dass die DMG-/Sparkle-Nutzer diese Version nicht bekommen. Nachziehen **derselben** Version geht dann nicht über den Command (der bumpt immer), sondern von Hand: `git tag v<MARKETING_VERSION> && git push origin v<MARKETING_VERSION>`, danach `PUBLISH=1 scripts/release-dmg.sh` (= Schritte 7 + 8).

Der Versions-Bump passiert **einmal** am Anfang und gilt für beide — beide Targets lesen dieselbe [Version.xcconfig](Version.xcconfig). Nie pro Kanal separat bumpen, sonst laufen DMG- und Store-Version auseinander.

Die Schritte 1–6 sind für alle Kanäle identisch. Danach verzweigt es:

| Schritt | `appstore` | `dmg` |
|---|---|---|
| 7 Tag + Push | ❌ (kein Tag, aber Commit + `git push origin main`) | ✅ |
| 8 notarisiertes .dmg + GitHub-Release | ❌ | ✅ |
| 9 Archiv + .pkg-Export + Upload | ✅ | ❌ |

Bei `beide`: erst 7 + 8, dann 9.

Schritte:

1. **Stand prüfen:** `git status` + `git diff --stat` (und ggf. `git log --oneline <letzter-tag>..HEAD`) ansehen, damit die Commit-Message + Release-Notes die Änderungen korrekt beschreiben. Aktuelle Version aus [Version.xcconfig](Version.xcconfig) lesen (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`).
2. **Bumpen (nur in [Version.xcconfig](Version.xcconfig) — SSoT, nie woanders hartcodieren):** `MARKETING_VERSION` nach SemVer anheben (Höhe s.o.) **und** `CURRENT_PROJECT_VERSION` um genau 1 erhöhen. Beide Felder gemeinsam. Diese Versionsnummern stehen für CFBundleShortVersionString, den GitHub-Tag `v<…>`, den .dmg-Dateinamen und die Sparkle-Update-Erkennung.
3. **Debug-Build verifizieren (Pflicht):**
   ```bash
   xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug build -quiet
   ```
   Muss `** BUILD SUCCEEDED **` liefern. Bei Fehler: stoppen und fixen, nicht weitermachen.

   Wurde im Release-Diff Sparkle-Code, eine Info.plist oder die Projektdatei berührt, **zusätzlich** das App-Store-Target bauen — ein fehlender `#if SPARKLE`-Guard bricht sonst nur den anderen Kanal, und das fällt erst beim nächsten Store-Release auf:
   ```bash
   xcodebuild -scheme Focuseditor-MAS -configuration Release -derivedDataPath build/mas build -quiet
   ```
   (Bei Kanal `appstore`/`beide` macht [scripts/archive-mas.sh](scripts/archive-mas.sh) diese Gegenprobe in Schritt 9 ohnehin selbst.)
4. **Guards (Pflicht):**
   ```bash
   xcodebuild -scheme schreibwerkstatt-focuseditor -configuration Debug test \
     -only-testing:schreibwerkstatt-focuseditorTests/SourceFileSizeTests \
     -only-testing:schreibwerkstatt-focuseditorTests/DistributionTargetsTests
   ```
   Beide müssen grün sein. Datei-Größe schlägt an → siehe CLAUDE.md (aufteilen oder bewusst in `allowedOverLimit`). `DistributionTargetsTests` schlägt an → die zwei Kanäle sind auseinandergelaufen (Plist-Key nur in einer Datei, Sparkle/Entitlements im MAS-Target, Bundle-ID oder Quell-Gruppe verschieden, `Version.xcconfig` nicht mehr projektweit). Das **vor** dem Bump fixen — es würde sonst genau den anderen Kanal treffen.
5. **Release-Notes schreiben (Pflicht, [AppStore/whats-new.md](AppStore/whats-new.md)):** Für die neue Version einen Abschnitt **ganz oben** anlegen — je ein Code-Block `## <version> · Deutsch (max. 4000)` und `## <version> · English (max 4000)`, Aufbau wie beim Vorgänger. Die Datei ist die **Quelle** dieser Texte, nicht das ASC-Feld; ohne Abschnitt gibt es in Schritt 9 nichts zu kopieren.
   - **Bezug ist die letzte im Store veröffentlichte Version**, nicht der letzte Bump. Zwischen-Bumps, die nur als DMG rausgingen, sind für Store-Nutzer neu und gehören mit in den Text — Grundlage ist also der Diff seit der letzten `READY_FOR_SALE`-Version (live abfragen: `scripts/appstore-status.sh`, Zeile „Zuletzt veröffentlicht“), nicht `<letzter-tag>..HEAD`.
   - **Nutzersicht, keine Technik:** was sich für den Schreibenden ändert. Migrationen, Refactorings, Guards und Test-Änderungen kommen nicht vor.
   - Bei Kanal `dmg` den Abschnitt trotzdem schreiben und mit „nur DMG, noch nicht im Store" markieren — der nächste Store-Release fasst ihn mit ein.
   - Danach die Längen prüfen (Limit 4000 je Sprache):
     ```bash
     scripts/appstore-check-lengths.sh
     ```
   - Wurde ein nutzersichtbarer Text der Listing-Seite berührt (Beschreibung, Keywords, URLs), im selben Schritt [AppStore/listing-de.md](AppStore/listing-de.md)/[listing-en.md](AppStore/listing-en.md) nachziehen — sonst laufen Repo und Store auseinander.
6. **Committen:** Alle Änderungen `git add -A`, Commit mit aussagekräftiger Message — Features in Stichpunkten + Abschlusszeile im Repo-Stil `version <MARKETING_VERSION> (build <CURRENT_PROJECT_VERSION>)`. Abschliessend der Co-Author-Trailer:
   ```
   Co-Authored-By: Claude <MODELL> <noreply@anthropic.com>
   ```
   `<MODELL>` ist das Modell, das den Commit **tatsächlich** macht — also der Trailer, den die laufende Umgebung vorgibt (z. B. `Claude Opus 5`). Hier bewusst **kein** fester Name: eine hartkodierte Version veraltet mit dem nächsten Modellwechsel und schreibt dann eine falsche Zuordnung in die Historie.
7. **Taggen + pushen** *(Kanal `dmg`/`beide`)*: `git tag v<MARKETING_VERSION>`, dann `git push origin main` **und** `git push origin v<MARKETING_VERSION>`.
   *(Kanal `appstore` — der Default: nur `git push origin main`. Kein Tag, weil er zum GitHub-Release gehört und ohne DMG-Asset irreführend wäre. Wird das DMG für dieselbe Version später nachgezogen, entsteht der Tag dabei von Hand, s. Kanal-Abschnitt oben.)*
8. **Notarisiertes .dmg bauen + als GitHub-Release veröffentlichen** *(Kanal `dmg`/`beide`)*:
   ```bash
   PUBLISH=1 scripts/release-dmg.sh
   ```
   Das Skript zieht die Version automatisch aus [Version.xcconfig](Version.xcconfig) und erledigt in einem Rutsch: frischer Release-Build → signieren + **notarisieren** + stapeln ([scripts/notarize.sh](scripts/notarize.sh)) → Drag-to-Applications-.dmg → .dmg signieren + notarisieren → Gatekeeper-Check → dann [scripts/publish-github-release.sh](scripts/publish-github-release.sh): **Sparkle-`appcast.xml`** erzeugen + EdDSA-signieren und zusammen mit dem `Focuseditor-<version>.dmg` als `--latest`-Release unter dem (in Schritt 7 bereits gepushten) Tag `v<version>` hochladen.
   - Voraussetzungen liegen in [scripts/release.env](scripts/release.env) (`DEV_ID_APP` + notarytool-Key) und `gh auth` muss eingeloggt sein — beides ist eingerichtet. Schlägt Notarisierung/Upload fehl → Fehler melden, **nicht** den lokalen Commit/Tag zurückrollen (der Push ist schon erfolgt).

9. **App-Store-Paket bauen + hochladen** *(Kanal `appstore`/`beide`)*:
   ```bash
   UPLOAD=1 scripts/archive-mas.sh
   ```
   Das Skript baut zuerst das DMG-Schema als Gegenprobe, archiviert dann das Target `Focuseditor-MAS`, prüft das archivierte Bundle auf die App-Store-Blocker (kein Sparkle.framework, kein `Contents/XPCServices`, keine `temporary-exception`-Entitlement, keine `SU*`-Keys), exportiert nach `build/mas/export/*.pkg` ([Config/ExportOptions-MAS.plist](Config/ExportOptions-MAS.plist)) und lädt das Paket zu App Store Connect hoch (`ASC_APP_ID` ist im Skript vorbelegt). Ohne `UPLOAD=1` endet es beim `.pkg` — dieser Weg ist nur für Trockenläufe gedacht.
   - **Kein** Tag, **kein** GitHub-Release, **keine** Notarisierung — das macht Apple beim Store-Ingest.
   - Der Upload **veröffentlicht nichts**: der Build landet in App Store Connect und wird dort verarbeitet (~10–30 min). Der vorhandene Notarisierungs-Key trägt ihn (verifiziert am 2026-08-16 mit 3.20 (42)); nur die **Metadaten**-API (Release-Notes, Antwort an den Review) bleibt ihm mit `403` verwehrt (Rolle „Developer"), das läuft über den Browser. Schlägt der Upload fehl, auf Transporter/Xcode-Organizer ausweichen — das ist dann kein Problem des Pakets. **Nicht** den Commit/Tag zurückrollen.
   - **Voraussetzungen** (Apple-Kontoarbeit, s. [SIGNING.md](SIGNING.md) „App Store"): App ID registriert, Zertifikate „Apple Distribution" + „Mac Installer Distribution", Provisioning-Profil *Mac App Store*, App-Record in App Store Connect. Fehlt davon etwas, läuft Archiv + Sanity-Check durch und der **Export bricht mit einem Signier-/Profilfehler ab** — das melden, nicht umgehen.
   - **Danach im Browser** (nicht automatisierbar, s. Metadaten-`403`): App Store Connect → neue Version anlegen → Build zuordnen → „Neue Funktionen" in **de und en** aus [AppStore/whats-new.md](AppStore/whats-new.md) einsetzen (in Schritt 5 geschrieben, 1:1 kopieren) → zur Review einreichen → nach der Freigabe veröffentlichen. Der vollständige Ablauf steht in [AppStore/README.md](AppStore/README.md), den aktuellen ASC-Stand liefert `scripts/appstore-status.sh`. Am Ende des Commands diese offenen Schritte explizit auflisten — inklusive der beiden Notes-Texte im Klartext, damit sie direkt aus der Antwort kopierbar sind. **Bei einem Reject** vor dem erneuten Upload `CURRENT_PROJECT_VERSION` erhöhen — Apple nimmt keine Build-Nummer zweimal an.

**Warum notarisiertes .dmg + Appcast (nicht nur ein Debug-Artefakt):** Der Server (Mutterprojekt) liest das `latest`-Release und bietet das .dmg unter Profil-Einstellungen zum Download an; **Sparkle** zieht `releases/latest/download/appcast.xml` für In-App-Auto-Updates. Beides setzt ein mit „Developer ID Application" signiertes, notarisiertes Image samt EdDSA-signiertem Appcast voraus (siehe [SIGNING.md](SIGNING.md)). Die Versionserkennung vergleicht den Tag (`v` gestrippt) per SemVer gegen die laufende App.

**Tastaturkürzel-/Lokalisierungs-Pflichten** (CLAUDE.md): Wurde im Release-Diff ein Shortcut oder ein UI-String berührt, vor dem Commit prüfen, dass [ShortcutsHelpView.swift](schreibwerkstatt-focuseditor/ShortcutsHelpView.swift) bzw. die Kataloge [mac-de.json](schreibwerkstatt-focuseditor/Localization/mac-de.json)/[mac-en.json](schreibwerkstatt-focuseditor/Localization/mac-en.json) mitgezogen wurden.

Am Ende: knappe Zusammenfassung mit der neuen Version (Marketing + Build), Commit-Hash und — je nach Kanal — Release-URL und/oder Pfad zum `.pkg` samt der noch offenen manuellen Schritte in App Store Connect. Beim Default-Kanal `appstore` zusätzlich der Satz, dass die DMG-/Sparkle-Nutzer diese Version **nicht** erhalten.
