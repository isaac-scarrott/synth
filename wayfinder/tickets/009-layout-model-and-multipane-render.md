---
id: 009
title: Layout model & multi-pane render (the spine)
type: task
status: closed
claimed_by: isaac
blocked_by: [001, 002, 003, 004, 005]
---

## Question

Not a question — the **first build slice**, the spine every other slice ([010]–[015]) hangs off.
Replace the single-open-session content model with a **pane tree** and render it.

- **Model.** Today `openEl` + `openSession()` (working.html ~2181) + `renderOpen()` (~2814) drive
  exactly one content pane. Introduce a nested binary-tree layout model — arbitrary depth, no cap
  ([Split topology & nesting](001-split-topology-and-nesting.md)) — whose leaves are **panes**, each
  bound to exactly one session (**no empty pane**, per [Per-pane chrome](004-pane-chrome-and-states.md) §2;
  a loading/setup pane still counts as bound — reuse `renderSetup`, ~2208). The single-pane case is
  just a one-leaf tree; today's behaviour is the degenerate case and must stay intact.
- **Render.** Lay the tree out in `.content` (~2103) as nested split containers with a **static**
  seam between siblings (drag-resize is [Inter-pane resize seams](011-inter-pane-resize-seams.md));
  each leaf renders its session through the existing per-type renderers (`renderTerminal` /
  `renderBrowser` / `renderChat` / `renderSim`).
- **Active pane.** Exactly one active pane at all times
  ([Selection & focus model](002-click-and-focus-model.md)); mark it with the **copper ring**
  `inset 0 0 0 2px rgba(var(--accent-rgb),0.85)` (004 §4). **Clicking a pane's body** makes it
  active (002).
- **Per-pane header.** Every pane carries its **full** header (session name + `workspace / branch`
  crumb + PR chip + kebab), per 004 §1 — basic form here; the per-width **degradation** breakpoints
  are [Narrow-pane polish](015-narrow-pane-and-micro-interactions.md).
- **Keys.** Retarget `⌘0` → sidebar / `⌘1` → the **active pane** (formerly "the open session"),
  per 002. No new bindings — finer pane-to-pane movement is
  [Keybinding scheme](007-keybinding-scheme.md).

Every change lands in **both** `working.html` and `big-picture-design.html`; keep
`diff working.html big-picture-design.html` showing only the `<title>` + the extra demo session rows.
Verify by driving `working.html` in a browser (construct a 2- and 3-pane tree, click between panes,
confirm the ring follows and single-pane still works).

## Resolution

Built in both `working.html` and `big-picture-design.html` (`diff` shows only `<title>` + the extra
demo session rows — subset invariant held). Verified by driving `working.html` in a browser.

**Model.** `openEl` + single-pane `renderOpen()` are replaced by a **binary pane tree**:
`layout` (root node) + `activePane` (a leaf). A leaf is `{ leaf:true, session, setup, el }` — bound
to exactly one session (or a setup skeleton, which still counts as bound); a split is
`{ leaf:false, dir:'row'|'col', a, b, split }` where `dir:'row'` = side by side, `'col'` = stacked
and `split` is child a's fraction. **The single-pane case is a one-leaf tree** — today's behaviour is
the degenerate case, kept byte-for-byte (verified: 1 pane, 0 splits, no ring, identical output).
`openEl` is retained as a **mirror of the active pane's session** (`syncActive` keeps it pointing
there), so every single-session subsystem — notifications, ⌘K, browser verbs — keeps reading one
"you are here" without change.

**Render.** `renderLayout()` walks the tree into nested `.split` containers (`renderNode`) with a
**static 1px seam** between siblings (`.pane-seam`; drag-resize is [011]); each leaf renders through
the existing per-type renderers, extracted into `sessionPaneHTML(el)`. Per-pane surfaces are wired
**scoped to their own pane element** (`wireBrowser`/`wireComposer`/`startStream` now take a `scope`),
so two browsers/terminals never steal each other's controls; running terminals each get their own
ticker (`streamTimers` set). Active pane wired last so shared singletons (`browserCommentAPI`) track it.

**Active pane.** Exactly one, marked by the copper ring (004 §4) via `.split .pane--active::after` —
so a lone pane stays ringless (today) but any pane in a split shows it. **Clicking a pane body**
activates it *in place* (`setActivePane`: moves ring + sidebar echo + pill, no re-render, so the click
still reaches its target). Sidebar-click follows 002: a session already up → focus its pane; a session
not up → collapses to a single pane (verified both).

**Keys.** `⌘0`→sidebar / `⌘1`→active pane retained; `focusContent` now scopes to the active pane.

**Prune.** Session deleted/closed → `pruneLayout()` drops the dead leaf and **collapses the split
above it, the sibling reflowing to fill** (001), no guard (005); called from the delete flow and every
`renderLayout`. Verified: removing one of two panes collapses cleanly to single-pane.

**Split creation** is not a gesture yet — that's [010] (content drag) / [012] (sidebar-create). Both
drive the model op `splitPane(leaf, session, dir, before)` built here. Until they land, the tree is
constructed through `window.SynthLayout` (a spine inspection/test handle; product code never reads it).

Verified end-to-end: 2- and 3-pane trees (incl. nested row+col), click-to-activate ring following,
sidebar focus-vs-collapse, prune/reflow, per-pane surface wiring, Settings round-trip restoring the
split — all with a clean console.
