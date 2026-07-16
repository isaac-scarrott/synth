---
id: 014
title: Per-branch persistence & sticky navigation
type: task
status: open
claimed_by:
blocked_by: [009]
---

## Question

The layout's lifetime across navigation and restart — all decided in
[Persistence & navigation](005-persistence-and-navigation.md).

- **Branch owns one layout, persisted.** Serialize the pane tree per branch and **simulate on-disk
  via `localStorage`** so it survives reload (005). Genuine on-disk serialization is a spec point the
  [handoff brief](008-handoff-brief.md) carries — this slice only simulates it.
- **Branch-switch** restores that branch's remembered layout (single-pane if it was never split);
  switching back restores the previous branch's split intact (005).
- **Workspace-switch reduces to branch-switch** — the workspace owns no layout of its own (005).
- **Sticky / tmux-style.** Full-screening a **non-member** session is a *transient* view that leaves
  the branch's split remembered underneath; clicking any **member** returns to the split. Falls out
  of [Selection & focus](002-click-and-focus-model.md) — no new rule; the keyboard toggle is
  [Keybinding scheme](007-keybinding-scheme.md).
- **Missing session on restore** → same collapse path as a live close (005 /
  [Per-pane chrome](004-pane-chrome-and-states.md) §2).

Land in **both** design files; keep the `diff` invariant green. Verify by splitting on branch A,
switching to B and back (split restored), reloading the page (split survives), and full-screening a
non-member then clicking a member (split still there), driving `working.html`.

## Resolution
