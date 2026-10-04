# Markendateien (Brand Assets)

Kanonische Marken-Quelldateien der Schreibwerkstatt, hier im Repo versioniert,
damit Icon-/Logo-/Font-Generierung ohne Zugriff aufs Hauptrepo möglich ist.

## Herkunft (Single Source of Truth)

Originale liegen im Hauptrepo `schreibwerkstatt/schreibwerkstatt`:

| Datei hier                          | Quelle im Hauptrepo                          |
|-------------------------------------|----------------------------------------------|
| `schreibwerkstatt_icon.svg`         | `public/schreibwerkstatt_icon.svg`           |
| `icon-192.png`, `icon-512.png`      | `public/icon-192.png`, `public/icon-512.png` |
| `fonts/Inter.var.woff2` u. Italic   | `public/fonts/`                              |
| `fonts/SourceSerif4.var.woff2` u. Italic | `public/fonts/`                         |
| `fonts/OFL.txt`                     | `public/fonts/OFL.txt` (SIL Open Font License) |

**Regel:** Ändert sich das Design im Hauptrepo, hier neu kopieren — nie hier
divergieren lassen. Diese Dateien sind ein Snapshot, kein Fork.

## Verwendung

- **App-Icon:** aus `schreibwerkstatt_icon.svg` gerendert (`rsvg-convert`) →
  `schreibwerkstatt-focuseditor/Assets.xcassets/AppIcon.appiconset/`.
  Neu erzeugen:
  ```sh
  cd ../schreibwerkstatt-focuseditor/Assets.xcassets/AppIcon.appiconset
  for px in 16 32 64 128 256 512 1024; do
    rsvg-convert -w $px -h $px ../../../brand/schreibwerkstatt_icon.svg -o icon_${px}.png
  done
  ```
- **Logo (in-App):** `schreibwerkstatt_icon.svg` als Vektor-Asset in
  `Assets.xcassets/AppLogo.imageset/`.
- **Fonts:** Inter (Sans) + Source Serif 4 (Serif), self-hosted. Die native
  Shell nutzt System-Pendants (SF / `.serif`-Design); die echten `.woff2`
  fließen über den Editor-Bundle-Step in die WebView (`Resources/web/`).
  Lizenz: SIL OFL — siehe `fonts/OFL.txt`.
