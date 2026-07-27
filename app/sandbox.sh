#!/bin/bash
# A disposable Synth for testing Archive by hand.
#
# Everything this launches lives under ONE directory ($SANDBOX). `SYNTH_SUPPORT_DIR` overrides
# the app's whole Application Support root, so its state, worktrees, instance registry, browser
# profile and MCP install are all in there — your real Synth (and your real Synth Dev) can't be
# touched, and `./sandbox.sh --reset` is a complete uninstall.
#
# The clocks are compressed so a background clean-up you'd normally wait a week for happens
# while you watch. See docs/archive-sandbox.md for what to actually do once it's up.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

SANDBOX="${SYNTH_SANDBOX_DIR:-/tmp/synth-archive-sandbox}"
SUPPORT="$SANDBOX/support"
NAME="Synth Sandbox"
# The `.dev` suffix is load-bearing: `isDevChannel` keys off it, which keeps analytics silent
# and Sparkle out of the picture. The distinct CFBundleName is what isolates the state.
BID="io.github.isaac-scarrott.synth.sandbox.dev"
ICON="icon/AppIcon-Dev.icns"

if [ "${1:-}" = "--reset" ]; then
  pkill -f "$SANDBOX" 2>/dev/null || true
  # A locked worktree refuses to go quietly.
  find "$SUPPORT/worktrees" -maxdepth 3 -name ".git" 2>/dev/null >/dev/null || true
  rm -rf "$SANDBOX"
  echo "sandbox removed: $SANDBOX"
  exit 0
fi

export SYNTH_SHORT_VERSION="$(cat VERSION)-sandbox"
export SYNTH_BUILD_VERSION="1"
export SYNTH_BUNDLE_ID="$BID"

if [ -f vendor/cef/libcef_dll_wrapper.a ] && [ -f vendor/cef/dist/include/cef_version.h ]; then
  HAS_CEF=true
else
  HAS_CEF=false
fi

swift build
BIN="$(swift build --show-bin-path)"
APP="$BIN/$NAME.app"
mkdir -p "$APP/Contents/MacOS"
cp -cf "$BIN/Synth" "$APP/Contents/MacOS/Synth" 2>/dev/null || cp -f "$BIN/Synth" "$APP/Contents/MacOS/Synth"
cp -cf "$BIN/synth-hook" "$APP/Contents/MacOS/synth-hook" 2>/dev/null || cp -f "$BIN/synth-hook" "$APP/Contents/MacOS/synth-hook"
write_info_plist "$APP" "$NAME" "$BID"
$HAS_CEF && ./vendor/bundle-cef.sh "$APP" "$BIN" symlink
stage_resources "$APP" "$BIN" "$ICON"
stage_sparkle "$APP" "$BIN" symlink

# Fixtures: a repo with a real bare origin, and one worktree per hazard. Rebuilt every launch
# so a run that swept something still starts from a known tree next time.
pkill -f "$APP/Contents/MacOS/Synth" 2>/dev/null || true
sleep 0.5
rm -rf "$SUPPORT/worktrees" "$SUPPORT/state.json"
mkdir -p "$SUPPORT"
python3 - "$SANDBOX" "$SUPPORT" <<'PY'
import json, pathlib, sys
sys.path.insert(0, "harness/agents")
import archive_fixture as fx

sandbox, support = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
repo, made = fx.build(sandbox / "repos", support)
(support / "state.json").write_text(json.dumps(fx.state(repo, made), indent=2))

print(f"\n  repo:      {repo}")
print(f"  worktrees: {support / 'worktrees'}\n")
print("  scenario                 what the sweeper must decide")
print("  " + "-" * 62)
for name, expect in fx.EXPECTED.items():
    print(f"  {name:<24} {'RECLAIM' if expect is None else 'keep — ' + expect}")
PY

cat <<EOF

  Clocks (compressed — real defaults are 7 days / 14 days / 300s):
    grace        0s   archived rows are eligible immediately
    eval gap     0s   but still need TWO sweeps, one tick apart
    tick        60s   a sweep runs every minute
    hold       600s   a reclaimed folder sits aside 10 min before real deletion

  Launching "$NAME" — quit it like any app; ./sandbox.sh --reset removes everything.

EOF

# `nohup` + `disown`, not a bare `&`: the app must outlive this script. Launched from a tool
# or a CI shell, a bare background child dies with its parent's process group the moment the
# script returns — which looks exactly like "the sandbox crashed on launch".
SYNTH_SUPPORT_DIR="$SUPPORT" \
SYNTH_ARCHIVE_GRACE_SECONDS=0 \
SYNTH_ARCHIVE_EVAL_GAP_SECONDS=0 \
SYNTH_ARCHIVE_TICK_SECONDS=60 \
SYNTH_ARCHIVE_HOLD_SECONDS=600 \
  nohup "$APP/Contents/MacOS/Synth" \
    -synth-archive-sweep '<true/>' \
    -synth-archive-grace-days '<integer>7</integer>' \
    -synth-archive-dry-run '<false/>' \
    </dev/null >"$SANDBOX/synth.log" 2>&1 &
PID=$!
disown $PID 2>/dev/null || true

echo "  pid $PID — log: $SANDBOX/synth.log"
