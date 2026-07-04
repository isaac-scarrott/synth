# SwiftTerm as the terminal backend for the first cut

**Superseded by ADR-0009** — the terminal is now rendered by embedded Ghostty (libghostty). The seam
this ADR describes (`TerminalManager` + the supervisor as the only PTY→bus translators) is exactly
what made that swap land without touching the store, sidebar, or session model.

The vision (see the handoff) calls for libghostty as the eventual terminal renderer, but embedding
it is a substantial, poorly-documented C-interop effort. To get a real, working terminal into the
native app immediately, the first implementation uses **SwiftTerm** (`migueldeicaza/SwiftTerm`) —
a mature pure-Swift terminal emulator whose `LocalProcessTerminalView` manages the PTY and process
lifecycle out of the box.

It sits behind a narrow seam: `TerminalManager` owns the terminal NSViews keyed by session id, and
`TerminalSupervisor` is the only thing that translates PTY lifecycle into derived status facts on the
bus. Swapping SwiftTerm for a libghostty-backed surface later means reimplementing those two types,
not touching the store, sidebar, or session model.

Chosen for speed-to-working over the vision's libghostty; recorded because it is a deliberate,
temporary deviation a future reader would otherwise question.
