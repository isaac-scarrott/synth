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
- **Layout** — the arrangement of panes **owned by a branch**: one remembered layout per branch,
  persisted to disk and restored on relaunch (see [005]). The branch is the **sole scope unit** —
  workspace owns no layout. The split is **sticky**: full-screening a single session is a transient,
  tmux-window-style view that leaves the branch's split remembered underneath. The user still splits
  and un-splits at will. Driving example: browser + dev logs side by side while testing, switch to
  another branch and back, and it's still there.
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
- [Sidebar representation of grouped sessions](tickets/003-sidebar-grouping.md) — the echo shows
  **membership + reading order only, never geometry**: a split renders as a **bare horizontal band of
  tiles** in place, always horizontal, ordered top-to-bottom/left-to-right (a nested tree flattens);
  active member keeps `.session--open`; past ~3 members non-active tiles go icon-only (hover-expands
  to restore name+⋮). **A split is always within one branch**, so the band sits inline under its
  branch row. **No bespoke UI:** a tile is a session row — its **⋮ opens ⌘K** drilled to that session
  (`openRowActions → sessionFrame`), where **Unsplit** is a flat command beside Rename/Close (Synth
  has no per-row popovers). **Drag a tile out** is the fast alternative; creating a split stays the
  drag gesture (001), a ⌘K/keyboard create command left to 007.
- [Layout persistence & navigation behaviour](tickets/005-persistence-and-navigation.md) — layout is
  **owned by the branch** (one per branch, persisted to disk, restored on relaunch); workspace owns
  none, so **workspace-switch = branch-switch**. The split is **sticky / tmux-style**: full-screening a
  single session is a transient view (falls out of 002 — member click focuses, non-member click
  full-screens, member click returns), split stays remembered; keyboard toggle deferred to 007.
  Session deleted/closed → pane collapses & siblings reflow (per 001), **no guard**; a missing session
  on relaunch collapses the same way. `working.html` simulates persistence (localStorage); real on-disk
  serialization is a **handoff-brief (008)** spec point.
- [Layout model & multi-pane render (the spine)](tickets/009-layout-model-and-multipane-render.md) —
  single-pane `openEl`/`renderOpen` replaced by a **binary pane tree** (`layout` + `activePane` leaf)
  rendered as nested `.split` containers with a static seam; single pane is the degenerate one-leaf
  case, kept identical to today. `openEl` stays as the active pane's session-mirror so every
  single-session subsystem is untouched. Per-pane surfaces wired to their own element (no cross-steal);
  click-a-pane-body activates in place (copper ring, only shown inside a split); sidebar-click focuses
  an up session / collapses a not-up one (002); delete collapses the split & reflows the sibling (001/005,
  no guard). Split **creation** is still gesture-less — [010]/[012] drive the `splitPane` op built here;
  meanwhile `window.SynthLayout` is the spine's test handle. Landed in both HTML files.
- [Per-pane chrome, drop-zones & empty states](tickets/004-pane-chrome-and-states.md) — **every pane
  keeps its full header** (name + crumb + PR + kebab), degrading **by width** not focus (crumb drops
  first, then PR label→icon); **no empty-pane state** (a pane always hosts exactly one session — splits
  born filled, unsplit collapses, loading still counts as bound; any ⌘K "pick a session" is a transient
  overlay left to 007); a **5th center "replace" drop-zone** swaps a pane's session in place (displaced
  one returns to sidebar) atop 001's edge-splits + outer rim; drop-zones are **bare** (colour+shape
  only) — split=copper, replace=slate-blue dashed; **active pane = a copper ring** around the whole
  pane; the **inter-pane seam** reuses the sidebar handle idiom (min-pane floor honoured), drag-only,
  **no double-click reset**; **no dedicated close/unsplit control** (kebab→⌘K, per 003).

## Not yet specified

- Whether any *cross-branch* "recent layouts" / quick-swap affordance is wanted, beyond the per-branch
  restore 005 already gives (branch-switch is the quick-swap) — only if it emerges from use.

<!-- graduated: the working.html build has been sliced (by mechanism) into 009–015, wired behind
     the build milestone [Build the mouse-only split layout](tickets/006-build-mouse-only-split-layout.md);
     narrow-pane session-type behaviour + per-width header degradation are now
     [Narrow-pane polish](tickets/015-narrow-pane-and-micro-interactions.md). -->

## Out of scope

- The native SwiftUI implementation itself — that's what the handoff hands *off*; a separate effort.
- Tearing a pane into a separate OS window / multi-monitor spread.
