---
id: 003
title: Sidebar representation of grouped / side-by-side sessions
type: prototype
status: closed
claimed_by: isaac
blocked_by: []
---

## Question

Dragging one session onto another in the sidebar pairs them, and the pair renders **side-by-side in
the sidebar**, mirroring the on-screen split (decided while charting). Nail what that looks like and
how durable it is.

- What does a side-by-side sidebar pair actually look like within the three-tier
  (workspace → branch → session) list, at the current row metrics? Does it read at a glance?
- Is the pairing **durable** (a sidebar object you can keep, collapse, re-open) or just a transient
  echo of the current layout? The map says layout is transient — reconcile: can the sidebar show a
  pairing that isn't currently on screen?
- How do you break a pair from the sidebar? Drag out? Kebab action?
- Does it nest (a group of three side-by-side), matching whatever topology 001 lands?

Prototype directly in a throwaway or a scratch copy of the sidebar markup; the output is the visual
+ behaviour **decision**. Feeds the build's sidebar changes.

**Constraint from [ticket 002](002-click-and-focus-model.md) (closed):** the pairing is a
**transient echo** — the sidebar *always mirrors* the on-screen layout automatically, so it never
shows a pairing that isn't currently split on screen (bullet 2 above is largely settled: **not**
durable/independent). Consequences: the "drag onto another session in the sidebar" gesture is just a
**second route to create the same split**; breaking a pair in the sidebar is really un-splitting the
layout (bullet 3); and the active member carries the **existing `.session--open` accent unchanged**,
with no separate visible-but-inactive treatment. This ticket still owns the *visual* — how the
side-by-side (and deeper nested trees, per 001) actually reads at the current row metrics — and the
un-split gesture's feel.

## Resolution

Prototyped content↔sidebar side-by-side across 7 scenarios (single, vertical, horizontal, 3-way,
nested, 4-way, tile-menu) at real row metrics:
[content-and-sidebar-scenarios.html](../assets/003-sidebar-grouping/content-and-sidebar-scenarios.html)
(earlier treatment comparison: [sidebar-split-treatments.html](../assets/003-sidebar-grouping/sidebar-split-treatments.html)).

**The echo carries membership + reading order only — never geometry.** The sidebar does not mirror
the split's shape (vertical / horizontal / nested all read the same); it only says *these sessions
are one split, in this order*.

- **Form.** A group renders as a **horizontal band of tiles** in place of its members' full-width
  rows, sitting where those rows already lived in the branch's session list. **Always horizontal**,
  whatever the on-screen orientation. Tiles are raised fills; **bare — no enclosing container**
  (adjacency against the flat full-width rows carries the grouping). Scenarios 2 and 3 (same echo,
  different geometry) are the proof.
- **Order.** Tile order = content **reading order**, top-to-bottom then left-to-right, flattened.
  A nested tree collapses to a flat ordered band (scenario 5 == scenario 4).
- **Active member** keeps the existing `.session--open` accent unchanged (per 002); no separate
  visible-but-inactive treatment.
- **Legibility floor.** Names stay legible to ~3 members. Past that, non-active tiles collapse to
  **icon-only** (active tile keeps its name); the band stays a single fixed row, never overflows.
  Since many sessions share the terminal icon, **hover-expands a collapsed tile** to restore its
  name (and its ⋮).
- **Scope: a split is always within one branch** (cross-branch ruled out). So the band always sits
  inline under its branch row — no hoisting, no cross-tree group. (Fact for 005: switching branch
  can't strand a split across the tree.)
- **Gestures — no bespoke UI; everything routes through existing patterns.** A tile *is* a session
  row: it carries the same hover **kebab (⋮)** every row has, and — like every row — that ⋮ **opens
  ⌘K drilled to the session's frame** (`openRowActions → sessionFrame`), never a popover ("no
  separate popover to maintain" is the codebase's own rule). **Unsplit** is one more **flat command**
  in that frame, beside `Rename` / `Close`; it also surfaces in root-⌘K search and in the active
  pane's context-actions. Unsplit drops the member back to a full-width row; a 2-way collapsing to 1
  dissolves the band. **Drag a tile out** is the fast alternative. On an icon-only tile the ⋮ rides
  the same hover-expand as the name.
- **Creating** a split stays the **drag gesture** (drag a session onto the content area / onto
  another sidebar session, per 001 / charting). A keyboard-/⌘K-driven *create* command is left to
  **007** (keybindings); this ticket only fixes that break/unsplit lives in ⌘K, not a tile menu.
  (An earlier pass mocked a bespoke tile popover with an `Add split ▸ existing/new` submenu — wrong
  on two counts: Synth has no per-row popovers, and no nested command menus. Corrected to the ⌘K
  command route above.)

This is a **transient echo** (per 002): the sidebar always mirrors the live layout automatically and
never shows a split that isn't on screen; the drag-onto-another-session gesture is simply a second
route to create the same split. Feeds the build's sidebar work (006) and should be kept consistent
with pane chrome (004).
