# Driving & verifying the native app

The only proof a change works is a screenshot / captured output of the **running** app. Tests and
`swift build` are necessary but not sufficient — drive the actual flow.

**Always launch with `SYNTH_AUTOMATION=1`.** This machine belongs to someone who is working on it
while you verify. A driven build takes no Dock icon, no ⌘Tab slot, no keyboard focus and no screen —
its window renders but is never visible, and Notification Center posts are recorded instead of
delivered. Everything below is addressed to that instance over its control socket, so nothing you do
appears on the desktop. Never `pkill Synth`; kill only your own PID.

## Screenshot your own instance

`automation.screenshot` renders the window's `contentView` via `cacheDisplay` from *inside* the app
process, so it captures the exact SwiftUI hierarchy regardless of Space, occlusion, display, or the
fact that nobody can see the window — and raises no screen-recording prompt:

```bash
SYNTH_AUTOMATION=1 nohup .build/debug/Synth >/tmp/s.log 2>&1 & disown; MYPID=$!; sleep 4
# EVERY automation verb needs a worktreePath that maps to a live branch. Grab one from the
# worktreeURL in Application Support/Synth/state.json (or your SYNTH_STATE_DIR seed).
printf '%s' '{"verb":"automation.screenshot","worktreePath":"<a branch worktree>","path":"/tmp/shot.png"}' \
  | nc -U /tmp/synth-ctl-$MYPID.sock   # → {"ok":true,...}; read /tmp/shot.png
```

`scripts/capture.sh` (set `APP_DIR`) is the same thing in one step: build, launch driven, screenshot,
and leave it running with its PID, socket and worktree path printed for the next verb.

Hover / selection / open-session chrome can't be produced by a real mouse on a window nobody is
looking at — drive the store first, then screenshot: `automation.jump` opens a session so its
full-width tint shows; `automation.nav` reports the tree so you know what to jump to. Kill your PID
when done.

There is no window-buffer path any more: `screencapture -l<WINID>` and ScreenCaptureKit want a window
on the active Space (which a tiling WM denies) plus a TCC grant that isn't coming, and a driven window
isn't on screen for them to find in the first place.

## Drive it by keyboard

`automation.key` posts the keystroke inside the app, addressed to its own window, so it lands whether
or not the app is frontmost — which it never is:

```bash
K() { printf '{"verb":"automation.key","worktreePath":"%s","keyCode":%s,"mods":%s,"chars":"%s"}\n' \
      "$WORKTREE" "$1" "${2:-[]}" "${3:-}" | nc -U "$SOCK"; }
K 40 '["cmd"]' k     # ⌘K (command palette)
K 125                # ↓   (nav down; also 126 ↑, 124 →, 123 ←)
K 36 '[]' $'\r'      # Return   (53 Esc, 49 Space, 51 Delete)
```

Type a string by sending its characters in turn (`keyCode` + `chars`), the way the gates do. Mouse
clicks have nowhere to land — drive the keyboard-first UI (global nav, ⌘K palette, sheets) by keys.
The hover-reveal kebab is `pointer-events:none` until hovered, which no synthetic click reproduces;
to verify a hover/menu-only state, set the store state in code (e.g. `activeMenu = …`), screenshot,
then revert.

## Headless driving over the control socket

The socket is the way to drive *and* observe here — it doesn't care about Spaces, focus, or TCC, and
it asks nothing of the desktop, which is why it pairs with the in-process screenshot above. Talk to
`/tmp/synth-ctl-<pid>.sock`, one JSON line in/out. Seed an isolated state so you never touch the
user's real data:

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
- Focus decides which notification surface a background transition takes, and a driven instance
  never has focus — so say what focus is rather than taking it: `automation.notifRoute`
  (`deck`|`nc`|`auto`) pins the branch, `automation.notifFocus` says focus came back so a transient
  card drains. `automation.notifs` reports the standing deck, plus `nc` — every Notification Center
  post the run would have made, recorded rather than fired at whoever is at the keyboard.
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
- **NSOpenPanel** (the add-workspace folder picker) is an out-of-process XPC window, so the in-process
  screenshot can't see it and no verb can drive it. Note it as visually unverified — the one way to
  photograph it is a full-screen capture of the user's own desktop, which isn't yours to take.
- **Toolchain:** `swift-tools-version:5.10` (Swift 5 mode) — keep it; Swift 6 strict concurrency
  breaks the SwiftTerm delegate conformances. SwiftTerm is fetched via SPM (needs network on first build).
- **Compare side by side:** serve the spec with `python3 -m http.server 8912` at the repo root and open
  `http://localhost:8912/working.html` (claude-in-chrome) next to your screenshot.
- **`.build/` is gitignored** — screenshots and scratch files there are throwaway.
