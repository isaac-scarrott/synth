---
id: 006
title: Build the mouse-only split layout in working.html
type: task
status: open
claimed_by:
blocked_by: [001, 002, 003, 004, 005]
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
