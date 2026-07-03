#!/usr/bin/env bash
# Build, launch YOUR OWN Synth instance, and screenshot its window buffer (works even
# when occluded by other agents' windows). Leaves the app RUNNING so you can drive it
# with drive.swift and re-capture. Kill ONLY the printed PID when done — never pkill.
#
# Usage: APP_DIR=/path/to/app scripts/capture.sh [out.png]
#        (defaults APP_DIR to $PWD, out to .build/shot.png)
# Prints: PID=<pid>  and  SHOT=<abs png path>
set -euo pipefail
APP_DIR="${APP_DIR:-$(pwd)}"
OUT="${1:-.build/shot.png}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

swift build 2>&1 | grep -E "error:|Build complete" || true
[ -x .build/debug/Synth ] || { echo "build produced no binary — fix errors above"; exit 1; }

nohup .build/debug/Synth >"/tmp/synth-mine-$$.log" 2>&1 & disown
MYPID=$!
sleep 3.5
WINID="$(swift "$SKILL_DIR/findwin.swift" "$MYPID" | head -1)"
[ -n "${WINID:-}" ] || { echo "no window for PID $MYPID (log: /tmp/synth-mine-$$.log)"; kill "$MYPID" 2>/dev/null; exit 1; }
screencapture -x -o -l"$WINID" "$OUT"

echo "PID=$MYPID"
echo "SHOT=$APP_DIR/$OUT"
echo "drive it:  swift $SKILL_DIR/drive.swift $MYPID key 40 cmd   # then re-run screencapture -x -o -l$WINID $OUT"
echo "done:      kill $MYPID"
