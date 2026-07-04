#!/bin/bash
# Fetch + verify the prebuilt GhosttyKit.xcframework that Synth's terminal links against.
# The framework is the Ghostty (MIT) embedding library, libghostty, built as a universal
# static-library xcframework. It's 538MB extracted, so it's gitignored and fetched here
# instead of committed. Pinned by ghostty SHA + sha256 so the artifact is reproducible.
set -euo pipefail
cd "$(dirname "$0")"

GHOSTTY_SHA="cc31d54eef285de2f73b17a2aeafc24904722131"
FLAVOR="crashsubdir-cmux-crash-v1"
EXPECT_SHA256="1925c83a0c25665f33f88bfc4d4dc351fa5ff1d538d035b530ed68f98864dacf"
TAG="xcframework-${GHOSTTY_SHA}-${FLAVOR}"
URL="https://github.com/manaflow-ai/ghostty/releases/download/${TAG}/GhosttyKit.xcframework.tar.gz"

if [ -d GhosttyKit.xcframework ] && [ "$(cat GhosttyKit.xcframework/.ghostty_sha 2>/dev/null)" = "$GHOSTTY_SHA" ]; then
  echo "GhosttyKit.xcframework already present for $GHOSTTY_SHA"
  exit 0
fi

echo "Fetching GhosttyKit.xcframework for ghostty ${GHOSTTY_SHA:0:12}..."
curl --fail --show-error --location --connect-timeout 15 --max-time 300 \
  -o GhosttyKit.xcframework.tar.gz "$URL"

ACTUAL_SHA256="$(shasum -a 256 GhosttyKit.xcframework.tar.gz | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECT_SHA256" ]; then
  echo "checksum mismatch" >&2
  echo "  expected: $EXPECT_SHA256" >&2
  echo "  actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

rm -rf GhosttyKit.xcframework
tar --no-same-owner -xzf GhosttyKit.xcframework.tar.gz
rm -f GhosttyKit.xcframework.tar.gz
test -d GhosttyKit.xcframework
echo "Verified + extracted vendor/GhosttyKit.xcframework"
