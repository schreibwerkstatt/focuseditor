# App-Store-Metadaten

Alles, was in App Store Connect eingetragen wird — fertig zum Kopieren. Der
Code-Teil (zweites Target, Signierung, `.pkg`-Export) steht in
[SIGNING.md](../SIGNING.md) „App Store“; hier liegt nur das Drumherum.

| Datei | Wofür in ASC |
|---|---|
| [listing-de.md](listing-de.md) | App-Informationen + Version → **Deutsch** (Primärsprache) |
| [listing-en.md](listing-en.md) | Version → **Englisch** |
| [whats-new.md](whats-new.md) | „Neue Funktionen in dieser Version“ — **je Version**, de + en |
| [app-privacy.md](app-privacy.md) | App-Datenschutz (Fragebogen) |
| [age-rating.md](age-rating.md) | Altersfreigabe (Fragebogen) → **4+** |
| [../REVIEW-NOTES.md](../REVIEW-NOTES.md) | App-Prüfungsinformationen (Demo-Zugang, 2.5.2) |
| [screenshots/de/](screenshots/de/) · [screenshots/en/](screenshots/en/) | Screenshots, je 4 Stück, 2880×1800 |

## Stand in App Store Connect (per API geprüft, 2026-10-04)

**Die App ist im Mac App Store veröffentlicht.** App-ID `6797073919`, SKU
`SWK-FOCUSEDITOR-MAC`, Primärsprache de-DE, Kategorien Produktivität + Bücher,
Altersfreigabe 4+, Inhalte Dritter deklariert (`USES_THIRD_PARTY_CONTENT`).

| Version | Build | Zustand |
|---|---|---|
| 3.20 | 42 | `READY_FOR_SALE` — die Erstveröffentlichung, nach drei Review-Runden |
| 3.21 | 43 | `READY_FOR_SALE` |
| 3.22 | 44 | `READY_FOR_SALE` |
| **3.23** | 45 | `READY_FOR_SALE` — zuletzt veröffentlicht |
| **3.24** | 46 (hochgeladen 2026-10-04) | Version im Browser anzulegen, Build zuzuordnen, „Neue Funktionen“ aus [whats-new.md](whats-new.md) |

Mit dem vorhandenen API-Schlüssel (Rolle *Developer*) **lesbar**: Versionen,
Builds, Localizations, Kategorien, Altersfreigabe — daher die Tabellen oben.
**Nicht** lesbar/schreibbar: App-Datenschutz-Fragebogen (404), Preis und
Verfügbarkeit (403), Release-Notes und Antworten ans Review-Team (403 beim
Schreiben). Das läuft alles über den Browser.

## Ablauf für ein Versions-Update

Der Code-Teil ist automatisiert: `/release` (bzw. `/release beide`, wenn die
Sparkle-Bestandsnutzer dieselbe Version bekommen sollen) bumpt, baut, prüft,
committet und lädt das `.pkg` per `UPLOAD=1 scripts/archive-mas.sh` hoch. Danach
bleibt die Browser-Arbeit in App Store Connect:

1. Neue Version anlegen (Versionsnummer = `MARKETING_VERSION` aus
   [../Version.xcconfig](../Version.xcconfig)). Beschreibung, Keywords, URLs und
   Screenshots übernimmt ASC von der Vorgängerversion — nur abweichende Werte
   nachziehen (Quelle: [listing-de.md](listing-de.md) / [listing-en.md](listing-en.md)).
2. **„Neue Funktionen“ in de *und* en** aus [whats-new.md](whats-new.md)
   einsetzen. Fehlt der Abschnitt für die Version, zuerst dort schreiben — die
   Datei ist die Quelle, nicht das ASC-Feld.
3. Build zuordnen (Verarbeitung dauert ~10–30 min nach dem Upload).
4. Prüfungsinformationen kontrollieren → [../REVIEW-NOTES.md](../REVIEW-NOTES.md)
   (Demo-Zugang; bei einer 2.1-Rückfrage zusätzlich den Screencast,
   `scripts/appstore-review-video.sh`).
5. Einreichen. **Bei einem Reject** vor dem erneuten Upload
   `CURRENT_PROJECT_VERSION` erhöhen — Apple nimmt keine Build-Nummer zweimal.

Der Erst-Einrichtungs-Teil (App-Record, Altersfreigabe, App-Datenschutz,
Kategorien, Deployment-Target, Kontolöschung) ist erledigt und muss nur bei
Änderungen wieder angefasst werden — Fragebögen in [age-rating.md](age-rating.md)
und [app-privacy.md](app-privacy.md).

## Screenshots

Vier pro Sprache, aufgenommen am **echten Build** gegen das öffentliche
Demo-Konto (`demo.schreibwerkstatt.app`, Beispielbuch „Die Verwandlung“):

| # | Motiv |
|---|---|
| 01 | Schreibfläche hell, Papier-Ton — die Kernansicht |
| 02 | Seiten-Picker (⌘O) mit „Zuletzt geöffnet“ |
| 03 | Einstellungen → Typografie (Schrift, Zeilenhöhe, Spaltenbreite, Papier) |
| 04 | Schreibfläche dunkel, Nacht-Ton |

Format: 2880×1800 (= 1440×900 pt auf Retina), PNG **ohne Alphakanal** — ASC
weist transparente Screenshots zurück. Neu aufnehmen:

```bash
scripts/appstore-screenshots.sh de
scripts/appstore-screenshots.sh en
```

Das Skript baut dafür eine **isolierte Kopie** der App (eigene Bundle-ID *und*
eigener Keychain-Service). Der Grund steht im Skriptkopf und ist wichtig: der
Keychain-Eintrag hängt an einer festen (service, account)-Kombination, nicht am
Server — ein Demo-Login aus der normalen App überschriebe das
Produktions-Gerätetoken, das nur einmal angezeigt wird.

**Grenze:** Synthetische Tastendrücke erreichen die WKWebView nicht (nur
AppKit-Shortcuts wie ⌘O/⌘, kommen an). Aufnahmen, die eine Interaktion *im
Text* brauchen — Synonym-Menü (⌘⇧S), Rechtschreib-Popover — müssen von Hand
gemacht werden. Fenster dafür auf exakt 1440×900 pt setzen und mit
`screencapture -x -R 60,60,1440,900` aufnehmen, danach
`swift scripts/strip-alpha.swift` drüberlaufen lassen.

## Textlängen prüfen

```bash
scripts/appstore-check-lengths.sh
```

Liest die Code-Blöcke aus den beiden Listing-Dateien **und** aus
[whats-new.md](whats-new.md) und vergleicht sie mit Apples Limits (Name 30,
Untertitel 30, Promo 170, Keywords 100, Beschreibung 4000, Neue Funktionen 4000).
Läuft ohne Netz.

## Offene Punkte

Die Blocker der ersten Einreichung sind alle erledigt — Kategorien
(`LSApplicationCategoryType = public.app-category.productivity`, Build und
Store-Eintrag stimmen überein), Kontolöschung in der App (Richtlinie 5.1.1(v)),
`MACOSX_DEPLOYMENT_TARGET` 14.0. Was bleibt:

- **Support-URL**: zeigt weiter auf die Startseite. Sobald es eine eigene
  Hilfe-/Kontaktseite gibt, in beiden Listing-Dateien und in ASC nachziehen.
- **Marketing-URL `en`**: in ASC leer, in `de` gesetzt — beim nächsten
  Versionsdurchgang mitnehmen.
- **ASC-API-Schlüssel** hat nur die Rolle *Developer*: Release-Notes und
  Antworten ans Review-Team lassen sich nicht per API schreiben. Ein
  App-Manager-Key würde Schritt 2 des Ablaufs automatisierbar machen.
