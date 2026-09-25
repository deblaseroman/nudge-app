#!/bin/zsh
# Pull Roman's in-app dev notes off a connected iPhone (DEBUG build of
# Nudge) and print them. Phone must be plugged in, unlocked once, and
# trusted for development. Copies Documents/DevNotes.md from the app's
# data container via Xcode's devicectl; nothing else is touched.
#   usage: scripts/pull-dev-notes.sh [output-dir]
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
    props = r.get("deviceProperties", {})
    hw = r.get("hardwareProperties", {})
    is_phone = hw.get("deviceType") == "iPhone" or "iPhone" in (props.get("name", "") + hw.get("marketingName", ""))
    # Prefer a phone that is actually connected right now; a registered but
    # unplugged phone (a tester's) must not win by list order.
    state = (r.get("connectionProperties", {}) or {}).get("tunnelState", "") or ""
    if is_phone and state.lower() == "connected":
        print(r["identifier"]); break
else:
    for r in d.get("result", {}).get("devices", []):
        props = r.get("deviceProperties", {}); hw = r.get("hardwareProperties", {})
        if hw.get("deviceType") == "iPhone" or "iPhone" in (props.get("name", "") + hw.get("marketingName", "")):
            print(r["identifier"]); break
PY
)
if [ -z "$DEV" ]; then echo "No paired iPhone found. Plug it in, unlock it, and trust this Mac." >&2; exit 1; fi
if xcrun devicectl device copy from --device "$DEV" \
     --domain-type appDataContainer --domain-identifier com.deblaser.nudge \
     --source Documents/DevNotes.md --destination "$OUT/DevNotes.md" --quiet 2>"$OUT/copy.err"; then
  echo "Pulled to $OUT/DevNotes.md"
  echo "-----"
  cat "$OUT/DevNotes.md"
else
  if grep -q "error 7000" "$OUT/copy.err"; then
    echo "Connected to the phone, but there is no notes file yet: nothing has been written on the Dev notes page, or the build on the phone predates it." >&2
  else
    cat "$OUT/copy.err" >&2
  fi
  exit 1
fi
