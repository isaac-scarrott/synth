---
id: 006
title: Build the mouse-only split layout in working.html
type: task
status: open
claimed_by:
blocked_by: [009, 010, 011, 012, 013, 014, 015]
---

## Question

Not a question — the **build**. Implement the settled mouse-only design in `working.html`, holding
the subset invariant with `big-picture-design.html` (every change in both; `diff` shows only title +
extra demo sessions). This is execution folded into the map (see map Notes).

Scope, once the decision tickets have landed the shape:

- Drag-to-edge split creation with live drop-zones (per 001 topology, 004 visuals).
- Inter-pane resize seams (004), extending the existing sidebar-seam idiom.
- Close / un-split (004), and selection + focus behaviour (002).
- Sidebar side-by-side grouping (003).
- All mouse-only — **no keybindings yet** (that's 007).

**Likely too big for one session.** When 001–005 close, slice this into ≤ one-session chunks
(create-then-wire fresh tickets, blocked by this one's decisions) rather than forcing it whole —
see the map's Not-yet-specified. Verify by driving `working.html` in a browser; keep the invariant
green with `diff working.html big-picture-design.html`.

## Resolution

**Sliced — this is now the build milestone, not a single-session task.** With decisions 001–005
closed, the build was cut **by mechanism** (each slice independent, ≤ one session, verifiable by
driving `working.html`, invariant held) into seven tickets. `blocked_by` was re-pointed from the
decision tickets to these slices; 006 stays open and closes with a final integration + invariant pass
once they all land, keeping the 006 → 007 → 008 spine intact.

- [Layout model & multi-pane render](009-layout-model-and-multipane-render.md) — the **spine**
  (pane-tree, active-pane ring, click-to-focus); everything below hangs off it.
- [Content drag-to-split & drop-zones](010-content-drag-to-split.md) — primary gesture.
- [Inter-pane resize seams](011-inter-pane-resize-seams.md).
- [Sidebar echo & sidebar-create route](012-sidebar-echo-and-create.md).
- [Unsplit, close & reflow](013-unsplit-close-and-reflow.md) — needs 009 + the sidebar tile (012).
- [Per-branch persistence & sticky navigation](014-branch-persistence-and-sticky-nav.md).
- [Narrow-pane behaviour & micro-interaction polish](015-narrow-pane-and-micro-interactions.md) —
  finishing pass over 009/010/011.

After 009 lands, 010 / 011 / 012 / 014 open in parallel; 013 waits on 012; 015 waits on 010 + 011.
