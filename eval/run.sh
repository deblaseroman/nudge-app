#!/bin/zsh
# Nudge eval runner. Builds the real Debug app for the iOS simulator, launches
# it with `-nudge-eval eval/cases.json`, and prints what the in-app harness
# (`Nudge/Services/EvalHarness.swift`) reports: one line per FAILING case,
# then a summary. Passing cases print nothing.
#
#   usage: eval/run.sh [--local-only] [--no-build] [--model <id>] [--cases <file>] [--fill]
#     --local-only   skip the capture cases (no API calls, no cost)
#     --no-build     reuse the last build in eval/.build
#     --model <id>   capture model for this run only (default: what the app uses)
#     --cases <file> run another case file (default eval/cases.json)
#     --fill         write each case back with `expected` set to what the app did,
#                    to <file>.filled.json; the input file is untouched
#
# Full simulator log (the app's own DEBUG chatter) goes to eval/.last-run.log.
set -u
cd "$(dirname "$0")/.." || exit 1

LOCAL=0
BUILD=1
MODEL=""
FILL=0
CASES="$PWD/eval/cases.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --local-only) LOCAL=1 ;;
    --no-build) BUILD=0 ;;
    --fill) FILL=1 ;;
    --model) shift; MODEL="${1:-}"; [ -n "$MODEL" ] || { echo "--model needs a model id" >&2; exit 2; } ;;
    --cases) shift; CASES="${1:-}"; [ -n "$CASES" ] || { echo "--cases needs a path" >&2; exit 2; }
             case "$CASES" in /*) ;; *) CASES="$PWD/$CASES" ;; esac ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

DD="$PWD/eval/.build"
LOG="$PWD/eval/.last-run.log"
BUILD_LOG="$PWD/eval/.build.log"
SIM_NAME="${NUDGE_EVAL_SIM:-iPhone 17}"
BUNDLE="com.deblaser.nudge"

[ -f "$CASES" ] || { echo "no case file at $CASES" >&2; exit 1; }
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CASES" 2>/dev/null \
  || { echo "eval/cases.json is not valid JSON" >&2; exit 1; }

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
d = json.load(sys.stdin)
for runtime, devs in d["devices"].items():
    for dev in devs:
        if dev.get("name") == name and dev.get("isAvailable", False):
            print(dev["udid"]); sys.exit(0)
' "$SIM_NAME")
[ -n "$UDID" ] || { echo "no available simulator named \"$SIM_NAME\" (set NUDGE_EVAL_SIM)" >&2; exit 1; }

if [ "$BUILD" = 1 ]; then
  echo "building Nudge (Debug, simulator)…"
  if ! xcodebuild -project Nudge.xcodeproj -scheme Nudge -configuration Debug \
       -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" \
       build -quiet > "$BUILD_LOG" 2>&1; then
    echo "build failed; see $BUILD_LOG" >&2
    grep -E "error:" "$BUILD_LOG" | head -20 >&2
    exit 1
  fi
fi

APP="$DD/Build/Products/Debug-iphonesimulator/Nudge.app"
[ -d "$APP" ] || { echo "no built app at $APP (run without --no-build)" >&2; exit 1; }

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP" || { echo "install failed" >&2; exit 1; }

ARGS=(-nudge-skip-onboarding -nudge-eval "$CASES")
[ "$LOCAL" = 1 ] && ARGS+=(-nudge-eval-local-only)
[ -n "$MODEL" ] && ARGS+=(-nudge-capture-model "$MODEL")
[ "$FILL" = 1 ] && ARGS+=(-nudge-eval-fill)

echo "running cases$([ "$LOCAL" = 1 ] && echo ' (local only)')$([ -n "$MODEL" ] && echo " (capture model $MODEL)")…"
xcrun simctl launch --console "$UDID" "$BUNDLE" "${ARGS[@]}" > "$LOG" 2>&1

grep -E "^EVAL " "$LOG" | sed -E 's/^EVAL //'
if ! grep -qE "^EVAL SUMMARY" "$LOG"; then
  echo "no summary line: the harness did not finish; see $LOG" >&2
  exit 1
fi
