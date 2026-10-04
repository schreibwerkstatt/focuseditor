#!/usr/bin/env bash
# publish-github-release.sh — Notarisiertes .dmg als GitHub-Release-Asset veroeffentlichen.
#
# Der Server (Mutterprojekt) liest das "latest"-Release dieses Repos ueber die
# GitHub-API und bietet das .dmg unter Profil-Einstellungen zum Download an.
# Damit landet jede neue Version automatisch dort — ohne das Binary in git zu legen.
#
# Voraussetzungen:
#   - gh CLI installiert + eingeloggt (gh auth status) mit Schreibrecht aufs Repo
#   - das uebergebene .dmg ist bereits signiert + notarisiert (scripts/release-dmg.sh)
#
# Nutzung:
#   scripts/publish-github-release.sh /Pfad/zu/Focuseditor-1.0.dmg
#   VERSION=1.1 scripts/publish-github-release.sh /Pfad/zu/Focuseditor.dmg
#
# Umgebungsvariablen:
#   VERSION   optional — ueberschreibt die aus dem .app-Bundle gelesene Version.
#             Daraus wird der Release-Tag "v<VERSION>" gebildet.
#   REPO      Default: schreibwerkstatt/focuseditor
#   NOTES     optional — Release-Notiz-Text. Ohne Wert: --generate-notes.

set -euo pipefail

DMG_PATH="${1:?Pfad zum notarisierten .dmg angeben}"
[[ -f "$DMG_PATH" ]] || { echo "FEHLER: .dmg nicht gefunden: $DMG_PATH" >&2; exit 1; }

REPO="${REPO:-schreibwerkstatt/focuseditor}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Sparkle generate_appcast finden -----------------------------------------
# Erzeugt + signiert (EdDSA, Privatkey aus dem Login-Keychain) das appcast.xml.
# Reihenfolge: explizites SPARKLE_BIN > Repo-Build-Dir (release-dmg.sh nutzt
# -derivedDataPath build) > irgendein DerivedData-Treffer. Schlägt fehl, wenn
# Sparkle nie aufgelöst wurde (dann zuerst einen Build laufen lassen).
find_generate_appcast() {
  if [[ -n "${SPARKLE_BIN:-}" && -x "$SPARKLE_BIN/generate_appcast" ]]; then
    echo "$SPARKLE_BIN/generate_appcast"; return 0
  fi
  local cand="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
  if [[ -x "$cand" ]]; then echo "$cand"; return 0; fi
  cand="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
            -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
  if [[ -n "$cand" && -x "$cand" ]]; then echo "$cand"; return 0; fi
  return 1
}

# --- Version bestimmen --------------------------------------------------------
# Bevorzugt VERSION-Env; sonst CFBundleShortVersionString aus dem frischen
# Release-Build-Produkt (single source: MARKETING_VERSION im Xcode-Projekt).
VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  APP_PLIST="$ROOT/build/Build/Products/Release/Focuseditor.app/Contents/Info.plist"
  if [[ -f "$APP_PLIST" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || true)"
  fi
fi
[[ -n "$VERSION" ]] || { echo "FEHLER: Version unbestimmbar — VERSION=… setzen." >&2; exit 1; }
TAG="v$VERSION"

echo "==> Repo:    $REPO"
echo "==> Version: $VERSION  (Tag: $TAG)"
echo "==> Asset:   $DMG_PATH"

# --- gh-Login pruefen ---------------------------------------------------------
gh auth status >/dev/null 2>&1 || { echo "FEHLER: 'gh' nicht eingeloggt (gh auth login)." >&2; exit 1; }

# --- Existiert der Tag bereits? -> sauber abbrechen mit Hinweis ---------------
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "FEHLER: Release '$TAG' existiert bereits." >&2
  echo "        MARKETING_VERSION im Xcode-Projekt erhoehen oder VERSION=… setzen." >&2
  exit 1
fi

# --- Release anlegen + Asset hochladen ---------------------------------------
# Asset-Name stabil halten, damit der Server-Parser robust den .dmg findet.
ASSET_NAME="Focuseditor-$VERSION.dmg"
TMP_ASSET="$(dirname "$DMG_PATH")/$ASSET_NAME"
if [[ "$DMG_PATH" != "$TMP_ASSET" ]]; then
  cp "$DMG_PATH" "$TMP_ASSET"
fi

# --- Appcast (Sparkle-Update-Feed) erzeugen + signieren ----------------------
# Sparkle lädt SUFeedURL = github.com/<repo>/releases/latest/download/appcast.xml.
# Der Feed muss die Download-URL des .dmg DIESES Releases tragen — darum der
# --download-url-prefix auf den Tag-Asset-Pfad. generate_appcast signiert das
# .dmg mit dem EdDSA-Privatkey (Login-Keychain; Pendant zu SUPublicEDKey).
GEN_APPCAST="$(find_generate_appcast)" || {
  echo "FEHLER: Sparkle 'generate_appcast' nicht gefunden." >&2
  echo "        Zuerst einen Build laufen lassen (löst das Sparkle-Paket auf) oder" >&2
  echo "        SPARKLE_BIN=<…/Sparkle/bin> setzen." >&2
  exit 1
}
APPCAST_DIR="$(mktemp -d)"
trap 'rm -rf "$APPCAST_DIR"' EXIT
cp "$TMP_ASSET" "$APPCAST_DIR/$ASSET_NAME"
DL_PREFIX="https://github.com/$REPO/releases/download/$TAG/"
echo "==> Appcast erzeugen + signieren (generate_appcast)..."
"$GEN_APPCAST" --download-url-prefix "$DL_PREFIX" "$APPCAST_DIR"
APPCAST_PATH="$APPCAST_DIR/appcast.xml"
[[ -f "$APPCAST_PATH" ]] || { echo "FEHLER: appcast.xml wurde nicht erzeugt." >&2; exit 1; }

NOTES_ARGS=(--generate-notes)
if [[ -n "${NOTES:-}" ]]; then
  NOTES_ARGS=(--notes "$NOTES")
fi

echo "==> Lege GitHub-Release an + lade Assets hoch (.dmg + appcast.xml)..."
gh release create "$TAG" "$TMP_ASSET" "$APPCAST_PATH" \
  --repo "$REPO" \
  --title "Focuseditor $VERSION" \
  --latest \
  "${NOTES_ARGS[@]}"

echo
echo "==> Fertig. Release veroeffentlicht:"
gh release view "$TAG" --repo "$REPO" --json url,tagName,assets \
  --jq '"  " + .url + "\n  Tag: " + .tagName + "\n  Assets: " + ([.assets[].name] | join(", "))'
echo
echo "    Der Server zieht das 'latest'-Release automatisch — neue Version ist sofort"
echo "    unter Profil-Einstellungen verfuegbar (kein Server-Deploy noetig)."
