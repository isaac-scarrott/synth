#!/usr/bin/env bash
# Build, launch YOUR OWN Synth instance, and screenshot it — none of which the person at the
# keyboard sees. A driven build (SYNTH_AUTOMATION=1) takes no Dock icon, no ⌘Tab slot, no focus
# and no screen, and it renders its own window into the PNG from inside the process, so a
# verification run never lands in the middle of what someone else is doing. Leaves the app RUNNING
# so you can drive it over its control socket and re-capture. Kill ONLY the printed PID — never pkill.
#
# Usage: APP_DIR=/path/to/app scripts/capture.sh [out.png]
#        (defaults APP_DIR to $PWD, out to .build/shot.png)
#        SYNTH_STATE_DIR=<seed dir> drives seeded state instead of the user's own.
# Prints: PID=<pid>  SOCK=<control socket>  WORKTREE=<the path every verb is addressed to>
#         SHOT=<abs png path>
set -euo pipefail
APP_DIR="${APP_DIR:-$(pwd)}"
OUT="${1:-.build/shot.png}"
cd "$APP_DIR"
case "$OUT" in /*) SHOT="$OUT" ;; *) SHOT="$APP_DIR/$OUT" ;; esac
mkdir -p "$(dirname "$SHOT")"

swift build 2>&1 | grep -E "error:|Build complete" || true
[ -x .build/debug/Synth ] || { echo "build produced no binary — fix errors above"; exit 1; }

SYNTH_AUTOMATION=1 nohup .build/debug/Synth >"/tmp/synth-mine-$$.log" 2>&1 & disown
MYPID=$!
SOCK="/tmp/synth-ctl-$MYPID.sock"
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.2; done
[ -S "$SOCK" ] || { echo "no control socket for PID $MYPID (log: /tmp/synth-mine-$$.log)"; kill "$MYPID" 2>/dev/null; exit 1; }

# Every automation verb is addressed to a branch by its worktree path, so find one this instance
# actually manages (a bare binary keeps its state under the plain "Synth" support dir).
STATE_JSON="${SYNTH_STATE_DIR:-$HOME/Library/Application Support/Synth}/state.json"
WORKTREE="$(python3 - "$STATE_JSON" <<'PY'
import json, sys, urllib.parse
try: state = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for ws in state.get("workspaces", []):
    for br in ws.get("branches", []):
        url = br.get("worktreeURL") or ""
        if url.startswith("file://"):
            print(urllib.parse.unquote(url[7:]).rstrip("/")); sys.exit(0)
PY
)"
[ -n "$WORKTREE" ] || { echo "no branch in $STATE_JSON — seed SYNTH_STATE_DIR or add a workspace first"; kill "$MYPID" 2>/dev/null; exit 1; }

printf '{"verb":"automation.screenshot","worktreePath":"%s","path":"%s"}\n' "$WORKTREE" "$SHOT" \
  | nc -U "$SOCK"

echo "PID=$MYPID"
echo "SOCK=$SOCK"
echo "WORKTREE=$WORKTREE"
echo "SHOT=$SHOT"
echo "drive it:  printf '{\"verb\":\"automation.key\",\"worktreePath\":\"$WORKTREE\",\"keyCode\":40,\"mods\":[\"cmd\"],\"chars\":\"k\"}\n' | nc -U $SOCK   # ⌘K, then re-capture"
echo "done:      kill $MYPID"
