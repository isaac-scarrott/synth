#!/bin/bash
# Fast inner loop: rebuild and launch Synth, leaving any previous instance running
# so you can test one build while iterating on another. Pass --kill (-k) to first
# stop the instance THIS script last launched — a straight relaunch.
# Tracks its own pid so it never touches another Synth (a bundled app, another agent's build).
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE=".build/dev.pid"

KILL=false
case "${1:-}" in
  -k|--kill) KILL=true ;;
esac

if $KILL; then
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
fi

./vendor/fetch-ghostty.sh
swift build
BIN="$(swift build --show-bin-path)/Synth"
"$BIN" & echo $! > "$PIDFILE"
echo "Synth running (pid $(cat "$PIDFILE")). Re-run ./dev.sh to build + launch alongside; --kill to replace the last one."
