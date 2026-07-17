---
id: 012
title: Sidebar echo & sidebar-create route
type: task
status: closed
claimed_by: isaac
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

Built in both design files; `diff` invariant green (title + demo sessions only). Verified by
driving the real page in a browser.

**Echo (`renderSidebarEcho`).** A live mirror rebuilt from `layout` on every `renderLayout` (and torn
down by `renderEmpty` when nothing's split). When the tree holds ≥2 session leaves, the member rows
themselves — not clones — are moved into a bare `.session-group` flex band inserted **where the first
reading-order member lived**, so adjacency (no enclosing chrome) carries the grouping. Reading order =
the tree flattened a-before-b (`eachLeaf`), so a nested split still reads as one flat ordered band and
geometry is never shown. Because a tile **is** the real `.session` row, the open accent
(`.session--open`, moved by `syncActive`) and the hover ⋮→⌘K come for free. Past 3 members the
non-active tiles get `.session--tile-min` (icon-only, hover-expands to restore the name) so the band
never overflows its single row; `refreshEchoActive` (the cheap path `setActivePane` runs) re-picks
which tile keeps its name without a rebuild. `snapOwned` after a reorder-drop re-asserts the echo it
might disturb.

**Second create route (`enableReorder`).** A dragged sidebar session over another row's **centre**
(30–70% band) pairs into a split — copper `.session--pair-to` highlight during the drag, echoing the
content split zone; the row's top/bottom edges stay reorder territory, so both gestures share the one
list. On drop `performPair` reuses the model ops: if the target is already a pane it `splitPane`s in
place (moving the dragged session out of any pane it held); otherwise the two become a fresh
side-by-side `row` layout. Focus follows the dragged session (matches `splitPane` / the content drop).

**Verified:** split on screen → band appears in place, active-tile accent correct; 4-way → three
icon-only tiles + named active; collapse to one pane → band dissolves, rows back to full-width;
drag one sidebar session onto another → `[target | dragged]` split with the dragged pane active, no
lingering highlight; edge-zone drag still reorders (no regression). No console errors.

Notes for the handoff brief (008): min-tile hover-expand + the pair-vs-reorder zone split are the two
interactions to spec; the active tile can ellipsize in a very narrow sidebar with 4 tiles (acceptable;
per-width polish is [015]).
