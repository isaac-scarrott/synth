---
id: 011
title: Inter-pane resize seams
type: task
status: closed
claimed_by: isaac
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

Built into both design files. The static `.pane-seam` is now the drag target, reusing the sidebar
`.resize-handle` idiom exactly.

- **Idiom.** The seam keeps its 1px hairline (`background: var(--border)`) and gains a widened
  **invisible grab band** (`::before`, 9px, `col-resize` for a row split / `row-resize` for a col
  split) plus a **hover/active highlight** (`::after`, a 1.5px `var(--input)` line, `opacity 0`→`0.5`
  on hover →`0.7` while dragging, 140ms fade) — mirroring `.resize-handle`. Seam gets
  `position: relative; z-index: 6` so its grab band sits above both neighbour panes' surfaces.
- **Drag mechanism.** A delegated `pointerdown` on `.content` grabs the seam, `setPointerCapture`
  routes the drag (survives crossing iframes/terminals; panes get `pointer-events: none` for the
  duration). Each seam stores its split node (`seam._node`, set in `renderNode`); the drag rewrites
  `node.split` and the two child elements' inline `flex` **in place** — no `renderLayout`, so live
  surfaces (browser, streaming logs) never blink.
- **Floor as hard stop.** `minAlong(subtree, axis)` computes the smallest size a neighbour subtree
  can take before any pane hits the 360×240 floor — **summing** panes split along the axis,
  **maxing** across it — and the drag clamps the fraction to `[minA/total, 1 − minB/total]`. An
  already-over-subscribed container (min > available) **pins** the seam (no give) rather than
  breaching the floor.
- **No double-click reset** — deliberately no `dblclick` handler (verified a no-op).

**Verified** by driving `working.html` in a real browser (595×555 content): a column seam dragged to
each extreme hard-stops at exactly 240px (240/314), a mid-drag repartitions proportionally, `::after`
reads opacity 0→0.7 idle→active, double-click leaves heights unchanged, and a floorless row split
correctly pins. `diff working.html big-picture-design.html` shows only the `<title>` + the two demo
session rows — invariant green.
