---
id: 004
title: Per-pane chrome, drop-zones & empty states
type: prototype
status: closed
claimed_by: isaac
blocked_by: []
---

## Question

Each pane needs its own chrome, and the split interaction needs its visual language. Decide:

- **Pane header**: today the content header carries the `workspace / branch` crumb, PR `#` chip,
  copy-branch button, kebab. In a narrow pane, what survives and what collapses? Does every pane get
  a header, or only the focused one? Where does the **close / un-split** control live?
- **Drop-zones**: what the edge highlights look like as a session is dragged over the content area
  (the primary split gesture) — colour, shape, snap feel. Reuse the existing sidebar resize-seam
  visual language where it fits.
- **Resize seam** between panes: there's already a draggable seam between sidebar and content
  (`.content` / resize CSS) — extend that idiom to inter-pane seams.
- **Empty states**: can a pane be empty (split with nothing in it yet)? What does it prompt?

Prototype the states cheaply; output is the **decision** on chrome + interaction visuals. May
graduate its finer micro-interactions into the build. Feeds the build.

## Resolution

Settled by reacting to a throwaway prototype ([prototype.html](../assets/004-pane-chrome-and-states/prototype.html)) —
a live 2-pane split reusing the real design tokens, with toggles to flip drop-zone treatment,
active-pane indicator, and a draggable seam to watch the header degrade. It defaults to the choices
below (bare zones + ring); the other variants stay switchable as evidence.

**1 · Pane header — full header on every pane.** Each pane always carries its own header (session
name + `workspace / branch` crumb + PR chip + kebab), not just the active one. It degrades **by
width, not by focus**: the branch crumb drops first, then the PR chip collapses label→icon, then the
title tightens — never the whole bar. Every pane self-describes; the cost (a repeated crumb, a
50px title bar per pane) was accepted over a focus-scoped slim bar.

**2 · Empty states — there is no empty pane.** A pane is **always bound to exactly one session**
(upholding the glossary's "hosts exactly one session"). It falls out of locked decisions: the primary
gesture drops a *session* onto an edge, so a split is **born filled** (001); unsplit **collapses** the
sibling in, leaving no hole (003). A *loading/setup* pane (worktree spinning up, browser navigating)
still counts as bound — "no empty pane" means the tile always has a session, not that it always has
rendered content; the existing `renderSetup` spinner covers that. The only "pick a session" moment —
a future keyboard/⌘K create (007) — is a **transient ⌘K picker overlay**, not persistent empty chrome,
and is 007's to design, not 004's. (The prototype's empty-state provocation was cut.)

**3 · Drop-zones — bare treatment; split copper, replace slate-blue; + a center replace zone.**
- **Topology** (from 001, rendered here): 4 edge zones split the hovered pane, plus one outer-rim zone
  for a whole-surface split. **Added capability:** a **5th center "replace" zone** — dropping onto the
  middle of a pane **swaps that pane's session in place** (no new split); the displaced session returns
  to the sidebar. Center = replace, edges = split.
- **Treatment: bare** — colour + shape only, no icon and no text label. **Split zones = copper**
  (`rgba(var(--accent-rgb),·)` wash, solid copper border when hot); the **replace zone = slate-blue**
  (`rgba(var(--input-rgb),·)`, dashed border) so swap never reads as split; **outer rim = dashed
  slate**. The targeted zone gets the strong (hot) state. (Icon and label variants were built and
  rejected as too loud/wordy for a power-tool gesture.)

**4 · Active-pane indicator — ring.** Exactly one pane is active (002); it's marked by a **copper
border around the whole pane** (`inset 0 0 0 2px rgba(var(--accent-rgb),0.85)`). Unmissable at a glance
in a multi-pane layout. Rejected: *strip* (top-edge hairline — too subtle), *tint* (header wash), and
*dim rest* (fading inactive panes — actively fights the split's purpose, e.g. watching dev-logs while
typing in the browser).

**5 · Resize seam — the sidebar handle idiom, extended; double-click does nothing.** Inter-pane
seams reuse the existing `.resize-handle` language exactly: a hairline that reveals a 1.5px draggable
line on hover, `col-resize` cursor, honouring the ~360×240 min-pane floor (001) — drags below it are
refused. Unlike the sidebar handle, **double-click has no reset behaviour** — the seam is drag-only
(no hidden "snap to equal").

**6 · Close / un-split — no dedicated pane control** (confirms 003). No close button on the pane
header; removing a session lives in the kebab → ⌘K (`Unsplit` as a flat command), with drag-a-tile-out
as the fast alternative. The pane header's kebab is that same ⌘K entry, drilled to the pane's session.

**Graduates to the build (006):** exact hot-state timing/opacity of the bare zones, the ring's
transition on focus change, seam hover-reveal timing, and the per-width breakpoints for header
degradation are micro-interactions to tune while building, within the language fixed above.
