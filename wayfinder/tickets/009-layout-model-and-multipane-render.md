---
id: 009
title: Layout model & multi-pane render (the spine)
type: task
status: open
claimed_by:
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
