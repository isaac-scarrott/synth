#!/bin/bash
# Assemble the CEF runtime into a Synth.app bundle: the Chromium framework plus the
# four helper apps CEF requires on macOS (one stub binary under four names). CEF can't
# run from a bare executable — the framework/helpers are resolved relative to the
# bundle (Contents/Frameworks). Shared by dev.sh (clone mode: APFS clonefile, so the 200MB
# framework is inside the bundle — which the sandbox requires — at no cost) and dist.sh
# (copy mode: a self-contained artifact that survives being moved off this machine).
set -euo pipefail

APP="$1"        # path to Synth.app
BIN="$2"        # swift build bin dir containing SynthBrowserHelper
MODE="${3:-copy}"  # copy | clone | symlink

# Helpers hang off the host app's bundle id, so the two channels' helpers stay distinct in
# Launch Services. CEFEngine finds them by path, never by id, so the suffix is free to vary.
BID="${SYNTH_BUNDLE_ID:?bundle-cef: SYNTH_BUNDLE_ID must be set by dev.sh/dist.sh}"

VENDOR="$(cd "$(dirname "$0")" && pwd)"
FW_SRC="$VENDOR/cef/dist/Release/Chromium Embedded Framework.framework"
[ -d "$FW_SRC" ] || { echo "bundle-cef: missing $FW_SRC — run vendor/fetch-cef.sh" >&2; exit 1; }
[ -x "$BIN/SynthBrowserHelper" ] || { echo "bundle-cef: $BIN/SynthBrowserHelper not built" >&2; exit 1; }

FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

FW_DST="$FRAMEWORKS/Chromium Embedded Framework.framework"
if [ "$MODE" = "symlink" ]; then
  rm -rf "$FW_DST"
  ln -sfn "$FW_SRC" "$FW_DST"
elif [ "$MODE" = "clone" ]; then
  # The framework has to be INSIDE the bundle, not symlinked to the checkout: with the
  # Chromium sandbox on (ADR-0011 stage five) a helper may not dlopen a framework that lives
  # outside the app it was launched from, and every helper dies with "file system sandbox
  # blocked open()". APFS clonefile makes that free — no bytes copied, no time — and it is
  # redone only when the framework itself is newer than the one staged.
  if [ -L "$FW_DST" ] || [ ! -d "$FW_DST" ] ||
     [ "$FW_SRC/Chromium Embedded Framework" -nt "$FW_DST/Chromium Embedded Framework" ]; then
    rm -rf "$FW_DST"
    cp -Rc "$FW_SRC" "$FW_DST" 2>/dev/null || rsync -a --delete "$FW_SRC/" "$FW_DST/"
  fi
else
  [ -L "$FW_DST" ] && rm -f "$FW_DST"
  rsync -a --delete "$FW_SRC/" "$FW_DST/"
fi

# Helper names + bundle-id suffixes follow CEF's required layout (cefsimple precedent):
# "<App> Helper.app", "<App> Helper (GPU).app", etc., siblings of the framework.
make_helper() {
  local name_suffix="$1" id_suffix="$2"
  local name="Synth Helper${name_suffix}"
  local helper_app="$FRAMEWORKS/${name}.app"
  mkdir -p "$helper_app/Contents/MacOS"
  cp -f "$BIN/SynthBrowserHelper" "$helper_app/Contents/MacOS/${name}"
  # MallocNanoZone=0 and LSUIElement mirror cefsimple's helper plist (nano-zone
  # crashes in Chromium child processes; helpers must never show in the Dock).
  cat > "$helper_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>${name}</string>
  <key>CFBundleExecutable</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>${BID}.helper${id_suffix}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${SYNTH_BUILD_VERSION:-1}</string>
  <key>CFBundleShortVersionString</key><string>${SYNTH_SHORT_VERSION:-0.1}</string>
  <key>LSEnvironment</key>
  <dict>
    <key>MallocNanoZone</key><string>0</string>
  </dict>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><string>1</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
}

make_helper ""            ""
make_helper " (GPU)"      ".gpu"
make_helper " (Renderer)" ".renderer"
make_helper " (Plugin)"   ".plugin"

echo "bundle-cef: CEF runtime staged into $APP ($MODE mode)"
