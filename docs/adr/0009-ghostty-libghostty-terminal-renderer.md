# The terminal is rendered by embedded Ghostty (libghostty), superseding SwiftTerm

Supersedes ADR-0006. Terminal fidelity is a first-class product concern, so the native app's terminal
is now rendered by **Ghostty's embedding library** (`GhosttyKit` / libghostty) rather than SwiftTerm.
libghostty brings a GPU (Metal) renderer, real CoreText font shaping (ligatures, powerline glyphs,
truecolor, emoji), and best-in-class VT compatibility — the things a serious dev terminal is judged
on — at the cost of a large C-ABI integration. ADR-0006 chose SwiftTerm for speed-to-working and
explicitly named libghostty as the eventual renderer; this is that swap.

**Ownership inverts.** SwiftTerm is a Swift emulator that Synth drove; libghostty is a whole terminal
*engine* that Synth hosts. libghostty owns the PTY/shell, VT parsing, font shaping, and the Metal
renderer — it draws into the view's `CAMetalLayer` on its own thread, driven by a CVDisplayLink keyed
to the display id. The Swift layer is deliberately thin, behind the same narrow seam ADR-0006 set up:
`GhosttySurfaceView` (an `NSView` that vends the Metal backing layer and forwards keyboard/mouse/IME/
scroll while keeping the surface sized in pixels), `GhosttyApp` (the process-wide `ghostty_app_t`,
runtime callbacks, and a coalesced wakeup→`ghostty_app_tick`), and `GhosttySurfaceContext` (ties a
surface back to its session for child-exit + clipboard). `TerminalManager` still owns the views keyed
by session id and remains the only place PTY lifecycle becomes a derived bus fact — the store,
sidebar, and session model were untouched, exactly as ADR-0006 predicted.

**Hooks (ADR-0008) are unchanged.** The Claude-detection env (`SYNTH_SESSION_ID`, socket path,
shim-first `PATH`) now reaches the shell via libghostty's `surface_config.env_vars` instead of
SwiftTerm's process environment. A Claude session is a native login shell that runs `claude` via
`initial_input`, so the shim intercepts it exactly as before. Verified end to end: a Claude session
launches through the shim and round-trips a `claude-start` signal back to the socket.

**Config is inline-only, never `~/.config/ghostty`.** libghostty is configured from an in-process
string (`ghostty_config_load_string`), so behaviour is deterministic and a tester's global ghostty
config can't perturb it — and, with the per-pid socket/shim from ADR-0008, parallel Synth instances
stay isolated. `term = xterm-256color` avoids depending on the ghostty terminfo being installed on the
host; colours and font match design.html's `.term` card.

**We link a prebuilt binary, and accept the risk.** `GhosttyKit.xcframework` (MIT, ~538 MB) is a
universal static-library build of libghostty, gitignored and fetched by `app/vendor/fetch-ghostty.sh`
(pinned by ghostty SHA + sha256; `dev.sh`/`build-app.sh` fetch it first). The prebuilt comes from the
cmux fork's GitHub release — the same project Synth's hook design is modelled on. The accepted risks:
it is an unaudited third-party binary running with full privileges (built with ghostty's crash-report
subsystem in a cmux namespace), and fresh checkouts/CI depend on that release staying hosted (the
checksum pin means it cannot silently change, and existing machines cache it). This is acceptable
because **we call only the standard upstream ghostty ABI — zero cmux fork-only symbols** — so lock-in
is minimal: migrating to a self-built *upstream* libghostty is a drop-in (rebuild the xcframework, swap
the file, keep the linker wiring; no Swift changes). The intended path is to self-build from upstream
before distributing to users; the prebuilt is the fast route while the integration matures.

**Linking mechanics.** `swift build` (the SwiftPM CLI, which Synth uses) cannot link a static-library
xcframework, so `Package.swift` vends the `GhosttyKit` Clang module from a small header target and
links the fat `.a` via an explicit `-Xlinker` path (ld selects the arch slice), plus the system
frameworks/libs libghostty's archive references. Recorded because a future reader would otherwise
expect a normal `.binaryTarget` and be puzzled by the header-target + `-Xlinker` shape.
