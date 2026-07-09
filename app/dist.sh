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

# Ad-hoc sign — required just for the binary to run on Apple Silicon (no Apple Developer
# account needed); --deep also covers the CEF framework and the four helper apps. It runs on
# any Mac once the download quarantine is cleared (see the xattr line dist prints at the end).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Install to /Applications for everyday use — replace any previous install in place.
DEST="/Applications/$NAME.app"
rm -rf "$DEST"
ditto "$APP" "$DEST"

# Shareable archive for teammates — no signature required. ditto -c -k --keepParent makes a
# proper macOS zip that preserves the bundle. Recipients clear the one-time download
# quarantine with the printed xattr command, then it opens like any app.
ZIP="build/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Installed $DEST  (v$SYNTH_SHORT_VERSION build $SYNTH_BUILD_VERSION)"
echo "Launch locally with:  open -a \"$NAME\""
echo
echo "Share with a teammate — send:  $(pwd)/$ZIP"
echo "They unzip it, move $NAME.app into /Applications, then run once:"
echo "    xattr -dr com.apple.quarantine \"/Applications/$NAME.app\""
echo "…then open it normally. No signing or Apple account required."
