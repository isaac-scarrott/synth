#!/bin/bash
# Build the app bundle the capture rig drives — and only build it.
#
# `app/dev.sh` ends by launching the bundle visibly and remembering its pid; a capture run
# wants the artifact, not that instance. It also builds to "Synth Dev.app", the same path the
# owner's own dev build runs from — and the teardown in capture.py matches on the executable
# path, so sharing that path would mean a capture run could kill the Synth its owner is
# working in. Hence a channel of its own: "Synth Capture.app", a path nothing else launches.
#
# CEF is not optional here: the browser scene has nothing to photograph without an engine.
set -euo pipefail
cd "$(dirname "$0")/../../app"
source ./lib.sh

NAME="Synth Capture"
BID="io.github.isaac-scarrott.synth.capture"
ICON="icon/AppIcon-Dev.icns"
export SYNTH_SHORT_VERSION="$(cat VERSION)"
export SYNTH_BUILD_VERSION="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
export SYNTH_BUNDLE_ID="$BID"

./vendor/fetch-ghostty.sh
./vendor/fetch-cef.sh || { echo "error: CEF assets unavailable — the browser scene cannot be captured" >&2; exit 1; }

swift build
BIN="$(swift build --show-bin-path)"
APP="$BIN/$NAME.app"

mkdir -p "$APP/Contents/MacOS"
cp -cf "$BIN/Synth" "$APP/Contents/MacOS/Synth" 2>/dev/null || cp -f "$BIN/Synth" "$APP/Contents/MacOS/Synth"
cp -cf "$BIN/synth-hook" "$APP/Contents/MacOS/synth-hook" 2>/dev/null || cp -f "$BIN/synth-hook" "$APP/Contents/MacOS/synth-hook"
write_info_plist "$APP" "$NAME" "$BID"
./vendor/bundle-cef.sh "$APP" "$BIN" clone
stage_resources "$APP" "$BIN" "$ICON"
stage_sparkle "$APP" "$BIN" symlink

echo "$APP"
