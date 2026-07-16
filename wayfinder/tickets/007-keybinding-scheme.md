---
id: 007
title: Keybinding scheme for split operations
type: grilling
status: open
claimed_by:
blocked_by: [006]
---

## Question

With the mouse design nailed, design the keyboard layer for every split operation — the part that
must feel *instant* to a tmux/neovim user while staying discoverable for everyone.

- Create split (H / V), move focus between panes, resize, close/un-split, zoom/maximise a pane,
  cycle panes — which bindings?
- Reconcile with existing Synth bindings: `⌘0`/`⌘1` focus split, `⌘T` new terminal, `⌘K` palette,
  `⌘B` sidebar, `⌘?` sheet, `r`/`d` sidebar. No collisions; consistent feel.
- tmux users expect a prefix/leader (`⌘-` style?) — decide whether Synth adopts a leader for splits
  or stays chord-based. "Works for all users" vs "fluid for a tmux user" — resolve.
- Land the bindings in `working.html` **and** the `⌘?` shortcuts sheet (both designs, invariant held).

HITL grilling, blocked by the build (design the mouse model first, then bind it). Feeds the handoff.

## Resolution
