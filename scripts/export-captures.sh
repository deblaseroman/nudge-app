#!/bin/zsh
# Export Roman's real capture history from the phone as an eval draft.
# Launches the installed DEBUG build with -nudge-export-captures (the app
# writes Documents/cases.draft.json + cases.draft.meta.json and exits),
# pulls both files, copies the draft to eval/cases.draft.json, prints counts.
# Phone connected (cable or wireless), unlocked, trusted; DEBUG build on it.
#   usage: scripts/export-captures.sh
set -u
cd "$(dirname "$0")/.." || exit 1
OUT="${TMPDIR:-/tmp}/nudge-dev-notes"
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
[ -n "$DEV" ] || { echo "No paired iPhone found. Connect it, unlock it, and trust this Mac." >&2; exit 1; }

echo "launching Nudge on the phone with -nudge-export-captures…"
xcrun devicectl device process launch --device "$DEV" --terminate-existing --console \
  com.deblaser.nudge -- -nudge-export-captures > "$OUT/export.log" 2>&1
grep -E "^EXPORT " "$OUT/export.log" || true

pull() {
  xcrun devicectl device copy from --device "$DEV" \
    --domain-type appDataContainer --domain-identifier com.deblaser.nudge \
    --source "Documents/$1" --destination "$OUT/$1" --quiet 2>"$OUT/copy.err"
}
if ! pull cases.draft.meta.json; then
  echo "no draft on the phone: is the DEBUG build with the exporter installed? ($OUT/copy.err)" >&2
  exit 1
fi
python3 - "$OUT/cases.draft.meta.json" <<'PY' || exit 1
import json, sys, datetime
m = json.load(open(sys.argv[1]))
written = datetime.datetime.fromisoformat(m["writtenAt"].replace("Z", "+00:00"))
age = (datetime.datetime.now(datetime.timezone.utc) - written).total_seconds()
if age > 300:
    print(f"the draft on the phone is {int(age/60)} min old; the launch did not write a fresh one", file=sys.stderr); sys.exit(1)
print(f"captures {m['captures']} over {m['days']} days ({m['logged']} from the log), swallowed {m['swallowed']}, plan-intent {m['planIntent']}, ambiguous days {m['ambiguousDays']}, cases {m['cases']}")
PY
pull cases.draft.json || { cat "$OUT/copy.err" >&2; exit 1; }
cp "$OUT/cases.draft.json" eval/cases.draft.json
echo "draft at eval/cases.draft.json (git-ignored)"
