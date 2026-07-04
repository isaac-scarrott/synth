#!/bin/bash
# Fast inner loop: kill the instance THIS script last launched, rebuild, relaunch.
# Tracks its own pid so it never touches another Synth (a bundled app, another agent's build).
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE=".build/dev.pid"
[ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true

swift build
BIN="$(swift build --show-bin-path)/Synth"
"$BIN" & echo $! > "$PIDFILE"
echo "Synth running (pid $(cat "$PIDFILE")). Re-run ./dev.sh to rebuild + relaunch."
