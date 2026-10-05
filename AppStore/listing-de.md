# App-Store-Listing — Deutsch (Primärsprache)

Alles hier wird 1:1 in App Store Connect → *App-Informationen* bzw.
*Version → Deutsch* eingetragen. Zeichenzahlen sind Apple-Limits; die
geprüften Ist-Werte stehen in Klammern (`scripts/appstore-check-lengths.sh`).

## App-Informationen (sprachübergreifend)

| Feld | Wert |
|---|---|
| Bundle-ID | `David-Berger.schreibwerkstatt-focuseditor` |
| Primäre Kategorie | Produktivität (`PRODUCTIVITY`) |
| Sekundäre Kategorie | Bücher (`BOOKS`) |
| Copyright | 2026 David Berger |
| Altersfreigabe | 4+ (Fragebogen: [age-rating.md](age-rating.md)) |
| Preis | Gratis, keine In-App-Käufe |

### Kategorie — entschieden und gesetzt

Primär `PRODUCTIVITY`, sekundär `BOOKS` — so steht es seit 2026-08-17 in App
Store Connect, und beide Targets bauen passend dazu mit
`INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.productivity`
(pbxproj, vier Stellen: zwei Targets × Debug/Release). Apple mahnt Abweichungen
zwischen Info.plist und ASC an — die zwei Werte müssen zusammen wandern.

Begründung, falls das je wieder aufgemacht wird: Die App ist ein Schreibwerkzeug,
kein Lesegerät. „Bücher“ ist im Store die Ecke der Lese-Apps und taugt darum nur
als zweite Kategorie; „Bildung“ passt schlechter, weil die App nichts lehrt.
**Unterkategorien gibt es nur für `GAMES`** — hier ist nichts weiter auszufüllen.

## Name (max. 30)

```
Schreibwerkstatt Focuseditor
```

## Untertitel (max. 30)

```
Fokussiert schreiben, offline
```

## Promotional Text (max. 170, ohne Review änderbar)

```
Ein Abschnitt, eine Schreiblinie, sonst nichts. Deine Texte liegen zuerst lokal auf dem Mac und gleichen sich mit deinem Schreibwerkstatt-Konto ab, sobald Netz da ist.
```

## Keywords (max. 100, kommagetrennt, keine Leerzeichen nach Komma)

```
schreiben,fokus,ablenkungsfrei,roman,manuskript,autor,offline,lektorat,synonyme,textverarbeitung
```

Nicht in die Keywords: der App-Name und die Kategorie — Apple indexiert die
ohnehin. „Editor“, „Buch“ und „Text“ stecken bereits in Name/Untertitel/
Beschreibung.

## Beschreibung (max. 4000)

```
Focuseditor ist der ablenkungsfreie Schreibmodus der Schreibwerkstatt als native Mac-App: ein Abschnitt, eine Schreiblinie, sonst nichts. Kein Buchorganizer, keine Analysekarten, keine Werkzeugleisten-Wüste — nur der Text, an dem du gerade arbeitest.

BEGLEIT-APP — BITTE VOR DEM LADEN LESEN
Focuseditor gehört zur Schreibwerkstatt (schreibwerkstatt.app) und braucht ein Konto auf einem Schreibwerkstatt-Server. Einen eigenständigen Modus ohne Server gibt es nicht. Zum Ausprobieren ist ein Demo-Zugang eingebaut: ein Klick im Anmeldefenster, ohne eigenes Konto.

ZUERST LOKAL, DANN SYNC
Jeder Tastendruck landet zuerst in einem lokalen Speicher auf deinem Mac — nicht im Netz. Die App wartet nie auf eine Verbindung. Im Hintergrund gleicht sie ab, sobald Netz da ist; nach dem ersten Start arbeitest du vollständig offline weiter, im Zug genauso wie am Schreibtisch. Ändert sich derselbe Abschnitt hier und anderswo, führt die App die Absätze zusammen, statt eine Fassung zu überschreiben.

FOKUS
• Schreibmaschinen-Modus: die aktive Zeile bleibt ruhig auf der Schreiblinie
• Umgebung abdunkeln — wahlweise alles ausser der Schreibzeile oder ein Fenster von drei Absätzen
• Vollbild mit Werkzeugleiste, die sich von selbst wegblendet
• Abschnitte öffnen über einen Picker mit „Zuletzt geöffnet“ (⌘O)

TYPOGRAFIE, DIE DU EINSTELLST
Schriftart und -grösse, Zeilenhöhe, Spaltenbreite und Papierton — vom hellen Papier bis zum dunklen Schreibtisch. Hell, dunkel oder dem System folgend.

HILFE BEIM SCHREIBEN
• Rechtschreib- und Grammatikprüfung, mit eigenem Wörterbuch
• Synonyme mit ⌘⇧S: Thesaurus und KI-Vorschläge, passend zum Satz
• Anführungszeichen auf den Stil des Buchs ziehen — «Schweiz», „Deutschland“ oder “englisch”
• Wortzahl, Lesezeit, Tagesziel und Schreibzeit im Blick
• Lektorat des offenen Abschnitts anstossen, das auf deinem Server läuft

AUF DEM MAC ZU HAUSE
Deutsch und Englisch, Tastaturkürzel-Übersicht mit ⌘?, Dunkelmodus, Vollbild, Kontextmenü — eine echte Mac-App, kein Browserfenster im Anzug.

DEINE TEXTE, DEIN SERVER
Die App spricht ausschliesslich mit dem Server, den du selbst einträgst. Das Gerätetoken liegt im macOS-Schlüsselbund und verlässt den Mac nicht im Klartext. Keine Werbung, kein Tracking, keine Analyse durch Dritte. Die KI-gestützten Funktionen (Synonyme, Lektorat) laufen über deinen Server; welcher KI-Dienst dort arbeitet, bestimmt dessen Betreiber — nachzulesen in der Datenschutzerklärung.
```

## Neue Funktionen in dieser Version

Steht je Version in [whats-new.md](whats-new.md) — dort liegen der deutsche und
der englische Text nebeneinander, damit beide Sprachen nicht auseinanderlaufen.
Diese Datei führt nur, was sich von Release zu Release **nicht** ändert.

## URLs

| Feld | Wert |
|---|---|
| Support-URL | `https://schreibwerkstatt.app` |
| Marketing-URL | `https://schreibwerkstatt.app` |
| Datenschutzrichtlinie | `https://schreibwerkstatt.app/datenschutz` |

Die Support-URL zeigt bewusst auf die Startseite: dort stehen Funktionsumfang,
Registrierung und der Hinweis auf den Betreiber. Sobald es eine eigene
Hilfe-/Kontaktseite gibt, hier und in der englischen Fassung nachziehen.
