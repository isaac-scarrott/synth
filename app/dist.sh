#!/bin/bash
# Stable distribution build: a self-contained, double-clickable Synth.app, installed to
# /Applications for everyday use and staged at build/Synth.app for sharing with teammates
# (e.g. via a Homebrew cask). Bundles the `synth-hook` CLI next to the main executable in
# Contents/MacOS/ — the layout HookEnvironment expects, so Claude Code hook detection works
# from the installed app exactly as it does in dev.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# Stable channel identity — the plain "Synth" the whole team runs.
NAME="Synth"
BID="tech.holibob.synth"
ICON="icon/AppIcon.icns"
export SYNTH_SHORT_VERSION="0.1"
export SYNTH_BUILD_VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo 1)"

./vendor/fetch-ghostty.sh
if ./vendor/fetch-cef.sh; then
  HAS_CEF=true
else
  echo "warning: CEF assets unavailable — bundling without the browser engine" >&2
  HAS_CEF=false
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/Synth" "$APP/Contents/MacOS/Synth"
cp "$BIN/synth-hook" "$APP/Contents/MacOS/synth-hook"

write_info_plist "$APP" "$NAME" "$BID"

if $HAS_CEF; then
  ./vendor/bundle-cef.sh "$APP" "$BIN" copy
fi

stage_resources "$APP" "$BIN" "$ICON"

# Ad-hoc sign so the bundle runs without Gatekeeper nagging on this machine; --deep also
# covers the CEF framework and the four helper apps. (Ad-hoc signatures don't cross to
# other Macs — teammate distribution strips quarantine via the Homebrew cask instead.)
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Install to /Applications for everyday use — replace any previous install in place.
DEST="/Applications/$NAME.app"
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "Built + installed $DEST  (v$SYNTH_SHORT_VERSION build $SYNTH_BUILD_VERSION)"
echo "Shareable bundle staged at $(pwd)/$APP"
echo "Launch it with:  open -a \"$NAME\""
