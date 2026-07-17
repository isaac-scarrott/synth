---
id: 010
title: Content drag-to-split & drop-zones
type: task
status: closed
claimed_by: isaac
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

**Built and verified in both design files** (diff invariant green — only `<title>` + demo sessions).
The gesture is folded **into `enableReorder`**, not a separate DnD handler: the moment a dragged
sidebar **session** clone crosses into `.content`, reorder hands off to a drop-zone mode (`dzMode`);
crossing back resumes reorder, and a content-drop restores the sidebar row to its pre-drag slot
(`origNext`) so mid-drag reshuffle never sticks. HTML5 DnD untouched — same pointer-clone feel as
sidebar reordering, per the ticket.

- **Zone resolution** (`computeDrop`, pointer → one op): **outer rim first** — within `RIM` (16px) of
  a content border → whole-surface split on the nearest edge. Else the pane under the pointer
  (`elementFromPoint().closest('.pane')`): normalized position picks **center** (min edge-distance
  `> EDGE` 0.3 → replace) or the nearest **edge** (→ split that side). Each resolves to a `dir`/`before`
  that feeds the spine's `splitPane` (edge) / new `splitRoot` (rim), or an in-place session swap
  (center). Empty surface / settings mode → a plain full-surface `openSession`.
- **Visual** = a single reused `.dz` highlight painted over **the region the new pane will occupy**
  (VS Code idiom, clearest "what will happen"), bare per 004 §3: `.dz--split` copper wash + solid,
  `.dz--replace` slate-blue dashed, `.dz--rim` slate dashed, `.dz--refuse` greyed. Only geometry
  transitions, so the kind never colour-morphs.
- **Min-pane floor** (360×240, 001): a resulting child (edge) or every halved pane (rim) below the
  floor flips the zone to `.dz--refuse` and the drop is a no-op. Verified: on a 995×851 surface a
  row-split of a 497px-wide pane refuses (248 < 360), a whole-surface split of a busy tree refuses.
- **Already-open session → MOVE, not duplicate**: before a split/replace/rim, an existing leaf for
  the dragged session is detached (new `removeLeaf`, collapse-and-reflow per 001), so its old pane
  reflows away and it lands once. **Focus follows** the newly-placed pane (002 / `splitPane`).
- New reusable spine ops added next to `splitPane`: **`splitRoot`** (wrap whole tree in a fresh root
  split — rim) and **`removeLeaf`** (detach one leaf, collapse the split above it — 013 will reuse it
  for unsplit/close).

Verified by driving `working.html`: edge split (row + col), center replace, rim whole-surface split,
floor-refusal (edge + rim), and the move (no duplication) all pass; drop-zone highlight paints the
resulting region live and clears on drop; no console errors.
