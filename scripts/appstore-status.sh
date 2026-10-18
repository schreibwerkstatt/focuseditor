#!/usr/bin/env bash
# appstore-status.sh — Versionsstand in App Store Connect live abfragen.
#
# Quelle für den Store-Stand (nicht im Repo von Hand gepflegt, das veraltet):
# Versionen, zugeordnete Builds, Zustand — und die zuletzt veröffentlichte
# Version als Bezug für die „Neue Funktionen“ in AppStore/whats-new.md.
#
# Nutzt den notarytool-API-Key aus scripts/release.env (Rolle „Developer“ —
# Versionen und Builds sind damit lesbar, Metadaten schreiben nicht).
#
# Nutzung:
#   scripts/appstore-status.sh          # die letzten 10 Versionen
#   LIMIT=30 scripts/appstore-status.sh
#
# Umgebungsvariablen:
#   ASC_APP_ID   numerische App-ID; unten vorbelegt (wie archive-mas.sh)
#   LIMIT        Anzahl Versionen, Default 10

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/scripts/release.env" ]] && source "$ROOT/scripts/release.env"

: "${NOTARY_KEY:?NOTARY_KEY fehlt (scripts/release.env)}"
: "${NOTARY_KEY_ID:?NOTARY_KEY_ID fehlt (scripts/release.env)}"
: "${NOTARY_ISSUER:?NOTARY_ISSUER fehlt (scripts/release.env)}"
export NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER
export ASC_APP_ID="${ASC_APP_ID:-6797073919}"
export LIMIT="${LIMIT:-10}"

python3 -I - <<'PY'
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request

def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")

# JWT (ES256) für die App-Store-Connect-API. openssl signiert DER — die API
# will r||s roh (je 32 Byte), darum hier umpacken.
key = os.path.expanduser(os.environ["NOTARY_KEY"])
now = int(time.time())
header = b64(json.dumps({"alg": "ES256", "kid": os.environ["NOTARY_KEY_ID"], "typ": "JWT"}).encode())
payload = b64(json.dumps({"iss": os.environ["NOTARY_ISSUER"], "iat": now, "exp": now + 600,
                          "aud": "appstoreconnect-v1"}).encode())
msg = header + b"." + payload
der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key],
                     input=msg, capture_output=True, check=True).stdout
i = 2 + (der[1] & 0x7F) if der[1] & 0x80 else 2
parts = []
for _ in range(2):
    assert der[i] == 2, "unerwartete DER-Signatur"
    n = der[i + 1]
    parts.append(der[i + 2:i + 2 + n].lstrip(b"\0").rjust(32, b"\0"))
    i += 2 + n
token = (msg + b"." + b64(parts[0] + parts[1])).decode()

url = (f"https://api.appstoreconnect.apple.com/v1/apps/{os.environ['ASC_APP_ID']}"
       f"/appStoreVersions?limit={os.environ['LIMIT']}&include=build")
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": "Bearer " + token})) as r:
        data = json.load(r)
except urllib.error.HTTPError as e:
    sys.exit(f"ASC-API: HTTP {e.code} — {e.read().decode(errors='replace')[:300]}")

builds = {b["id"]: b["attributes"].get("version", "?")
          for b in data.get("included", []) if b["type"] == "builds"}
latest = None
print(f"{'Version':<9} {'Build':<6} {'Zustand':<28} angelegt")
for v in data["data"]:
    a = v["attributes"]
    state = a.get("appVersionState") or a.get("appStoreState") or "?"
    rel = (v.get("relationships", {}).get("build", {}) or {}).get("data")
    build = builds.get(rel["id"], "?") if rel else "—"
    print(f"{a['versionString']:<9} {build:<6} {state:<28} {a.get('createdDate', '')[:10]}")
    # `appVersionState` (neu) meldet READY_FOR_DISTRIBUTION, das veraltete
    # `appStoreState` READY_FOR_SALE — beides heisst: im Store veröffentlicht.
    if latest is None and state in ("READY_FOR_DISTRIBUTION", "READY_FOR_SALE"):
        latest = a["versionString"]
print()
print(f"Zuletzt veröffentlicht: {latest or '—'}  (Bezug für „Neue Funktionen“ in AppStore/whats-new.md)")
PY
