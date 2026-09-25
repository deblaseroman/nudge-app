#!/bin/zsh
# Pull the data snapshot written from the Dev notes page ("Write data
# snapshot") off a connected iPhone and print where it landed.
#   usage: scripts/pull-dev-snapshot.sh [output-dir]
set -u
OUT="${1:-${TMPDIR:-/tmp}/nudge-dev-notes}"
mkdir -p "$OUT"
LIST="$OUT/devices.json"
xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1 || true
DEV=$(python3 - "$LIST" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
phones = []
for r in d.get("result", {}).get("devices", []):
    props = r.get("deviceProperties", {}); hw = r.get("hardwareProperties", {})
    is_phone = hw.get("deviceType") == "iPhone" or "iPhone" in (props.get("name", "") + hw.get("marketingName", ""))
    # Prefer a phone that is actually connected right now; a registered but
    # unplugged phone (a tester's) must not win by list order.
    if not is_phone:
        continue
    conn = r.get("connectionProperties", {}) or {}
    # Rank by reachability, then by most recent connection. "unavailable"
    # is a phone that is not here at all (a tester's, unplugged); a
    # "disconnected" tunnel is still reachable over USB or the local
    # network and devicectl will bring it up.
    rank = {"connected": 0, "disconnected": 1}.get((conn.get("tunnelState") or "").lower(), 2)
    phones.append((rank, conn.get("lastConnectionDate") or "", r["identifier"]))
if phones:
    best_rank = min(p[0] for p in phones)
    same = sorted((p for p in phones if p[0] == best_rank), key=lambda p: p[1], reverse=True)
    print(same[0][2])
PY
)
if [ -z "$DEV" ]; then echo "No paired iPhone found. Plug it in, unlock it, and trust this Mac." >&2; exit 1; fi
if xcrun devicectl device copy from --device "$DEV" \
     --domain-type appDataContainer --domain-identifier com.deblaser.nudge \
     --source Documents/DataSnapshot.json --destination "$OUT/DataSnapshot.json" --quiet 2>"$OUT/copy.err"; then
  echo "Pulled to $OUT/DataSnapshot.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("written", d["writtenAt"], "rows", d["taskCount"])' "$OUT/DataSnapshot.json"
else
  if grep -q "error 7000" "$OUT/copy.err"; then
    echo "Connected, but no snapshot on the phone yet: open Settings → Dev notes and tap \"Write data snapshot\" first." >&2
  else
    cat "$OUT/copy.err" >&2
  fi
  exit 1
fi
