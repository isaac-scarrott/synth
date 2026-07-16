# Session layout & pane splitting

## Destination

A nailed-down, **mouse-only** interactive design of live session-layout / pane-splitting living in
`working.html` (subset invariant with `big-picture-design.html` held), **then** a keybinding scheme
layered on top, packaged as a **handoff task** for another agent to implement in the native app.
Reaching the end = that design + bindings are settled and the handoff brief is written; the native
implementation itself is the next effort, not this one.

## Notes

**Domain.** The Synth content surface today renders exactly one open session. This effort turns it
into a splittable **layout** of several sessions at once.

**Glossary** (settled language — every later session speaks this):

- **Session** — the existing Synth unit: Claude Code, opencode, dev-server logs, a plain terminal,
  or the browser. The browser is **not** special; it's just a session that can't be rendered by a
  terminal.
- **Pane** — a tile in the content surface hosting exactly one session.
- **Layout** — the current arrangement of panes. **Live and transient**: no branch or workspace
  *owns* a layout; the user splits and un-splits at will. Driving example: browser + dev logs side
  by side while testing, then separated again.
- **Split gesture (mouse, primary)** — drag a session from the sidebar over the content area;
  edge drop-zones (left / right / top / bottom) highlight; dropping subdivides. VS Code / tmux feel.
- **Sidebar grouping (mouse, secondary)** — drag a session onto another *in the sidebar* to pair
  them; the pair renders **side-by-side in the sidebar**, mirroring the on-screen split.

**Standing preferences.** Speed-first, Mac-native, simple-at-a-glance with progressive disclosure
(project ethos). Must feel fluid to a neovim/tmux power user **and** work for every kind of user.
Mouse-only design comes first; keybindings are designed **only after** the mouse design is nailed.

**Execution is in-map** (deliberate override of wayfinder's plan-don't-do default): prototype/build
tickets actually implement in `working.html`. Every shell / style / interaction change MUST land in
**both** `working.html` and `big-picture-design.html`, so `diff working.html big-picture-design.html`
only ever shows the `<title>` + the extra demo session rows (the subset invariant is the guardrail).
The terminal deliverable is a **handoff brief**, not the native implementation.

## Decisions so far

<!-- one line per closed ticket; follow the link for the detail -->

- [Split topology & nesting model](tickets/001-split-topology-and-nesting.md) — arbitrary nested tree,
  no cap; edge-drop splits the hovered pane (+ one outer-rim zone for whole-surface splits); a
  min-pane pixel floor (~360×240) is the guardrail — drops/resizes below it are refused.
- [Selection & focus model with a split open](tickets/002-click-and-focus-model.md) — always exactly
  one active pane; sidebar click = "take me to it" (focus the pane if the session's up, else collapse
  to full-screen); drag-split focuses the newly-dropped pane; `⌘0`→sidebar / `⌘1`→active pane; the
  sidebar **always mirrors** the layout (split members side-by-side, existing `.session--open` accent
  on the active one — so the sidebar-grouping gesture is just a second route to the same split).

## Not yet specified

- How the working.html build ([Build the mouse-only split layout in working.html](tickets/006-build-mouse-only-split-layout.md))
  slices into ≤ one-session chunks, once the decision tickets land.
- Empty-pane / drag-target / resize-seam visuals and micro-interactions (may graduate out of the
  pane-chrome ticket).
- Session-type-specific behaviour inside a *narrow* pane: browser device-mode chrome, terminal
  reflow, the per-pane header (branch crumb, PR chip, copy, kebab) degrading at small widths.
- Whether any "recent layouts" / quick-swap affordance is wanted — only if it emerges from use.

## Out of scope

- The native SwiftUI implementation itself — that's what the handoff hands *off*; a separate effort.
- Tearing a pane into a separate OS window / multi-monitor spread.
- Persisting layouts to disk or across app restart — layout is transient by decision (unless the
  persistence-and-navigation ticket rules otherwise).
