---
id: 014
title: Per-branch persistence & sticky navigation
type: task
status: closed
claimed_by: isaac
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

Built in both design files; `diff working.html big-picture-design.html` shows only the `<title>` +
the two extra demo session rows (invariant green). Verified end-to-end in a real browser.

**The branch is the sole scope unit.** A new `branchLayouts` Map keys each branch's remembered layout
by `branchKeyOf(el)` = workspace-name `\0` branch-name — so a branch shared by name across
workspaces stays distinct, and **workspace-switch reduces to branch-switch** for free (there is no
workspace-level entry). Two new globals ride alongside the existing `layout`/`activePane`:
`currentBranchKey` (whose layout is on screen) and `stashedSplit` (the durable split held behind a
transient full-screen). `durableLayout()` = `stashedSplit || layout` is the remembered layout,
ignoring any full-screen.

**`openSession` is now branch-aware and sticky (the whole of 002/005 falls out of it):**
- Different branch → stash the durable layout of the branch you leave, load the target's remembered
  layout, then apply the rules below within it.
- Target has a split, session **is** a member → return to the split, focus that pane.
- Target has a split, session is **not** a member → transient full-screen over the split
  (`stashedSplit` holds the split; a later member click restores it). Split-creating ops
  (`splitPane`/`splitRoot`) clear `stashedSplit`, so deliberately splitting while full-screen commits
  the current view as the new durable layout.
- Target has no split → the session is the single pane (unchanged degenerate case).

**Sidebar echo mirrors `durableLayout()`, not `layout`** — so the member band stays put behind a
full-screen (a visible "the split is still here"), and any member tile clicks straight back into it.

**Persistence is simulated via `localStorage`** under key `synth-branch-layouts`
(`{v, cur, branches:{ [branchKey]: tree }}`). `renderLayout` is the single choke point: it ends in
`syncBranchLayout()`, which refreshes the current branch's entry and re-persists — so **every** layout
mutation (split, drag, unsplit, resize seam) saves with no per-call bookkeeping. A lone setup skeleton
is branchless (`currentBranchKey = null`) and never clobbers a real branch. Session identity across
reload = `branchKey \0 name #occurrence`; the static sidebar rebuilds identically so keys resolve
back. `hydrateLayouts()` runs at boot (before the default open) and repaints the last on-screen branch.

**Missing session on restore → collapse & reflow (005 / 004 §2), verified.** A leaf whose key no
longer resolves — a runtime-spawned, closed, or renamed session — serializes/deserializes to null and
the split above it collapses to its surviving sibling; no empty-pane state ever appears.

**Handoff-brief (008) spec points this surfaces:** the native impl must (a) key one persisted layout
per branch by a stable branch identity, (b) serialize the pane tree (dir/fraction/leaf-session) to
disk and restore on relaunch, (c) treat full-screen as a transient view that never mutates the stored
split, and (d) take the collapse-reflow path for any session that's gone on restore. The
`\0`-joined string keys here are a `working.html` simulation stand-in, not a wire format.
