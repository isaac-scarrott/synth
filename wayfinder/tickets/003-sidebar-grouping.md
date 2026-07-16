---
id: 003
title: Sidebar representation of grouped / side-by-side sessions
type: prototype
status: open
claimed_by:
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
