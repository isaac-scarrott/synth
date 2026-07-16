---
id: 013
title: Unsplit, close & reflow
type: task
status: open
claimed_by:
blocked_by: [009, 012]
---

## Question

Removing sessions from a layout — the only routes out of a split.

- **Unsplit — a flat ⌘K command** ([Sidebar grouping](003-sidebar-grouping.md) /
  [Per-pane chrome](004-pane-chrome-and-states.md) §6): add `Unsplit` beside `Rename` / `Close` in
  `sessionFrame` (working.html ~4309) and in the root frame's Session group (~4132 / ~4140), and
  surface it in the active pane's context actions (003). Unsplit drops the member back to a full-width
  row; a 2-way collapsing to 1 dissolves the band. **No dedicated pane close/unsplit control** —
  the pane kebab is that same ⌘K entry, drilled to the pane's session (004 §6).
- **Drag-a-tile-out** of the sidebar band as the fast alternative (003) — reuses the drag machinery
  ([Sidebar echo](012-sidebar-echo-and-create.md) / `enableReorder`).
- **Close/delete a live session** → its pane **collapses**, siblings **reflow** to absorb the space
  (tree reflow, 001 / [Persistence & navigation](005-persistence-and-navigation.md)); a 2-pane split
  collapses to one full-screen pane. **No confirmation guard** — speed-first (005).

Land in **both** design files; keep the `diff` invariant green. Verify by unsplitting via ⌘K, by
dragging a tile out, and by closing a live session mid-split (pane must collapse + siblings reflow),
driving `working.html`.

## Resolution
