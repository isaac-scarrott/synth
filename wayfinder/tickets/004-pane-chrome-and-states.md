---
id: 004
title: Per-pane chrome, drop-zones & empty states
type: prototype
status: open
claimed_by:
blocked_by: []
---

## Question

Each pane needs its own chrome, and the split interaction needs its visual language. Decide:

- **Pane header**: today the content header carries the `workspace / branch` crumb, PR `#` chip,
  copy-branch button, kebab. In a narrow pane, what survives and what collapses? Does every pane get
  a header, or only the focused one? Where does the **close / un-split** control live?
- **Drop-zones**: what the edge highlights look like as a session is dragged over the content area
  (the primary split gesture) — colour, shape, snap feel. Reuse the existing sidebar resize-seam
  visual language where it fits.
- **Resize seam** between panes: there's already a draggable seam between sidebar and content
  (`.content` / resize CSS) — extend that idiom to inter-pane seams.
- **Empty states**: can a pane be empty (split with nothing in it yet)? What does it prompt?

Prototype the states cheaply; output is the **decision** on chrome + interaction visuals. May
graduate its finer micro-interactions into the build. Feeds the build.

## Resolution
