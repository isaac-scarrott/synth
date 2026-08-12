#!/bin/bash
# Fetch the Bun runtime synth-md ships inside Synth.app (ADR-0016). Vendored rather than
# taken from the user's PATH for the reason the ADR gives: the TUI must run on a machine
# with no JS toolchain at all, and the version is load-bearing.
#
# Load-bearing how: OpenTUI highlights markdown through a tree-sitter worker, and that
# worker's message bridge is picked by `process.getBuiltinModule`. Bun gained that in 1.3.
# On an older Bun the bridge silently never registers — the worker starts, answers nothing,
# initialization times out after ten seconds, and every paragraph in the document renders
# BLANK while tables and code fences still draw. It fails as a styling bug, not a crash, so
# pin the version here and let the build fail loudly instead.
set -euo pipefail
cd "$(dirname "$0")"

BUN_VERSION="${SYNTH_BUN_VERSION:-1.3.14}"
# Synth ships arm64-only (app/vendor/fetch-cef.sh takes the macosarm64 CEF distro and
# dist.sh's `swift build` is host-arch), so one slice is the whole story here too. The
# layout stays per-arch keyed so adding x64 is this list plus a build-script line.
ARCHES="${SYNTH_BUN_ARCHES:-aarch64}"

for arch in $ARCHES; do
  dest="bun/$arch"
  if [ -x "$dest/bun" ] && [ "$("$dest/bun" --version 2>/dev/null)" = "$BUN_VERSION" ]; then
    continue
  fi
  echo "fetching bun $BUN_VERSION ($arch)"
  rm -rf "$dest" && mkdir -p "$dest"
  url="https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/bun-darwin-$arch.zip"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/bun.zip" "$url"
  unzip -q -o "$tmp/bun.zip" -d "$tmp"
  mv "$tmp/bun-darwin-$arch/bun" "$dest/bun"
  chmod +x "$dest/bun"
  rm -rf "$tmp"
done

# The host slice doubles as the toolchain `build.ts` and `bun test` run under, so a stale
# system Bun can never be what produced a shipped bundle.
host="$(uname -m)"
[ "$host" = "arm64" ] && host="aarch64"
if [ ! -x "bun/$host/bun" ]; then
  echo "fetch-bun.sh: no Bun slice for this host ($host); set SYNTH_BUN_ARCHES=$host" >&2
  exit 1
fi
echo "bun $BUN_VERSION ready: $(cd "bun/$host" && pwd)/bun"
