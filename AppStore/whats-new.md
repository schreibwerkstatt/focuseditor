# „Neue Funktionen in dieser Version“ — je Version, fertig zum Kopieren

Ein Abschnitt pro Store-Version, neueste zuerst, jeweils **Deutsch und
Englisch**. Die Code-Blöcke gehen 1:1 in App Store Connect → *Version → Deutsch
bzw. Englisch → „Neue Funktionen“*. Limit 4000 Zeichen, geprüft von
`scripts/appstore-check-lengths.sh` (liest auch diese Datei).

Zwei Regeln, damit der Text stimmt:

- **Bezug ist die letzte veröffentlichte Store-Version**, nicht der letzte
  Versions-Bump. Zwischen-Bumps (z. B. 3.19) landen im Build der nächsten
  eingereichten Version und sind damit schon draussen — sie gehören **nicht**
  noch einmal in die Notes. Grundlage ist also
  `git log v<letzte-Store-Version>..HEAD` bzw. der Diff der Builds.
- **Nutzersicht, keine Technik.** Migrationen, Refactorings, Guards und
  Test-Änderungen kommen nicht vor. Wer das lesen will, liest die Commits.

Die Erstversion braucht keinen Text — Apple zeigt „Neue Funktionen“ erst ab dem
ersten Update und lässt das Feld dort leer.

## 3.23 · Deutsch (max. 4000)

```
• Sync-Verbesserung: Seiten, die beim Öffnen nachgeladen wurden, werden jetzt zuverlässig synchronisiert
• Einstellungen ▸ Konto: „Lokalen Spiegel zurücksetzen" baut den lokalen Speicher frisch vom Server auf — hilfreich, wenn der Sync mal hakt
```

## 3.23 · English (max 4000)

```
• Sync improvement: pages loaded on demand are now synced reliably
• Settings ▸ Account: "Reset local mirror" rebuilds the local storage fresh from the server — helpful when sync gets stuck
```

## 3.22 · Deutsch (max. 4000)

```
Widerrufen (⌘Z) arbeitet jetzt in kleinen Schritten — Satz für Satz statt alles seit dem letzten Mausklick.

• ⌘Z nimmt einzelne Sätze zurück, ⌘⇧Z setzt sie wieder ein; nach einer grösseren Rücknahme erscheint kurz ein Hinweis mit dem Rückweg
• Neu: „Frühere Fassungen …“ (⌘⇧R) zeigt die gespeicherten Fassungen der offenen Seite samt Vorschau — Wiederherstellen legt selbst eine Fassung an, es geht also nichts verloren
• Seiten verwalten ohne Umweg über den Browser: „Neue Seite …“ (⌘N) sowie Umbenennen und Löschen direkt im Seiten-Picker (⌘O)
• Neu: „Buch exportieren …“ schreibt das ganze Buch als eine Markdown-Datei — offline, aus dem Stand auf deinem Mac
• Der Seiten-Picker zeigt, wie viel auf einer Seite steht: Zeichen- und Wortzahl je Seite plus Summe, einstellbar über „Zählwert im Seiten-Picker“
• Beim Beenden mit ⌘Q wird der zuletzt getippte Satz noch gesichert
• Einstellungen ▸ Konto: „Diagnose kopieren“ legt einen Zustandsbericht für Support-Anfragen in die Zwischenablage — ohne Token, ohne Text aus dem Manuskript
```

## 3.22 · English (max 4000)

```
Undo (⌘Z) now works in small steps — sentence by sentence instead of everything since your last mouse click.

• ⌘Z takes back single sentences, ⌘⇧Z puts them back; after a larger undo a short notice shows the way back
• New: “Earlier Versions …” (⌘⇧R) lists the saved versions of the open page with a preview — restoring saves a version of its own, so nothing is lost
• Manage pages without detouring to the browser: “New Page …” (⌘N) plus rename and delete right in the page picker (⌘O)
• New: “Export Book …” writes the whole book as a single Markdown file — offline, from the copy on your Mac
• The page picker shows how much is on a page: characters and words per page plus a total, configurable via “Count in the page picker”
• Quitting with ⌘Q saves the sentence you just typed
• Settings ▸ Account: “Copy diagnostics” puts a status report for support requests on the clipboard — no token, no text from your manuscript
```

## 3.21 — nie eingereicht (Inhalt steckt in 3.22)

Build 43 wurde hochgeladen, die Version aber nie zur Review gegeben. Die
Zählwerte im Seiten-Picker sind darum Teil der 3.22-Notes oben; die Texte hier
bleiben nur als Archiv stehen.

## 3.21 · Deutsch (max. 4000)

```
Der Seiten-Picker (⌘O) zeigt jetzt, wie viel auf einer Seite steht.

• Zeichen- und Wortzahl an jeder Seite, dazu eine Summe über alle angezeigten Seiten
• Neue Einstellung „Zählwert im Seiten-Picker“: Zeichen, Wörter, beides oder aus
• Unbeschriebene Seiten sind als „leer“ markiert, und ein feiner Punkt zeigt, dass eine Seite noch auf den Sync wartet
• Gezählt wird der Stand auf deinem Mac; Seiten, die noch nie geladen wurden, zeigen „—“ statt einer erfundenen Null
```

## 3.21 · English (max 4000)

```
The page picker (⌘O) now shows how much is on each page.

• Character and word count on every page, plus a total across the pages shown
• New setting “Count in the page picker”: characters, words, both, or off
• Blank pages are marked “empty”, and a small dot shows that a page is still waiting to sync
• The counts come from the copy on your Mac; pages that were never loaded show “—” instead of a made-up zero
```

## 3.20 — Erstveröffentlichung (kein Text nötig)

Erste Fassung im Mac App Store (Build 42, `READY_FOR_SALE`). „Neue Funktionen“
bleibt leer. Enthalten war ausser dem vollen Funktionsumfang alles, was die drei
App-Review-Runden gefordert haben:

- Kein falscher Hinweis „Token ungültig oder widerrufen“ mehr beim ersten Start
  ohne bestehende Anmeldung (3.19).
- Fenster → „Schreibfenster“ (⌘0) öffnet das geschlossene Hauptfenster wieder
  (Guideline 4 – Design, 3.20).
- Konto löschen in der App (Guideline 5.1.1(v)), Store-Kategorie
  Produktivität, macOS 14 als Mindestversion.

**Archiv** — der Text, der für die Erstversion vorbereitet war (aus
`listing-de.md`/`listing-en.md`, dort nicht mehr geführt). Nicht wiederverwenden,
er beschreibt den Grundumfang, nicht ein Update:

```
Erste Fassung im Mac App Store.

• Ablenkungsfreier Schreibmodus für genau eine Seite, voll offline-fähig
• Lokaler Speicher mit Hintergrund-Sync zu deinem Schreibwerkstatt-Konto
• Schreibmaschinen-Modus, Fokus-Abdunklung und einstellbare Typografie
• Rechtschreibprüfung, Synonyme (⌘⇧S) und Anführungszeichen-Normalisierung
• Wortzahl, Tagesziel und Schreibzeit
• Deutsch und Englisch
```

```
First release on the Mac App Store.

• Distraction-free writing mode for exactly one page, fully offline-capable
• Local storage with background sync to your Schreibwerkstatt account
• Typewriter mode, focus dimming and adjustable typography
• Spell checking, synonyms (⌘⇧S) and quotation-mark normalisation
• Word count, daily goal and writing time
• German and English
```
