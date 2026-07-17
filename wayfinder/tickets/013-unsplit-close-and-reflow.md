---
id: 013
title: Unsplit, close & reflow
type: task
status: closed
claimed_by: isaac
blocked_by: [009, 012]
---

## Question

Removing sessions from a layout — the only routes out of a split.

- **Unsplit — a flat ⌘K command** ([Sidebar grouping](003-sidebar-grouping.md) /
  [Per-pane chrome](004-pane-chrome-and-states.md) §6): add `Unsplit` beside `Rename` / `Close` in
  `sessionFrame` (working.html ~4309) and in the root frame's Session group (~4132 / ~4140), and
  surface it in the active pane's context actions (003). Unsplit drops the member back to a full-width
  row; a 2-way collapsing to 1 dissolves the band. **No dedicated pane close/unsplit control** —
  the pane kebab is that same ⌘K entry, drilled to the pane's session (004 §6).
- **Drag-a-tile-out** of the sidebar band as the fast alternative (003) — reuses the drag machinery
  ([Sidebar echo](012-sidebar-echo-and-create.md) / `enableReorder`).
- **Close/delete a live session** → its pane **collapses**, siblings **reflow** to absorb the space
  (tree reflow, 001 / [Persistence & navigation](005-persistence-and-navigation.md)); a 2-pane split
  collapses to one full-screen pane. **No confirmation guard** — speed-first (005).

Land in **both** design files; keep the `diff` invariant green. Verify by unsplitting via ⌘K, by
dragging a tile out, and by closing a live session mid-split (pane must collapse + siblings reflow),
driving `working.html`.

## Resolution

Built in both design files; the `diff` invariant stays green (only `<title>` + the two demo
sessions). All three routes out of a split now land on one tree op — `removeLeaf` collapse + reflow.

- **Model op `unsplitSession(session)`** (working.html ~2403, beside `removeLeaf`). Guarded by
  `inSplit(session)` = `layout && !layout.leaf && leafBySession(session)` — a **lone pane has no
  split, so Unsplit is never offered there** (verified). It detaches the leaf (`removeLeaf`),
  collapses the split above, reflows the surviving sibling (001), fixes `activePane` to the survivor
  (`firstLeaf` fallback, same as `pruneLayout`), and re-renders. The unsplit session drops back to a
  plain full-width sidebar row — it is *not* closed, just pulled out of the layout. A 2-pane split
  collapsing to 1 dissolves the sidebar band (`renderSidebarEcho` needs ≥2 members).

- **Unsplit — a flat ⌘K command**, added **beside Close** in both `sessionFrame` (the row-kebab
  drill) and the root frame's `contextActions` Session group, gated on `inSplit` so it only appears
  for a session actually in an on-screen split. New `ICON_UNSPLIT` (Phosphor arrows-in — two panes
  merging to one). This is the pane kebab's route too (004 §6): the kebab drills to `sessionFrame`,
  no bespoke pane control.

- **Drag-a-tile-out** (the fast alternative): `begin()` stamps `start.wasMember` when a `.session`
  drag starts inside the split; in `onUp`'s plain-sidebar branch (not a content drop, not a pair) a
  member drag calls `unsplitSession`. Since band order is derived from the tree, reorder-within-band
  has no meaning — any sidebar drop of a member reads as "leave the split." Content-drop MOVE and
  sidebar-pair keep their existing `removeLeaf`-based paths untouched.

- **Close/delete a live session** already collapsed the pane and reflowed via the pre-existing
  `removeUnit → pruneLayout → renderLayout` chain (009/005) — no split-specific guard, matching 005
  "speed-first, no guard" (the standard session-close confirm is not a split guard). Left as-is.

**Verified in a real browser** (working.html): 3-pane → ⌘K Unsplit the active member → 2 panes,
band mirrors survivors, focus falls to survivor, session returns as a row; 2-pane → Unsplit → single
full-screen pane, band dissolved; Unsplit **absent** on a lone pane; **drag api-tests tile out** →
removed from split, row persists in sidebar; **Close dev server mid-split** → pane collapses, sibling
reflows to full surface, row deleted. Owned browsers (e.g. `localhost:5173`, owner `c1`) stay
non-draggable, so they can't be dragged out — correct pre-existing behaviour, unchanged.
