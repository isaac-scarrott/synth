---
id: 005
title: Layout persistence & navigation behaviour
type: grilling
status: open
claimed_by:
blocked_by: []
---

## Question

Layout is transient and unowned (decided while charting) — but "transient" still has to answer what
happens on navigation. Pin the edges:

- You have a 3-pane split up. You switch **branch** in the sidebar. Does the split stay, collapse to
  one session, or something else? Same question for switching **workspace**.
- Does the arrangement survive an **app restart**, or is a fresh launch always single-pane?
  (Out-of-scope draft says no disk persistence — confirm or overturn.)
- If a session shown in a pane is **deleted/closed** from the sidebar, what happens to its pane?
- Is there ever more than one layout alive at once (e.g. per branch you last visited), or is there
  strictly **one** current arrangement, full stop?

HITL grilling. The user leaned hard on "just the current arrangement", so the likely answer is
minimal/transient — but the navigation edges must be explicit before the build. Blocks the build.

## Resolution
