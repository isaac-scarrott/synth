---
id: 015
title: Narrow-pane behaviour & micro-interaction polish
type: task
status: open
claimed_by:
blocked_by: [009, 010, 011]
---

## Question

The finishing pass — how panes behave when small, and the micro-interactions
[Per-pane chrome](004-pane-chrome-and-states.md) explicitly graduated to build-time.

- **Per-width header degradation** (004 §1): as a pane narrows, the branch crumb drops first, then
  the PR chip collapses label→icon, then the title tightens — **never** the whole bar. Set the
  breakpoints (004 fixed the language, left the exact widths to the build).
- **Session-type behaviour in a narrow pane** (map *Not yet specified*): browser device-mode chrome,
  terminal reflow — keep each session type legible under the ~360×240 min-pane width.
- **Micro-interactions** (004 graduated): hot-state timing / opacity of the bare drop-zones
  ([Content drag-to-split](010-content-drag-to-split.md)), the active-ring transition on focus change
  ([Layout model](009-layout-model-and-multipane-render.md)), and seam hover-reveal timing
  ([Inter-pane resize seams](011-inter-pane-resize-seams.md)) — tune within the fixed language.

Land in **both** design files; keep the `diff` invariant green. Verify by narrowing panes to the floor
and watching the header degrade + each session type reflow, driving `working.html`.

## Resolution
