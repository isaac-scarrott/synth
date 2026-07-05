#!/bin/bash
# Fetch + stage the pinned CEF binary distro that Synth's embedded browser links against
# (ADR-0011 stage one). Mirrors the fetch-ghostty.sh pattern: pinned version + sha256,
# gitignored artifact, one-time native build step.
#
# Produces under vendor/cef/:
#   dist/                 include/, libcef_dll/, cmake/, CMakeLists.txt, Release/<framework>
#   libcef_dll_wrapper.a  static wrapper the app and helper link (built once via cmake)
#   .cef_stamp            pinned version marker
#
# A local cache (another worktree's already-extracted distro + prebuilt wrapper) is tried
# first to avoid the 253MB download; the official CDN is the fallback.
set -euo pipefail
cd "$(dirname "$0")"

CEF_VERSION="144.0.29+g0b1a012+chromium-144.0.7559.256"
CEF_DIST="cef_binary_${CEF_VERSION}_macosarm64"
EXPECT_SHA256="764e7282158eb879cd1358ec69935efc736e58abd6e6d7a1edc3ad3843c74f1a"
# '+' must be %2B-encoded for the CDN.
URL="https://cef-builds.spotifycdn.com/$(printf '%s' "${CEF_DIST}.tar.bz2" | sed 's/+/%2B/g')"
CACHE="${SYNTH_CEF_CACHE:-/Users/isaac/Library/Application Support/Synth/worktrees/synth-9feb4dee/browser-working/.worktree/browser-spike/spike/cef-attempt}"

# Only these distro pieces are needed to compile the shim, build the wrapper, and
# assemble the app bundle. Debug/ and tests/ stay out (saves ~700MB).
SUBSET=(include libcef_dll cmake CMakeLists.txt Release)

if [ "$(cat cef/.cef_stamp 2>/dev/null)" = "$CEF_VERSION" ] \
   && [ -f cef/libcef_dll_wrapper.a ] \
   && [ -d "cef/dist/Release/Chromium Embedded Framework.framework" ]; then
  echo "vendor/cef already staged for CEF $CEF_VERSION"
  exit 0
fi

rm -rf cef
mkdir -p cef/dist

stage_from_dir() {
  local src="$1"
  for item in "${SUBSET[@]}"; do
    [ -e "$src/$item" ] || return 1
  done
  for item in "${SUBSET[@]}"; do
    rsync -a "$src/$item" cef/dist/
  done
}

extract_tarball() {
  local tarball="$1"
  local actual
  actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  if [ "$actual" != "$EXPECT_SHA256" ]; then
    echo "checksum mismatch for $tarball" >&2
    echo "  expected: $EXPECT_SHA256" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
  local paths=()
  for item in "${SUBSET[@]}"; do paths+=("$CEF_DIST/$item"); done
  tar xjf "$tarball" -C cef "${paths[@]}"
  for item in "${SUBSET[@]}"; do mv "cef/$CEF_DIST/$item" cef/dist/; done
  rmdir "cef/$CEF_DIST"
}

if [ -d "$CACHE/$CEF_DIST" ] && stage_from_dir "$CACHE/$CEF_DIST"; then
  echo "Staged CEF distro from local cache $CACHE/$CEF_DIST"
elif [ -f "$CACHE/cef-std.tar.bz2" ] && extract_tarball "$CACHE/cef-std.tar.bz2"; then
  echo "Staged CEF distro from cached tarball"
else
  echo "Downloading $URL (253MB)..."
  curl --fail --show-error --location --connect-timeout 15 --max-time 1800 \
    -o cef/cef.tar.bz2 "$URL"
  extract_tarball cef/cef.tar.bz2
  rm -f cef/cef.tar.bz2
fi

# Wrapper archive: reuse the cache's prebuilt arm64 one when present, else a one-time
# cmake build (~2m, stock cmake + Xcode — proven in the spike).
CACHED_WRAPPER="$CACHE/$CEF_DIST/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
if [ -f "$CACHED_WRAPPER" ] && lipo -info "$CACHED_WRAPPER" 2>/dev/null | grep -q arm64; then
  cp "$CACHED_WRAPPER" cef/libcef_dll_wrapper.a
  echo "Copied prebuilt libcef_dll_wrapper.a from cache"
else
  echo "Building libcef_dll_wrapper (one-time)..."
  cmake -S cef/dist -B cef/dist/build -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64 >/dev/null
  cmake --build cef/dist/build --target libcef_dll_wrapper -j 8
  cp cef/dist/build/libcef_dll_wrapper/libcef_dll_wrapper.a cef/libcef_dll_wrapper.a
fi

echo "$CEF_VERSION" > cef/.cef_stamp
echo "Staged vendor/cef for CEF $CEF_VERSION"
