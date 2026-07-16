---
id: 010
title: Content drag-to-split & drop-zones
type: task
status: open
claimed_by:
blocked_by: [009]
---

## Question

The **primary split gesture**. Drag a sidebar session over `.content` and show live drop-zones on
the pane under the pointer, then act on the drop.

- **Zones** ([Per-pane chrome](004-pane-chrome-and-states.md) §3, topology from
  [Split topology](001-split-topology-and-nesting.md)): **4 edge zones** (split the hovered pane) +
  **1 outer-rim zone** (whole-surface split) + **1 center zone** (replace the pane's session in
  place). Center = replace, edges = split.
- **Visuals — bare** (004 §3): split zones **copper** wash + solid copper border when hot; **replace**
  zone **slate-blue dashed**; **outer rim** dashed slate. No icons, no labels. Targeted zone gets the
  hot state.
- **Drop behaviour.** Edge → subdivide the hovered pane, inserting the dragged session as its sibling
  (001). Center → **swap** the pane's session in place; the displaced session returns to the sidebar
  (004 §3). Rim → whole-surface split.
- **Min-pane floor** ~360×240 (001): a zone whose result would push any pane below the floor stays
  **dark / refused** (distinct from the hot highlight).
- **Focus follows the newly-dropped pane** ([Selection & focus](002-click-and-focus-model.md)).
- Reuse the existing pointer-drag clone machinery (`enableReorder`, working.html ~3676), **not** HTML5
  DnD, for a consistent feel with sidebar reordering.

Land in **both** design files; keep the `diff` invariant green. Verify by dragging a session to each
zone (edge/rim/center) and to a floor-violating target (must refuse), driving `working.html`.

## Resolution
