#!/bin/bash
# Fast inner loop: rebuild, refresh the dev bundle, and launch Synth, leaving any
# previous instance running so you can test one build while iterating on another.
# Pass --kill (-k) to first stop the instance THIS script last launched.
# Pass --check to run the browser engine self-check (PASS/FAIL lines) instead of
# launching the UI.
# Tracks its own pid so it never touches another Synth (a bundled app, another agent's build).
#
# Launches a minimal .app bundle rather than the bare binary: CEF resolves its
# framework + helper apps relative to Contents/, so the bare binary has no browser.
# The 200MB framework is symlinked, binaries copied — a rebuild refresh is instant.
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE=".build/dev.pid"

KILL=false
CHECK=false
for arg in "$@"; do
  case "$arg" in
    -k|--kill) KILL=true ;;
    --check)   CHECK=true ;;
  esac
done

if $KILL; then
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
fi

./vendor/fetch-ghostty.sh
if ./vendor/fetch-cef.sh; then
  HAS_CEF=true
else
  echo "warning: CEF assets unavailable — building without the browser engine" >&2
  HAS_CEF=false
fi

swift build
BIN="$(swift build --show-bin-path)"

APP="$BIN/Synth.app"
mkdir -p "$APP/Contents/MacOS"
# clonefile (APFS) makes the copy free; plain cp is the fallback.
cp -cf "$BIN/Synth" "$APP/Contents/MacOS/Synth" 2>/dev/null || cp -f "$BIN/Synth" "$APP/Contents/MacOS/Synth"
cp -cf "$BIN/synth-hook" "$APP/Contents/MacOS/synth-hook" 2>/dev/null || cp -f "$BIN/synth-hook" "$APP/Contents/MacOS/synth-hook"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Synth</string>
  <key>CFBundleDisplayName</key><string>Synth</string>
  <key>CFBundleIdentifier</key><string>tech.holibob.synth</string>
  <key>CFBundleExecutable</key><string>Synth</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if $HAS_CEF; then
  ./vendor/bundle-cef.sh "$APP" "$BIN" symlink
fi

# The browser MCP server sources: the app installs them from Contents/Resources/mcp
# to ~/Library/Application Support/Synth/browser-mcp/ at launch (ADR-0011 stage two).
mkdir -p "$APP/Contents/Resources"
rm -rf "$APP/Contents/Resources/mcp"
cp -R ../mcp "$APP/Contents/Resources/mcp"

# SwiftPM resource bundle (CommentOverlay.js, ADR-0011 stage three): the app looks it
# up under Contents/Resources when running from a bundle.
if [ -d "$BIN/Synth_Synth.bundle" ]; then
  rm -rf "$APP/Contents/Resources/Synth_Synth.bundle"
  cp -R "$BIN/Synth_Synth.bundle" "$APP/Contents/Resources/Synth_Synth.bundle"
fi

if $CHECK; then
  exec env SYNTH_AUTOMATION=1 "$APP/Contents/MacOS/Synth" --browser-check
fi

"$APP/Contents/MacOS/Synth" & echo $! > "$PIDFILE"
echo "Synth running (pid $(cat "$PIDFILE")). Re-run ./dev.sh to build + launch alongside; --kill to replace the last one."
