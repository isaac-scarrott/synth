---
id: 012
title: Sidebar echo & sidebar-create route
type: task
status: open
claimed_by:
blocked_by: [009]
---

## Question

The sidebar's live mirror of the on-screen layout, plus the second route to create a split.

- **Echo form** ([Sidebar grouping](003-sidebar-grouping.md)): render an on-screen split as a
  **horizontal band of tiles** in place of its members' full-width rows, sitting inline under the
  branch row. Membership + reading-order **only, never geometry**; **always horizontal**; **bare**
  (no enclosing container — adjacency against the flat rows carries the grouping).
- **Order** = content reading order (top-to-bottom, then left-to-right); a nested tree **flattens**
  to one ordered band (003).
- **Active member** keeps the existing `.session--open` accent unchanged
  ([Selection & focus](002-click-and-focus-model.md) / 003); **no** separate visible-but-inactive
  treatment.
- **Legibility floor** (003): names stay legible to ~3 members; past that, non-active tiles collapse
  to **icon-only**, with **hover-expand** to restore name + ⋮ (many sessions share the terminal icon).
  The band is a single fixed row, never overflows.
- **Always mirrors** the live layout automatically (002) — the sidebar never shows a split that isn't
  on screen.
- **Second create route** (002 / 003): dragging one sidebar session **onto another sidebar session**
  creates the identical split — reuse [Content drag-to-split](010-content-drag-to-split.md)'s drop
  logic / the existing drag clone (`enableReorder`, ~3676). A tile **is** a session row (same hover
  ⋮ → ⌘K); unsplit/drag-out live in [Unsplit, close & reflow](013-unsplit-close-and-reflow.md).

Land in **both** design files; keep the `diff` invariant green. Verify by splitting on screen and
watching the band appear/reorder in the sidebar, and by dragging one sidebar session onto another to
create the split. Reference asset:
[content-and-sidebar-scenarios.html](../assets/003-sidebar-grouping/content-and-sidebar-scenarios.html).

## Resolution
