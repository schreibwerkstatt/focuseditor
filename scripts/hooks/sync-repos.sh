#!/bin/bash
# SessionStart-Hook: zieht beim Start jeder Claude-Session den neusten Stand
# dieses Repos UND des Mutterprojekts (entwickelt wird auf zwei Geräten).
# Nur Fast-Forward — lokale Commits/Änderungen werden nie überschrieben;
# was nicht gefahrlos geht, wird gemeldet statt erzwungen.
# Die Ausgabe landet als Kontext in der Session.

CLIENT_REPO="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
SERVER_REPO="${SW_SERVER_REPO:-/Users/bd/ClaudeProjects/schreibwerkstatt}"

# `timeout` fehlt auf macOS ohne coreutils — dann ohne Deckel (Hook-Timeout greift).
if command -v timeout >/dev/null; then TO="timeout 20"; else TO=""; fi

sync_repo() {
  local dir="$1" name="$2"
  [ -d "$dir/.git" ] || { echo "[$name] kein Git-Repo unter $dir — übersprungen"; return; }

  if ! $TO git -C "$dir" fetch --prune --quiet 2>/dev/null; then
    echo "[$name] fetch fehlgeschlagen (offline?) — Stand evtl. veraltet"
    return
  fi

  local branch upstream ahead behind
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  upstream=$(git -C "$dir" rev-parse --abbrev-ref '@{u}' 2>/dev/null) || {
    echo "[$name] Branch $branch hat keinen Upstream — nichts gepullt"; return; }
  read -r ahead behind < <(git -C "$dir" rev-list --left-right --count HEAD..."$upstream")

  if [ "$behind" -eq 0 ]; then
    echo "[$name] aktuell ($branch, ahead $ahead)"
  elif [ "$ahead" -gt 0 ]; then
    echo "[$name] DIVERGIERT: $ahead lokal / $behind remote auf $branch — bitte manuell rebasen/mergen"
  elif git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
    echo "[$name] $behind Commit(s) gepullt ($branch)"
  else
    echo "[$name] $behind Commit(s) remote, Pull blockiert (lokale Änderungen?) — bitte prüfen"
  fi
}

sync_repo "$CLIENT_REPO" "focuseditor"
sync_repo "$SERVER_REPO" "schreibwerkstatt"
exit 0
