---
id: 001
title: Split topology & nesting model
type: prototype
status: closed
claimed_by: isaac
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

Sketch reacted to: [topologies.txt](../assets/001-split-topology-and-nesting/topologies.txt) (candidates A/B/C).

**Topology — A: arbitrary nested binary tree, no depth/count cap.** Any pane splits H or V, any
depth (tmux / VS Code power). Full power wins the tmux/neovim-vs-everyone tension; the guardrail is a
pixel floor, not a magic depth number (below).

**Edge-drop target — split the pane you're pointing at, plus ONE outer-rim zone for whole-surface
splits.** Direct manipulation: dropping on a pane's edge subdivides *that pane*, inserting the
dragged session as its sibling — this alone reaches every possible tree. Whole-surface splits (e.g. a
full-height far-right column when the right side is already subdivided) are served by a single
surface-level drop-zone: the thin margin between the outermost panes and the content border. So there
are exactly **two kinds of zone** — per-pane edges (split that pane) and the outer rim (split the
surface) — *not* VS Code's two-nested-zones-per-edge, which was rejected as too fiddly.

**Smallest usable pane — a pixel floor, and drops/resizes below it are REFUSED.** The floor is the
implicit cap: a drop-zone stays dark (won't accept) and a resize seam hard-stops if the result would
push any pane below the minimum. Nesting can therefore only go as deep as the screen honestly allows;
no rabbit-hole, no scroll, no auto-collapse-to-tabs. Suggested starting floor ≈ **360 × 240 px**
(smallest a terminal/browser session stays legible) — tune during the [working.html
build](006-build-mouse-only-split-layout.md).

Downstream note for [Per-pane chrome, drop-zones & empty states](004-pane-chrome-and-states.md): the
"refuse the drop" rule needs a **rejected/disabled** drop-zone visual (dark / greyed) distinct from
the active highlight, and resize seams need a hard-stop feel at the floor.
