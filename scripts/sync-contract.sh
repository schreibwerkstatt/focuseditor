#!/usr/bin/env bash
# sync-contract.sh — Client-Vertrag des Servers nach contract/ übernehmen.
#
# Der Server führt den maschinenlesbaren Vertrag zwischen sich und den nativen
# Clients im Ordner contract/ seines Repos (README dort). Dieser Client zieht
# daraus eine eingecheckte Kopie (contract/ im Repo-Root), gegen die die
# Decoding-Tests laufen (ContractFixtureTests). Ein roter Test nach dem Sync
# heisst: der Server liefert etwas anders, als die App es liest — erst
# verstehen, dann die DTOs anpassen, nie die Fixtures von Hand.
#
# Kopiert werden version.json, openapi.json, CHANGELOG.md, editor-api.d.ts,
# editor-surface.json und fixtures/*.json. Alte Fixtures fliegen vorher raus,
# damit eine serverseitig entfernte Fixture hier nicht weiterlebt.
#
# Nutzung:
#   scripts/sync-contract.sh                  # aus ../schreibwerkstatt
#   SW_SERVER_REPO=/pfad/zum/server scripts/sync-contract.sh
#   scripts/sync-contract.sh --from-github    # flacher Klon von GitHub (main)
#
# Umgebungsvariablen:
#   SW_SERVER_REPO   Pfad zum Server-Repo; Default ../schreibwerkstatt
#                    (relativ zum Repo-Root dieses Clients)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITHUB_URL="https://github.com/schreibwerkstatt/schreibwerkstatt"
FILES="version.json openapi.json CHANGELOG.md editor-api.d.ts editor-surface.json"

TMP=""
cleanup() { [[ -n "$TMP" ]] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT

if [[ "${1:-}" == "--from-github" ]]; then
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/sw-contract.XXXXXX")"
  echo "Klone $GITHUB_URL (flach) …"
  git clone --quiet --depth 1 "$GITHUB_URL" "$TMP/server"
  SERVER="$TMP/server"
elif [[ -n "${1:-}" ]]; then
  echo "Unbekanntes Argument: $1 (erlaubt: --from-github)" >&2
  exit 2
else
  SERVER="${SW_SERVER_REPO:-$ROOT/../schreibwerkstatt}"
fi

SRC="$SERVER/contract"
if [[ ! -f "$SRC/version.json" ]]; then
  echo "Kein Vertrag gefunden unter $SRC (SW_SERVER_REPO setzen oder --from-github)." >&2
  exit 1
fi

DST="$ROOT/contract"
mkdir -p "$DST/fixtures"

for f in $FILES; do
  if [[ ! -f "$SRC/$f" ]]; then
    echo "Fehlt im Server-Vertrag: $f" >&2
    exit 1
  fi
  cp "$SRC/$f" "$DST/$f"
done

rm -f "$DST"/fixtures/*.json
count=0
for f in "$SRC"/fixtures/*.json; do
  [[ -e "$f" ]] || continue
  cp "$f" "$DST/fixtures/"
  count=$((count + 1))
done

commit="$(git -C "$SERVER" rev-parse --short HEAD 2>/dev/null || echo "?")"
version="$(tr -d '\n ' < "$DST/version.json")"
echo "Vertrag übernommen: $version · $count Fixtures · Server @ $commit"
echo "Nächster Schritt: ContractFixtureTests laufen lassen; CHANGELOG.md sagt, was zu tun ist."
