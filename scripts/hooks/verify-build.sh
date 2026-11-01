#!/usr/bin/env bash
# verify-build.sh — Stop-Hook: verifiziert am Ende einer Claude-Runde, was die
# harten Regeln aus CLAUDE.md verlangen.
#
#   1. Swift geändert (Marker swift-pending)
#      → volle Test-Suite des DMG-Schemas (enthält Build + SourceFileSizeTests
#        + DistributionTargetsTests)
#   2. App-Store-Kanal betroffen (Marker mas-pending)
#      → zusätzlich Release-Build des Targets „Focuseditor-MAS". Eigener
#        derivedDataPath `build/mas-hook` — beide Targets heißen Focuseditor.app
#        (würden sich überschreiben), und `build/mas` gehört dem Release-Weg
#        (scripts/archive-mas.sh), der sonst mit diesem Lauf um die build.db
#        streitet.
#
# Marker setzt scripts/hooks/mark-changed.sh (PostToolUse). Ohne Marker: no-op.
# Ausgabe ist eine Zeile JSON mit `systemMessage` für die Claude-Code-UI.
#
# Logs: /tmp/swk-focuseditor-test.log · /tmp/swk-focuseditor-mas.log

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SWIFT_MARKER=/tmp/swk-focuseditor-swift-pending
MAS_MARKER=/tmp/swk-focuseditor-mas-pending
TEST_LOG=/tmp/swk-focuseditor-test.log
MAS_LOG=/tmp/swk-focuseditor-mas.log
LOCK=/tmp/swk-focuseditor-verify.lock

[[ -f "$SWIFT_MARKER" || -f "$MAS_MARKER" ]] || exit 0

# Zwei parallele xcodebuild-Läufe auf demselben derivedDataPath scheitern an der
# gesperrten build.db („database is locked"). `mkdir` ist atomar → einfacher Lock.
if ! mkdir "$LOCK" 2>/dev/null; then
    echo '{"systemMessage":"⏳ schreibwerkstatt-focuseditor: Verifikation läuft schon — übersprungen"}'
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

run_tests=0; run_mas=0
[[ -f "$SWIFT_MARKER" ]] && run_tests=1
[[ -f "$MAS_MARKER"   ]] && run_mas=1
rm -f "$SWIFT_MARKER" "$MAS_MARKER"

cd "$ROOT" || exit 0

# Zusammenfassung als schlichter String aufbauen — kein Array (macOS liefert
# bash 3.2, wo `${arr[*]}` mit `set -u` auf einem leeren Array stolpert).
summary=""; ok=1
add() { [[ -n "$summary" ]] && summary="$summary · $1" || summary="$1"; }

if (( run_tests )); then
    # SyncIntegrationTests brauchen den Testserver aus dem Scheme (SW_E2E_BASE,
    # Default remote-desktop.lan:3737). Ist er nicht erreichbar, würden sie mit
    # -1004 FAILEN statt zu skippen → dann gezielt auslassen statt Fehlalarm.
    skip_args=()
    e2e_base=$(grep -A1 'key = "SW_E2E_BASE"' \
        schreibwerkstatt-focuseditor.xcodeproj/xcshareddata/xcschemes/schreibwerkstatt-focuseditor.xcscheme \
        | sed -n 's/.*value = "\(.*\)".*/\1/p')
    if [[ -n "$e2e_base" ]] && ! curl -s -o /dev/null --max-time 3 "$e2e_base/config"; then
        skip_args=(-skip-testing:schreibwerkstatt-focuseditorTests/SyncIntegrationTests)
        add "Integrationstests übersprungen ($e2e_base nicht erreichbar)"
    fi
    if xcodebuild test -project schreibwerkstatt-focuseditor.xcodeproj \
        -scheme schreibwerkstatt-focuseditor -destination 'platform=macOS' \
        ${skip_args[@]+"${skip_args[@]}"} -quiet >"$TEST_LOG" 2>&1; then
        add "Tests grün"
    else
        ok=0
        add "Tests/Build fehlgeschlagen ($TEST_LOG)"
    fi
fi

if (( run_mas )); then
    if xcodebuild -project schreibwerkstatt-focuseditor.xcodeproj \
        -scheme Focuseditor-MAS -configuration Release \
        -derivedDataPath build/mas-hook build -quiet >"$MAS_LOG" 2>&1; then
        add "App-Store-Target baut"
    else
        ok=0
        add "App-Store-Target bricht ($MAS_LOG)"
    fi
fi

if (( ok )); then
    icon="✅"
else
    icon="❌"
fi

# JSON-sicher zusammensetzen (Pfade/Meldungen enthalten keine Anführungszeichen,
# aber jq ist ohnehin schon Hook-Voraussetzung).
if command -v jq >/dev/null 2>&1; then
    jq -cn --arg msg "$icon schreibwerkstatt-focuseditor: $summary" '{systemMessage: $msg}'
else
    printf '{"systemMessage":"%s schreibwerkstatt-focuseditor: %s"}\n' "$icon" "$summary"
fi
exit 0
