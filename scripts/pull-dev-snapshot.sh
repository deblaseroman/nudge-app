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
for r in d.get("result", {}).get("devices", []):
    props = r.get("deviceProperties", {}); hw = r.get("hardwareProperties", {})
    if hw.get("deviceType") == "iPhone" or "iPhone" in (props.get("name", "") + hw.get("marketingName", "")):
        print(r["identifier"]); break
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
