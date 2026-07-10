#!/bin/bash
# Fetch Sparkle's command-line tools (generate_keys, sign_update, generate_appcast, and the
# BinaryDelta engine generate_appcast shells out to). The Swift Package Manager artifact ships
# only Sparkle.framework, so release.sh has no way to build an appcast without these. Pinned by
# version + sha256 so a release is reproducible; gitignored, like the CEF and Ghostty artifacts.
set -euo pipefail
cd "$(dirname "$0")"

SPARKLE_VERSION="2.9.4"
EXPECT_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

if [ -x sparkle-tools/generate_appcast ] &&
   [ "$(cat sparkle-tools/.sparkle_version 2>/dev/null)" = "$SPARKLE_VERSION" ]; then
  exit 0
fi

echo "Fetching Sparkle ${SPARKLE_VERSION} command-line tools..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/sparkle.tar.xz" "$URL"

ACTUAL="$(shasum -a 256 "$TMP/sparkle.tar.xz" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECT_SHA256" ]; then
  echo "fetch-sparkle: sha256 mismatch (expected $EXPECT_SHA256, got $ACTUAL)" >&2
  exit 1
fi

rm -rf sparkle-tools
mkdir -p sparkle-tools
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP" ./bin
cp "$TMP/bin/generate_keys" "$TMP/bin/sign_update" "$TMP/bin/generate_appcast" \
   "$TMP/bin/BinaryDelta" sparkle-tools/
echo "$SPARKLE_VERSION" > sparkle-tools/.sparkle_version
echo "Sparkle tools staged at $(pwd)/sparkle-tools"
