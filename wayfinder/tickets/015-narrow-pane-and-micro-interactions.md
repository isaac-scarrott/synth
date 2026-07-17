---
id: 015
title: Narrow-pane behaviour & micro-interaction polish
type: task
status: closed
claimed_by: isaac
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

The finishing pass, landed in both design files (diff invariant green). The header degrades against
each pane's **own** width, not the viewport's — every `.pane` is now a `container-type: inline-size`
query container, so a pane tightens independently of its siblings.

**Per-width header degradation (004 §1), in order.** Three container-query breakpoints:
- `≤520px` — the branch crumb + its copy button drop (`.pane__crumb, .crumb-copy { display: none }`).
- `≤420px` — the PR chip sheds its `#number` for the bare state glyph (`.prchip span { display:none }`,
  padding tightened); session surfaces also reclaim their frame padding here (below).
- `≤380px` — the title tightens (`.pane__head` padding 18→12px, `.pane__title` gap 8→6px, 13→12.5px).

The bar itself **never collapses** — title (icon + name) and the PR state glyph always survive. Making
that hold required a base fix beyond the breakpoints: `.pane__title` now truncates its name with an
ellipsis (`min-width:0; overflow:hidden` + `white-space:nowrap; text-overflow:ellipsis` on the name
span, icon pinned `flex-shrink:0`) instead of wrapping to a second line — a wrapping title *was* the
bar growing, which 004 §1 forbids. Verified down to 124px: titles read `Clau…` / `local…` / `dev …`,
header height stays a constant 50px single bar.

**Session-type behaviour at the floor.** At `≤420px` the generous surface paddings give way so content
stays legible: terminal `margin 14→8 / padding 13×15→10×12` (it already reflows via `pre-wrap` +
`word-break` — this only reclaims the frame), browser `margin 14→8`, browser bar/view/home paddings
tightened, chat scroll + composer tightened. The browser device-mode chip strip already scrolls
(`overflow-x:auto`), so device chrome needs no change beyond the reclaimed frame.

**Micro-interactions, tuned within the fixed language.**
- *Active ring (009):* the copper ring now lives on **every** split pane at zero alpha
  (`.split .pane::after`) and only `.pane--active` lights it, with `transition: box-shadow 150ms` — so
  a focus change **cross-fades** the copper from old pane to new instead of snapping. Verified: inactive
  `rgba(168,96,56,0)`, active `rgba(168,96,56,0.85)`, transition present on both.
- *Drop-zones (010):* added `@keyframes dz-in` (110ms fade) on `.dz` so the zone **fades in on appear**
  rather than popping; the existing 80ms geometry transition still morphs it as the pointer moves, so
  the *kind* never re-flashes when it changes.
- *Seam reveal (011):* already a 140ms `opacity` reveal (hover 0.5 → active 0.7) — within language,
  left as-is.

All landed in `working.html` + `big-picture-design.html`; `diff` shows only the `<title>` + the two
extra demo-session rows. Verified in a real browser across 995 / 497 / 248 / 124px panes.
