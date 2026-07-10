#!/bin/bash
# Stable distribution build: a self-contained, double-clickable Synth.app, installed to
# /Applications for everyday use and staged at build/Synth.app for release.sh to notarize and
# publish. Bundles the `synth-hook` CLI next to the main executable in Contents/MacOS/ — the
# layout HookEnvironment expects, so Claude Code hook detection works from the installed app
# exactly as it does in dev.
#
# Set SYNTH_NO_INSTALL=1 to skip the /Applications install (release.sh does; it wants the
# artifact, not a new local install).
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# Stable channel identity — the plain "Synth" everyone runs.
NAME="Synth"
BID="io.github.isaac-scarrott.synth"
ICON="icon/AppIcon.icns"

# Sparkle orders releases by CFBundleVersion, so it must increase monotonically. A commit count
# does; the short hash this used to be does not, and Sparkle would have compared "a3f9c1" to
# "bc05d05" as text and offered the wrong build — or none.
export SYNTH_SHORT_VERSION="$(cat VERSION)"
export SYNTH_BUILD_VERSION="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# Both keys must be present for the app to grow an updater at all (see write_info_plist). The
# public half of the EdDSA pair is safe to commit; the private half lives in the login keychain,
# put there by `vendor/sparkle-tools/generate_keys`.
export SYNTH_FEED_URL="$FEED_URL"
if [ -f signing/ed25519-public.txt ]; then
  export SYNTH_ED_PUBLIC_KEY="$(cat signing/ed25519-public.txt)"
else
  echo "warning: signing/ed25519-public.txt missing — building without the updater" >&2
  echo "         create it with: ./vendor/fetch-sparkle.sh && ./vendor/sparkle-tools/generate_keys" >&2
fi

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

export SYNTH_BUNDLE_ID="$BID"
write_info_plist "$APP" "$NAME" "$BID"

if $HAS_CEF; then
  ./vendor/bundle-cef.sh "$APP" "$BIN" copy
fi

stage_resources "$APP" "$BIN" "$ICON"
stage_sparkle "$APP" "$BIN" copy

IDENTITY="$(signing_identity)"
sign_app "$APP" "$IDENTITY"
if [ "$IDENTITY" = "-" ]; then
  echo "warning: no Developer ID Application certificate found — signed ad-hoc." >&2
  echo "         This build runs locally but cannot be notarized or auto-updated." >&2
fi

if [ "${SYNTH_NO_INSTALL:-}" != "1" ]; then
  DEST="/Applications/$NAME.app"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo
  echo "Installed $DEST  (v$SYNTH_SHORT_VERSION build $SYNTH_BUILD_VERSION)"
  echo "Launch locally with:  open -a \"$NAME\""
fi

# ditto -c -k --keepParent makes a macOS zip that preserves the bundle and its signature.
ZIP="build/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo
echo "Staged $(pwd)/$ZIP  (signed by: $IDENTITY)"
echo "Publish it with:  ./release.sh"
