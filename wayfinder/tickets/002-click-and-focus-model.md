---
id: 002
title: Selection & focus model with a split open
type: grilling
status: open
claimed_by:
blocked_by: []
---

## Question

Once a layout shows more than one pane, what does **clicking a session in the sidebar** do, and
which pane is **active**?

- Clicking a sidebar session with a split open: fill the *focused* pane, replace the *whole* split
  with that session full-screen, or open it as a *new* pane? (There's already precedent: today a
  click renders the session full-screen and hands focus to the content pane.)
- Which pane is "focused/active", and how is that shown? How does clicking *into* a pane move focus?
- How does this reconcile with the existing focus split — `⌘0` sidebar / `⌘1` session, and
  "click follows focus" (see FEATURES ledger)? Is there now a notion of "the focused pane" that
  `⌘1` targets?
- Does the sidebar highlight *all* sessions currently visible in panes, or just one "active" one?

HITL grilling — the answers hang on how the user actually navigates. Blocks the build.

## Resolution
