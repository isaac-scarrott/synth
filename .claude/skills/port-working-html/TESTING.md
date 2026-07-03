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
