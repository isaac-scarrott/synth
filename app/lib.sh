#!/bin/bash
# Shared bundle assembly for the Synth build channels. Sourced by dev.sh (the
# development build, "Synth Dev") and dist.sh (the stable build, "Synth"); each sets
# its own channel identity + version and orchestrates its own build and launch/install.
# Not meant to be run directly.

# Synth's source repo is private, and Sparkle fetches the appcast and the zips with no
# credentials — a private repo's release assets 404 for it. So the artifacts live in a public
# Tigris bucket (Fly.io's object storage, `flyctl storage`) and the source stays where it is.
# One flat, stable prefix serves every version, which is what lets the appcast name an old
# release's zip and still have it resolve years later.
#
# dist.sh bakes FEED_URL into every stable build and release.sh publishes to it; they read both
# from here, because an app polling an address nothing publishes to fails silently and forever.
RELEASE_BUCKET="${SYNTH_RELEASE_BUCKET:-synth-releases}"
RELEASE_BASE_URL="https://$RELEASE_BUCKET.fly.storage.tigris.dev"
FEED_URL="$RELEASE_BASE_URL/appcast.xml"
TIGRIS_ENDPOINT="https://fly.storage.tigris.dev"

# write_info_plist <app_dir> <display_name> <bundle_id>
# Version strings come from $SYNTH_SHORT_VERSION / $SYNTH_BUILD_VERSION (channel-stamped).
# CFBundleName is what AppSupport keys the Application Support sandbox off, so the two
# channels never share state. The Sparkle keys are written only when both $SYNTH_FEED_URL and
# $SYNTH_ED_PUBLIC_KEY are set — Updates.swift treats their absence as "this build does not
# update itself", which is what keeps the dev channel off the appcast.
write_info_plist() {
  local app="$1" name="$2" bid="$3"
  local sparkle=""
  if [ -n "${SYNTH_FEED_URL:-}" ] && [ -n "${SYNTH_ED_PUBLIC_KEY:-}" ]; then
    # SUEnableAutomaticChecks: check on our own, no first-run "do you want updates?" prompt.
    # SUAutomaticallyUpdate: once a check finds a newer build, download it silently in the
    # background and only then surface a "ready to install — relaunch now?" prompt. The user is
    # never asked to start a download, only to accept a restart; ignore it and Sparkle installs
    # on the next quit.
    sparkle="  <key>SUFeedURL</key><string>${SYNTH_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SYNTH_ED_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>"
  fi
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
${sparkle}
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

# stage_sparkle <app_dir> <bin_dir> <copy|symlink>
# `swift build` drops Sparkle.framework in the bin dir but sets no rpath; Package.swift adds
# @executable_path/../Frameworks, so the framework has to land there or the app won't launch —
# on both channels, since the dev build links Sparkle even though it never checks for updates.
# XPCServices exist only to let sandboxed apps install updates, and Synth is not sandboxed:
# dropping them is two fewer nested binaries to sign and notarize.
stage_sparkle() {
  local app="$1" bin="$2" mode="$3"
  local src="$bin/Sparkle.framework" dst="$app/Contents/Frameworks/Sparkle.framework"
  [ -d "$src" ] || { echo "stage_sparkle: missing $src" >&2; return 1; }
  mkdir -p "$app/Contents/Frameworks"
  if [ "$mode" = "symlink" ]; then
    rm -rf "$dst"
    ln -sfn "$src" "$dst"
  else
    [ -L "$dst" ] && rm -f "$dst"
    rsync -a --delete "$src/" "$dst/"
    rm -rf "$dst/Versions/B/XPCServices"
  fi
}

# sign_app <app_dir> <identity>
# Signs inside-out, deepest nested code first, because codesign seals a container against the
# contents it finds at signing time. `--deep` cannot do this job: it applies one entitlement set
# to every nested binary, and CEF's helpers need JIT entitlements the main app should not carry.
# Pass "-" to sign ad-hoc — enough to run locally on Apple Silicon, never enough to notarize,
# so the hardened runtime and secure timestamp are skipped there.
sign_app() {
  local app="$1" id="$2"
  local sign=(codesign --force --sign "$id")
  [ "$id" = "-" ] || sign+=(--options runtime --timestamp)
  local fw="$app/Contents/Frameworks"

  # CEF: the dylibs the framework vends, then the framework whose seal covers them.
  local cef="$fw/Chromium Embedded Framework.framework"
  if [ -d "$cef" ]; then
    local lib
    for lib in "$cef/Libraries/"*.dylib; do
      [ -e "$lib" ] && "${sign[@]}" "$lib"
    done
    "${sign[@]}" "$cef"
  fi

  # Sparkle: Autoupdate and Updater.app are standalone Mach-Os that the framework's own
  # signature does not cover, and both run as separate processes during an install.
  if [ -d "$fw/Sparkle.framework" ]; then
    local versions="$fw/Sparkle.framework/Versions/B"
    [ -d "$versions/Updater.app" ] && "${sign[@]}" "$versions/Updater.app"
    [ -e "$versions/Autoupdate" ] && "${sign[@]}" "$versions/Autoupdate"
    "${sign[@]}" "$fw/Sparkle.framework"
  fi

  local helper
  for helper in "$fw/Synth Helper"*.app; do
    [ -d "$helper" ] && "${sign[@]}" --entitlements signing/Helper.entitlements "$helper"
  done

  # synth-hook is a second Mach-O in Contents/MacOS. Signing the bundle seals it as a resource
  # but never signs it, and notarization rejects any unsigned executable in the bundle.
  "${sign[@]}" "$app/Contents/MacOS/synth-hook"

  "${sign[@]}" --entitlements signing/Synth.entitlements "$app"
}

# signing_identity
# The Developer ID Application certificate to sign with: $SYNTH_SIGN_IDENTITY when set,
# otherwise the first one in the keychain, otherwise "-" for an ad-hoc signature.
signing_identity() {
  if [ -n "${SYNTH_SIGN_IDENTITY:-}" ]; then
    echo "$SYNTH_SIGN_IDENTITY"
    return
  fi
  local found
  found="$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  echo "${found:--}"
}
