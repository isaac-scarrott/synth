# Driving & verifying the native app

The only proof a change works is a screenshot / captured output of the **running** app. Tests and
`swift build` are necessary but not sufficient — drive the actual flow.

## Screenshot your own instance (occlusion-proof, contested-machine-safe)

The machine runs several Synth instances at once. Never `pkill Synth` — it kills other agents' apps.
Capture *your* window by its CGWindowID so it works even when occluded:

```bash
APP_DIR=/Users/isaac/git/synth/app  # or .worktree/<slice>/app inside a slice worktree
"$APP_DIR/../.claude/skills/port-working-html/scripts/capture.sh"  # from repo; prints PID= and SHOT=
```

`capture.sh` builds, launches your instance, screenshots it, and **leaves it running** so you can
drive it and re-capture. Read the printed `SHOT=` path. When finished, `kill <PID>` — only that PID.

To re-capture after driving: `screencapture -x -o -l<WINID> <out.png>` (WINID from
`swift scripts/findwin.swift <PID>`).

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

## Headless driving when TCC blocks keys AND capture

On machines where CGEvent posting *and* `screencapture -l` are both TCC-denied, drive and
observe entirely over the control socket (`/tmp/synth-ctl-<pid>.sock`, one JSON line in/out):

```bash
# isolated instance — never touches the user's real state
mkdir -p "$STATE" && cat > "$STATE/state.json" <<< '{"version":1,"workspaces":[…seed…],"expanded":[…]}'
SYNTH_STATE_DIR="$STATE" SYNTH_AUTOMATION=1 .build/debug/Synth &
echo '{"verb":"automation.nav","worktreePath":"…"}' | nc -U /tmp/synth-ctl-<pid>.sock
```

- `automation.nav` → rows/status/cursor/open session; `automation.notifs` → the toast deck +
  `active`; `automation.newClaude` / `browser.create` open-and-select a session (the only
  headless way to background the previous one); `automation.requestDelete` + `paletteEnter`
  drive the delete flow. Global `claudeFlags` in the seeded state control what a spawned
  claude runs (`--help` exits 0 in ~2s; a bogus flag exits 1) — the headless stand-in for
  typing into a PTY.
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
- **NSOpenPanel** (the add-workspace folder picker) is an out-of-process XPC window: the PID→window
  screenshot can't see it, and it can't be driven while the screen is locked. Verify it with a
  full-screen `screencapture` when the screen is unlocked, or note it as visually unverified.
- **Toolchain:** `swift-tools-version:5.10` (Swift 5 mode) — keep it; Swift 6 strict concurrency
  breaks the SwiftTerm delegate conformances. SwiftTerm is fetched via SPM (needs network on first build).
- **Compare side by side:** serve the spec with `python3 -m http.server 8912` at the repo root and open
  `http://localhost:8912/working.html` (claude-in-chrome) next to your screenshot.
- **`.build/` is gitignored** — screenshots and scratch files there are throwaway.
