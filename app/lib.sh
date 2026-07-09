#!/bin/bash
# Shared bundle assembly for the Synth build channels. Sourced by dev.sh (the
# development build, "Synth Dev") and dist.sh (the stable build, "Synth"); each sets
# its own channel identity + version and orchestrates its own build and launch/install.
# Not meant to be run directly.

# write_info_plist <app_dir> <display_name> <bundle_id>
# Version strings come from $SYNTH_SHORT_VERSION / $SYNTH_BUILD_VERSION (channel-stamped).
# CFBundleName is what AppSupport keys the Application Support sandbox off, so the two
# channels never share state.
write_info_plist() {
  local app="$1" name="$2" bid="$3"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundleDisplayName</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>${bid}</string>
  <key>CFBundleExecutable</key><string>Synth</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${SYNTH_BUILD_VERSION:-1}</string>
  <key>CFBundleShortVersionString</key><string>${SYNTH_SHORT_VERSION:-0.1}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
}

# stage_resources <app_dir> <bin_dir> <icon_icns>
# Channel icon + browser MCP sources (ADR-0011 stage two) + SwiftPM resource bundle
# (CommentOverlay.js, ADR-0011 stage three) into Contents/Resources. Idempotent — safe
# for dev.sh's in-place refresh and dist.sh's clean rebuild alike.
stage_resources() {
  local app="$1" bin="$2" icon="$3"
  mkdir -p "$app/Contents/Resources"
  cp "$icon" "$app/Contents/Resources/AppIcon.icns"
  rm -rf "$app/Contents/Resources/mcp"
  cp -R ../mcp "$app/Contents/Resources/mcp"
  if [ -d "$bin/Synth_Synth.bundle" ]; then
    rm -rf "$app/Contents/Resources/Synth_Synth.bundle"
    cp -R "$bin/Synth_Synth.bundle" "$app/Contents/Resources/Synth_Synth.bundle"
  fi
}
