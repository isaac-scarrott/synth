---
id: 002
title: Evaluate libghostty / libghostty-vt
type: research
status: open
claimed_by:
blocked_by: []
---

## Question

Does the Ghostty project give us load-bearing components for the split? Two distinct fits to
evaluate (summary to assets):

1. **Client-side rendering.** libghostty as the Swift client's terminal surface (VT emulation,
   font shaping, GPU rendering behind a C ABI — the Ghostty mac app is itself a Swift shell over
   it). How mature / stable / embeddable is it *today*? What does Synth render terminals with now
   (cross-check [001](001-current-architecture-inventory.md))?
2. **Server-side screen state.** libghostty-vt as a headless VT state machine per session in the
   Node server, so late-attaching clients get an instant redraw (tmux-style) instead of a byte
   replay. Is it consumable from Node (N-API)? What's the alternative (xterm.js headless)?

Also capture licensing and release cadence. Feeds
[006 screen-state ownership](006-screen-state-and-multi-size.md).

## Resolution
