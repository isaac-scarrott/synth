#!/bin/bash
# Assemble a double-clickable Synth.app from a release build. Bundles the `synth-hook`
# CLI next to the main executable in Contents/MacOS/ — the layout HookEnvironment expects,
# so Claude Code hook detection works from the bundled app exactly as it does in dev.
set -euo pipefail
cd "$(dirname "$0")"

./vendor/fetch-ghostty.sh
if ./vendor/fetch-cef.sh; then
  HAS_CEF=true
else
  echo "warning: CEF assets unavailable — bundling without the browser engine" >&2
  HAS_CEF=false
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/Synth.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/Synth" "$APP/Contents/MacOS/Synth"
cp "$BIN/synth-hook" "$APP/Contents/MacOS/synth-hook"

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
  ./vendor/bundle-cef.sh "$APP" "$BIN" copy
fi

# Ad-hoc sign so the bundled app runs without Gatekeeper nagging on this machine.
# --deep also covers the CEF framework and the four helper apps.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP  —  run it with:  open $(pwd)/$APP"
