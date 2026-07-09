#!/bin/bash
# Fast inner loop: rebuild, refresh the dev bundle, and launch Synth, leaving any
# previous instance running so you can test one build while iterating on another.
# Pass --kill (-k) to replace the instance THIS script last launched — the new one is brought
# up and confirmed live FIRST, and the old one is killed only as the last step, so a failed
# build or a crash-on-launch never leaves you with no running Synth.
# Pass --check to run the browser engine self-check (PASS/FAIL lines) instead of
# launching the UI.
# Tracks its own pid so it never touches another Synth (a bundled app, another agent's build).
#
# Launches a minimal .app bundle rather than the bare binary: CEF resolves its
# framework + helper apps relative to Contents/, so the bare binary has no browser.
# The 200MB framework is symlinked, binaries copied — a rebuild refresh is instant.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# Development channel identity — distinct name + bundle id + Application Support sandbox
# so a dev build installs and runs alongside the stable "Synth" without colliding.
NAME="Synth Dev"
BID="tech.holibob.synth.dev"
ICON="icon/AppIcon-Dev.icns"
SUPPORT="$HOME/Library/Application Support/$NAME"
export SYNTH_SHORT_VERSION="0.1-dev"
export SYNTH_BUILD_VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"

PIDFILE=".build/dev.pid"

KILL=false
CHECK=false
for arg in "$@"; do
  case "$arg" in
    -k|--kill) KILL=true ;;
    --check)   CHECK=true ;;
  esac
done

# Capture the instance --kill will replace, but DON'T kill it yet: a build failure or a
# crash-on-launch must never leave you with no Synth. It dies only at the very end, once the
# new one is confirmed live (see the launch step).
OLD_PID=""
if $KILL && [ -f "$PIDFILE" ]; then OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"; fi

./vendor/fetch-ghostty.sh
if ./vendor/fetch-cef.sh; then
  HAS_CEF=true
else
  echo "warning: CEF assets unavailable — building without the browser engine" >&2
  HAS_CEF=false
fi

swift build
BIN="$(swift build --show-bin-path)"

APP="$BIN/$NAME.app"
mkdir -p "$APP/Contents/MacOS"
# clonefile (APFS) makes the copy free; plain cp is the fallback.
cp -cf "$BIN/Synth" "$APP/Contents/MacOS/Synth" 2>/dev/null || cp -f "$BIN/Synth" "$APP/Contents/MacOS/Synth"
cp -cf "$BIN/synth-hook" "$APP/Contents/MacOS/synth-hook" 2>/dev/null || cp -f "$BIN/synth-hook" "$APP/Contents/MacOS/synth-hook"

write_info_plist "$APP" "$NAME" "$BID"

if $HAS_CEF; then
  ./vendor/bundle-cef.sh "$APP" "$BIN" symlink
fi

stage_resources "$APP" "$BIN" "$ICON"

if $CHECK; then
  exec env SYNTH_AUTOMATION=1 "$APP/Contents/MacOS/Synth" --browser-check
fi

# Launch the new instance and wait for it to actually boot before touching the old one. A live
# Synth advertises itself as instances/<pid>.json the moment it finishes starting up (see
# InstanceRegistry) — that file appearing is our "the new session exists" signal.
"$APP/Contents/MacOS/Synth" & NEW_PID=$!
echo "$NEW_PID" > "$PIDFILE"

INSTANCE_JSON="$SUPPORT/instances/$NEW_PID.json"
for _ in $(seq 1 100); do
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "error: new Synth (pid $NEW_PID) exited during launch — old instance left running" >&2
    exit 1
  fi
  [ -f "$INSTANCE_JSON" ] && break
  sleep 0.1
done
if [ ! -f "$INSTANCE_JSON" ]; then
  echo "error: new Synth (pid $NEW_PID) never advertised itself — old instance left running" >&2
  exit 1
fi
echo "Synth running (pid $NEW_PID)."

# Last step, and only now that the new session is confirmed live: retire the one it replaces.
if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$NEW_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
  kill "$OLD_PID" 2>/dev/null || true
  echo "replaced previous instance (pid $OLD_PID)."
else
  echo "Re-run ./dev.sh to build + launch alongside; --kill to replace the last one."
fi
