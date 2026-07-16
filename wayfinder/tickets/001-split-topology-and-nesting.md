---
id: 001
title: Split topology & nesting model
type: prototype
status: open
claimed_by:
blocked_by: []
---

## Question

What shapes can a layout take? Pick the topology before any pixels get drawn, because it governs
the drag model, resize, close, and every keybinding downstream.

- **Arbitrary nested binary tree** (tmux/VS Code): any pane splits H or V, any depth. Most powerful,
  most edge cases (deep nesting on a laptop screen).
- **Single-level grid** with presets (2-up, 3-up, 2×2): simpler, bounded, less "tmux".
- **Capped tree**: nested but with a max depth / max pane count so it never becomes unusable.

A tmux/neovim power user will reach for deep nesting; "works for all users" argues for sane caps and
obvious defaults. Resolve the tension. Also decide: when a session is dropped on an edge drop-zone,
does it split *that pane* or the *whole surface*? What's the smallest usable pane?

Prototype: a throwaway sketch (HTML or even ASCII) of 2–3 candidate topologies to react to. Keep it
cheap — the output is the **decision**, not the sketch.

## Resolution
