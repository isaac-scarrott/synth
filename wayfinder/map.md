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
- [Content drag-to-split & drop-zones](tickets/010-content-drag-to-split.md) — the primary split
  gesture, built into `enableReorder`: a dragged sidebar session crossing into `.content` flips to
  drop-zone mode; `computeDrop` resolves pointer → **rim** (whole-surface split, `splitRoot`) / **edge**
  (split the hovered pane, `splitPane`) / **center** (swap session in place). A single `.dz` highlight
  paints **the region the new pane will occupy** — bare copper (split) / slate-blue dashed (replace) /
  slate dashed (rim) / greyed (`.dz--refuse`) when a child or halved pane would breach the 360×240 floor
  (no-op). An already-open session **moves** (new `removeLeaf` collapse-reflow) instead of duplicating;
  focus follows the drop. Landed in both HTML files, diff invariant green.
- [Inter-pane resize seams](tickets/011-inter-pane-resize-seams.md) — the static `.pane-seam` becomes
  draggable, reusing the sidebar `.resize-handle` idiom (1px hairline + 9px invisible grab band +
  a 1.5px hover/active highlight, `col-`/`row-resize` by axis). A delegated `pointerdown` on `.content`
  grabs the seam (`seam._node` → the split node), `setPointerCapture` carries the drag across
  iframes, and it rewrites `node.split` + the two children's inline `flex` **in place** (no re-render,
  live surfaces preserved). The 360×240 floor is a **hard stop**: `minAlong` (sum along axis, max
  across) clamps the fraction; an over-subscribed split pins with no give. **Drag-only — no
  double-click reset.** Verified in a real browser (extremes hard-stop at 240, mid-drag proportional,
  dblclick no-op); landed in both files, diff invariant green.
- [Sidebar echo & sidebar-create route](tickets/012-sidebar-echo-and-create.md) — a live mirror
  (`renderSidebarEcho`, rebuilt every `renderLayout`): ≥2 session leaves pull the **real** member rows
  into a bare `.session-group` band placed where the first reading-order member lived, flattened
  a-before-b so nested trees still read as one flat ordered band (membership only, never geometry). A
  tile **is** the session row, so the `.session--open` accent + hover ⋮→⌘K come free; past 3 members
  non-active tiles go icon-only (`.session--tile-min`, hover-expands), `refreshEchoActive` re-picks the
  named tile on activation without a rebuild. Second create route in `enableReorder`: a drag onto
  another row's **centre** (30–70%) pairs (copper `.session--pair-to`), edges still reorder;
  `performPair` reuses `splitPane` (target already a pane) or builds a fresh side-by-side layout,
  dragged pane active. Verified in a real browser (both files, diff invariant green).
- [Unsplit, close & reflow](tickets/013-unsplit-close-and-reflow.md) — every route out of a split is
  one tree op (`removeLeaf` collapse + sibling reflow, 001). New `unsplitSession` (guarded by
  `inSplit`) detaches a leaf and drops the session back to a plain sidebar row **without closing it**;
  focus falls to the survivor, a 2→1 collapse dissolves the band. Surfaced as a **flat ⌘K `Unsplit`
  command** beside Close in `sessionFrame` + the root Session group (new `ICON_UNSPLIT`), only when
  the session is in an on-screen split — the pane kebab is that same entry (004 §6). **Drag-a-tile-out**
  is the fast alternative: a member dragged to the plain sidebar (`start.wasMember` in `onUp`) leaves
  the split. **Closing a live session** already collapsed+reflowed via `removeUnit → pruneLayout`
  (009/005), no guard — left as-is. Verified in a real browser (both files, diff invariant green).
- [Per-branch persistence & sticky navigation](tickets/014-branch-persistence-and-sticky-nav.md) — a
  `branchLayouts` Map keys one remembered layout per branch by `workspace‹NUL›branch`, so
  **workspace-switch reduces to branch-switch** for free. `openSession` is now branch-aware: switching
  branch stashes the layout you leave and restores the target's; within a branch a **member click
  returns to the split**, a **non-member click full-screens transiently** over it (`stashedSplit`
  holds the durable split; split-creating ops commit the full-screen as the new durable). The sidebar
  echo mirrors `durableLayout()` so the band stays put behind a full-screen. `renderLayout` is the
  single persistence choke point (`syncBranchLayout` → `localStorage` key `synth-branch-layouts`), so
  every split/drag/unsplit/resize saves; `hydrateLayouts()` restores at boot. A leaf whose key no
  longer resolves on restore takes the **collapse-&-reflow** path (005/004 §2, no empty pane). Genuine
  on-disk serialization stays an **008 handoff** spec point. Verified in a real browser (both files,
  diff invariant green).
- [Narrow-pane behaviour & micro-interaction polish](tickets/015-narrow-pane-and-micro-interactions.md) —
  the finishing pass. Every `.pane` is a `container-type: inline-size` query container, so its header
  degrades against its **own** width (004 §1 order): crumb+copy drop `≤520px`, PR chip → bare state
  glyph `≤420px`, title tightens `≤380px` — the bar never collapses, the name ellipsis-truncates
  instead of wrapping (a base fix, since a wrapped title *is* the bar growing). At `≤420px` the
  terminal/browser/chat surfaces reclaim their frame padding so content stays legible at the 360×240
  floor (terminal already reflows via `pre-wrap`). Micro-interactions: the active copper ring now lives
  at zero-alpha on every split pane so focus changes **cross-fade** it (`transition: box-shadow 150ms`);
  drop-zones **fade in** on appear (`dz-in` 110ms) while geometry still morphs them; the 011 seam reveal
  (140ms) was already within language. Verified 995/497/248/124px, both files, diff invariant green.
- [Build the mouse-only split layout](tickets/006-build-mouse-only-split-layout.md) — **the build
  milestone, closed.** Final integration + invariant pass: drove `working.html` in a real browser and
  confirmed the seven slices cohere as one build — split→two-pane render + copper active ring + per-pane
  live surfaces (009/010), sidebar echo band with tracking accent (012/003), persistence round-trip
  **restoring intact across a full reload** (014), container-query header degradation (015), ⌘K
  **Unsplit** collapsing 2→1 and returning the detached session to the sidebar unclosed (013), seam drag
  hard-stopping at the 360px floor (011). Console clean throughout; `diff working.html
  big-picture-design.html` green (only `<title>` + demo session rows). Mouse-only design is built and
  settled; **[007] keybindings now unblocked**, the 006 → 007 → 008 handoff spine intact.

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
