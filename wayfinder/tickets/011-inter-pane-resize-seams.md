---
id: 011
title: Inter-pane resize seams
type: task
status: open
claimed_by:
blocked_by: [009]
---

## Question

Make the seams between panes draggable, extending the existing sidebar idiom.

- **Idiom.** Reuse the sidebar `.resize-handle` language exactly (CSS working.html ~117, DOM ~1833)
  for **inter-pane seams** ([Per-pane chrome](004-pane-chrome-and-states.md) §5): a hairline that
  reveals a ~1.5px `col-resize` line on hover; dragging resizes the two adjacent panes.
- **Floor.** Honour the ~360×240 min-pane floor as a **hard stop**
  ([Split topology](001-split-topology-and-nesting.md) / 004 §5) — the drag refuses to push either
  neighbour below the floor.
- **No double-click reset** (unlike the sidebar handle): the seam is **drag-only**, no hidden
  "snap to equal" (004 §5).

Land in **both** design files; keep the `diff` invariant green. Verify by dragging a seam in a 2- and
3-pane split down to the floor (must hard-stop) and confirming double-click does nothing.

## Resolution
