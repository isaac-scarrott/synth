---
id: 006
title: Screen-state ownership & multi-size clients
type: grilling
status: open
claimed_by:
blocked_by: [002, 003]
---

## Question

Where does terminal *screen state* live, and what happens when two attached clients have different
sizes?

- Server-side VT state machine per session (libghostty-vt / xterm-headless per
  [002](002-libghostty-evaluation.md)) buys instant redraw on attach, reconnect, and multiple
  clients — or is a dumb byte relay + client-side scrollback enough for v1?
- PTY size with two clients: tmux's "resize to smallest" is miserable; alternatives (size follows
  the focused/most-recent client; per-client server-side re-render) have very different costs.
  Multi-size is a *future* reality (phone + desktop) — decide how much v1 must build vs merely not
  preclude.

## Resolution
