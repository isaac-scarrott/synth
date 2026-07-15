# Driving & verifying the native app

The only proof a change works is a screenshot / captured output of the **running** app. Tests and
`swift build` are necessary but not sufficient — drive the actual flow.

## Screenshot your own instance

Two ways to capture. Reach for the in-process one first — it's the only one that survives this
machine's realities: several Synth instances at once, a tiling window manager (aerospace) that parks
each window on its own Space, and permission popups that won't be granted. Never `pkill Synth`; kill
only your own PID.

### Preferred: let the app screenshot itself (WM-agnostic, no permission prompt)

`automation.screenshot` renders the visible window's `contentView` via `cacheDisplay` from *inside*
the app process, so it captures the exact SwiftUI hierarchy regardless of Space, occlusion, or
display — and raises no screen-recording prompt. Launch with automation on, then ask over the socket:

```bash
SYNTH_AUTOMATION=1 nohup .build/debug/Synth >/tmp/s.log 2>&1 & disown; MYPID=$!; sleep 4
# EVERY automation verb needs a worktreePath that maps to a live branch. Grab one from the
# worktreeURL in Application Support/Synth/state.json (or your SYNTH_STATE_DIR seed).
printf '%s' '{"verb":"automation.screenshot","worktreePath":"<a branch worktree>","path":"/tmp/shot.png"}' \
  | nc -U /tmp/synth-ctl-$MYPID.sock   # → {"ok":true,...}; read /tmp/shot.png
```

Hover / selection / open-session chrome can't be produced by a real mouse on an inactive window —
drive the store first, then screenshot: `automation.jump` opens a session so its full-width tint
shows; `automation.nav` reports the tree so you know what to jump to. Kill your PID when done.

### Fallback: capture the window buffer by ID

`scripts/capture.sh` (set `APP_DIR`) builds, launches your instance, screenshots its CGWindowID, and
leaves it running; re-capture with `screencapture -x -o -l<WINID> <out.png>` (WINID from
`swift scripts/findwin.swift <PID>`). This only works when the window is on the **active** Space —
under a tiling WM it usually isn't, so you get `could not create image from window` (and a full-display
`screencapture` shows only the desktop). ScreenCaptureKit from an ad-hoc script hits a TCC prompt, and
activating the app can't pull the window across Spaces (the debug binary has no bundle id). If by-ID
capture fails, don't fight it — use the in-process path above.

## Drive it by keyboard (no focus, no lock-screen dependency)

`osascript … frontmost` targets the *wrong* same-named process and its clicks/keys can leak into
another agent's app. Instead post CGEvents straight to your PID — reliable regardless of focus:

```bash
D="$APP_DIR/../.claude/skills/port-working-html/scripts/drive.swift"
swift "$D" <PID> key 40 cmd     # ⌘K (command palette)
swift "$D" <PID> key 125        # ↓   (nav down; also 126 ↑, 124 →, 123 ←)
swift "$D" <PID> type feat/x    # type into a focused field
swift "$D" <PID> key 36         # Return   (53 Esc, 49 Space, 51 Delete)
```

Mouse clicks do **not** land on inactive windows — drive the keyboard-first UI (global nav, ⌘K
palette, sheets) by keys. The hover-reveal kebab is `pointer-events:none` until hovered, which
osascript/clicks can't do; to verify a hover/menu-only state, set the store state in code
(e.g. `activeMenu = …`), screenshot, then revert.

## Headless driving over the control socket

The socket is the reliable way to drive *and* observe here — it doesn't care about Spaces, focus, or
TCC, so it's the natural pair to the in-process screenshot above (and the only option when CGEvent
posting and `screencapture -l` are both blocked). Talk to `/tmp/synth-ctl-<pid>.sock`, one JSON line
in/out. Seed an isolated state so you never touch the user's real data:

```bash
# isolated instance — never touches the user's real state
mkdir -p "$STATE" && cat > "$STATE/state.json" <<< '{"version":1,"workspaces":[…seed…],"expanded":[…]}'
SYNTH_STATE_DIR="$STATE" SYNTH_AUTOMATION=1 .build/debug/Synth &
echo '{"verb":"automation.nav","worktreePath":"…"}' | nc -U /tmp/synth-ctl-<pid>.sock
```

- `automation.nav` → rows (incl. `unread`)/status/cursor/open session; `automation.notifs` →
  the toast deck + `active`; `automation.newClaude` opens-and-selects a session (headless way
  to background the previous one) while `browser.create` is deliberately quiet — unread row, no
  focus change, engine booted detached; `automation.jump` selects a row; `automation.requestDelete`
  + `paletteEnter` drive the delete flow. Global `claudeFlags` in the seeded state control what a
  spawned claude runs (`--help` exits 0 in ~2s; a bogus flag exits 1; omit the key for interactive
  claude that stays alive) — the headless stand-in for typing into a PTY.
- In-app toasts only raise while `NSApp.isActive`; activate your instance with
  `osascript -e 'tell application "System Events" to set frontmost of (first process whose
  unix id is <pid>) to true'` (NSRunningApplication.activate is refused on macOS 14+).
  Focus is contested on this machine — check `active` in `automation.notifs` at the moment
  that matters.
- **Exit codes never ride the PTY**: libghostty wraps children in `/usr/bin/login`, which
  exits 0 regardless. The true code arrives over the hook socket (zshexit hook / claude
  shim) — test that seam directly with a `nc -lU` listener (socket path must be short:
  /tmp, not the scratchpad).

## Gotchas
- **Trust only `swift build`.** SourceKit reports phantom "Cannot find type/module 'X'" across files
  and a false `@main` error — ignore them. Grep the build for `error:` / `Build complete`.
- **A fresh worktree won't link.** `git worktree add` doesn't carry gitignored artifacts, so the
  vendored `app/vendor/GhosttyKit.xcframework` (~538MB, fetched by `vendor/fetch-ghostty.sh`) is
  missing: the code compiles but the link fails with `library '…/ghostty-internal.a' not found`.
  Symlink it from a sibling worktree that already has it (same pinned SHA) rather than re-fetching:
  `ln -s <other-worktree>/app/vendor/GhosttyKit.xcframework app/vendor/`.
- **NSOpenPanel** (the add-workspace folder picker) is an out-of-process XPC window: the PID→window
  screenshot can't see it, and it can't be driven while the screen is locked. Verify it with a
  full-screen `screencapture` when the screen is unlocked, or note it as visually unverified.
- **Toolchain:** `swift-tools-version:5.10` (Swift 5 mode) — keep it; Swift 6 strict concurrency
  breaks the SwiftTerm delegate conformances. SwiftTerm is fetched via SPM (needs network on first build).
- **Compare side by side:** serve the spec with `python3 -m http.server 8912` at the repo root and open
  `http://localhost:8912/working.html` (claude-in-chrome) next to your screenshot.
- **`.build/` is gitignored** — screenshots and scratch files there are throwaway.
