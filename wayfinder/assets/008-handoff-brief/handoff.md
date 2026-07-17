# Handoff brief — Session layout & pane splitting → native app

**Destination of the [Session layout & pane splitting](../../map.md) effort.** The mouse-only design
and the keyboard layer are settled and built in `working.html` (and mirrored in
`big-picture-design.html`, subset invariant green). This brief hands that design to the
**`port-working-html`** skill to implement in the native SwiftUI app under `app/Sources/Synth/`.
The native implementation is the *next* effort — **out of scope here**; this document is the map for it.

> **Source of truth = `working.html`.** Every behaviour below is live there; the line numbers are
> approximate (they drift — grep the named symbol, it's stable). The port skill already reads the
> HTML, the `git log -p -- working.html` diff, and runs a fidelity audit; this brief gives it the
> **seams**: what the feature is, the invariants that must survive the port, the slice list, and the
> exact regions each slice owns.

---

## 1. What the feature is (one paragraph)

The Synth content surface renders exactly one session today. This turns it into a **layout**: a
splittable arrangement of several sessions at once, side-by-side or stacked, nested arbitrarily. You
split by dragging a session from the sidebar over the content area (VS Code / tmux edge drop-zones),
or by keyboard chord. The layout is **owned by the branch** — one remembered layout per branch,
persisted and restored on relaunch — and full-screening one pane is a **transient, tmux-window-style
view** that leaves the branch's split remembered underneath. The sidebar always **mirrors** the
layout as a flat band of session tiles.

## 2. Glossary (the settled language — native code should speak this)

- **Session** — the existing Synth unit: Claude Code, opencode, dev-server logs, a terminal, or the
  browser. The browser is **not special** — just a session a terminal can't render.
- **Pane** — a tile in the content surface hosting exactly one session. A pane is *always* filled
  (splits are born filled; unsplit collapses; loading still counts as bound). **No empty-pane state.**
- **Layout** — the arrangement of panes owned by a branch. Internally a **binary pane tree** (see §3).
- **Split** — a layout with ≥2 panes. Single pane = the degenerate one-leaf tree, behaves exactly as
  today.
- **Active pane** — always exactly one. Copper ring, shown only inside a split.
- **Full-screen (zoom)** — transient single-pane view over a remembered split; the split is *stashed*,
  not destroyed.

## 3. The spine — layout model & multi-pane render

This is the foundation every other slice builds on. **Port this first.**

- The single-pane `openEl` / `renderOpen` model is replaced by a **binary pane tree**: a node is
  either a **leaf** (`{ leaf:true, session, el }`) or a **split** (`{ leaf:false, dir, split, a, b }`)
  where `dir` = `'row'` (side-by-side) / `'col'` (stacked) and `split` is child *a*'s fraction.
  See the node-shape comment at `working.html:2258`; state at `working.html:2262`
  (`let layout = null, activePane = null`).
- Render as nested flex `.split` containers (`.split--row` / `.split--col`) with `.pane` leaves and a
  `.pane-seam` between siblings — CSS `working.html:352` (`.split`), `:338` (`.pane`), `:359`
  (`.pane-seam`). **Single pane is the same code path with one leaf** — keep it byte-for-byte the
  behaviour of today's single session.
- **`openEl` survives** as the active pane's session-mirror, so every existing single-session
  subsystem (header, content render, notifications) is untouched — it just points at the active leaf.
- **Per-pane surfaces are wired to their own element — no cross-steal.** Natively this is the load-
  bearing constraint: N panes = N *concurrent* live surfaces, each terminal / browser / chat rendering
  into its own view. Clicking a pane body activates it in place (`working.html:2230`, `setActivePane`
  `:2379`).
- **`window.SynthLayout`** (`working.html`, search the symbol) is the mock's test handle — the native
  equivalent is the store exposing the tree for driving/tests.

**Tree ops (the whole vocabulary — every gesture and chord funnels through these):**

| Op | `working.html` | Does |
|---|---|---|
| `splitPane(targetLeaf, session, dir, before)` | `:2420` | subdivide one pane |
| `splitRoot(session, dir, before)` | `:2438` | split the whole surface (outer rim) |
| `removeLeaf(target)` | `:2451` | detach a leaf, **collapse & reflow** the sibling into its place |
| `unsplitSession(session)` | `:2470` | detach a leaf, drop its session back to a sidebar row **still running** |
| `pruneLayout()` | `:2336` | drop leaves whose session vanished, re-seat `activePane` |
| `setActivePane(leaf)` | `:2379` | move the active ring + refresh sidebar echo |
| `inSplit(session)` | `:2464` | is this session in an on-screen (≥2-pane) split? |

**Invariants that must survive the port:**
1. Exactly one active pane, always.
2. A pane always hosts exactly one session; **no empty pane**, ever.
3. **Min-pane floor 360×240** (`PANE_MIN_W = 360, PANE_MIN_H = 240`, `working.html:2527`) — a hard
   stop for *both* drops and resizes. A drop or resize that would breach it is refused (no-op).
4. Closing / deleting a session collapses its pane and reflows the sibling — **no confirmation guard**
   beyond Synth's existing quit/close confirms.

## 4. Chrome, drop-zones & active state (per-pane)

- **Every pane keeps its full header** (name + `workspace / branch` crumb + copy button + PR chip +
  kebab). It degrades **by the pane's own width**, not by focus — this is a CSS **container query**
  (`.pane` is `container-type: inline-size`): crumb+copy drop `≤520px`, PR chip → bare state glyph
  `≤420px`, title tightens `≤380px`, name **ellipsis-truncates, never wraps** (a wrapped title *is* the
  bar growing). Order & breakpoints in the §15 narrow-pane slice.
- **Active pane = a copper ring** around the whole pane, shown *only* inside a split — CSS
  `.split .pane--active::after` `working.html:383`. It sits at zero-alpha on every split pane so focus
  changes **cross-fade** (`transition: box-shadow 150ms`).
- **Drop-zones** are bare (colour + shape only), fade in on appear: split = copper solid
  (`.dz--split`, `:396`), replace = slate-blue dashed (`.dz--replace`, `:397`), rim = slate dashed
  (`.dz--rim`, `:398`), refused = greyed (`.dz--refuse`). A single `.dz` highlight paints **the region
  the new pane will occupy**.
- **The inter-pane seam** reuses the sidebar resize-handle idiom (1px hairline + 9px invisible grab
  band + 1.5px hover/active highlight) — `.pane-seam` family `working.html:359–373`. **Drag-only, no
  double-click reset.**
- **No dedicated close/unsplit control** on the pane — the kebab opens ⌘K drilled to that session,
  where Unsplit is a flat command (§6).

## 5. Mouse split gestures (the primary create route)

Built into `enableReorder` (`working.html:4320`); `computeDrop(x,y)` (`:4474`) resolves pointer →
zone:

- Drag a sidebar session across into `.content` → it flips to drop-zone mode.
- **Rim** (outer edge of the whole surface) → `splitRoot` (whole-surface split).
- **Edge** (left/right/top/bottom of the hovered pane) → `splitPane` (split that pane).
- **Center** → **replace** the pane's session in place; the displaced session returns to the sidebar.
- An **already-open** session **moves** (via `removeLeaf` collapse-reflow) instead of duplicating.
- Focus follows the drop. Breach of the 360×240 floor → `.dz--refuse`, no-op.
- **Drag a member tile out** to the plain sidebar leaves the split (`start.wasMember`, `:4437`) — the
  fast unsplit.

## 6. Unsplit / close / reflow

- Every route out of a split is one tree op: `removeLeaf` (collapse + reflow sibling).
- **`unsplitSession`** (`:2470`) detaches a leaf and returns the session to a plain sidebar row
  **without closing it** (keeps running); focus falls to the survivor; a 2→1 collapse dissolves the
  sidebar band.
- Surfaced as a **flat ⌘K `Unsplit` command** beside Close — in the root Session group
  (`working.html:4976`) and the drilled session frame / row-actions (`:5166`), only when the session
  `inSplit`. New `ICON_UNSPLIT`. The pane kebab is that same entry.
- **Closing a live session** already collapses+reflows via the existing `removeUnit` → `pruneLayout`
  path — no new guard.

## 7. Sidebar echo (mirror of the layout)

- `renderSidebarEcho()` (`:2387`), rebuilt every render: ≥2 session leaves pull the **real** member
  rows into a bare `.session-group` band (CSS `working.html:279`) placed where the first reading-order
  member lived.
- **Membership + reading order only, never geometry.** A nested tree **flattens** (a-before-b) into
  one horizontal ordered band. Always horizontal regardless of on-screen split direction.
- A tile **is** the session row, so the `.session--open` accent + hover-kebab→⌘K come free.
- Past ~3 members, non-active tiles go **icon-only** (`.session--tile-min`, `:294`, hover-expands to
  restore name). `refreshEchoActive()` (`:2409`) re-picks the accented tile on activation without a
  full rebuild.
- A split is **always within one branch**, so the band sits inline under its branch row.
- **Second create route:** a drag onto another sidebar row's **centre** (30–70%) pairs them (copper
  `.session--pair-to`); edges still reorder. `performPair` reuses `splitPane` (target already a pane)
  or builds a fresh side-by-side layout, dragged pane active.

## 8. Focus model

- Sidebar click = **"take me to it"**: if the session is up, focus its pane; if it's a *member* of the
  current split, a click **returns to the split**; a **non-member** click **full-screens transiently**
  over the split (§9). `openSession` `working.html:2646`.
- Drag-split / keyboard-create focuses the newly-created pane.
- `⌘0` → sidebar, `⌘1` → active pane (existing bindings, extended by `⌘2`–`⌘9`, §11).

## 9. Persistence & sticky navigation (per-branch)

- **`branchLayouts` Map** (`working.html:2276`) keys one remembered layout per branch by
  `workspace‹NUL›branch`. **Workspace-switch reduces to branch-switch** for free (workspace owns no
  layout).
- **Sticky full-screen:** `stashedSplit` (`:2278`) holds the durable split hidden behind a transient
  full-screen; `durableLayout()` (`:2280`) = the remembered layout ignoring any full-screen. Split-
  creating ops commit the current view as the new durable (they null `stashedSplit`). The sidebar echo
  mirrors `durableLayout()`, so the band stays put behind a full-screen.
- `openSession` (`:2646`) is branch-aware: switching branch stashes the layout you leave and restores
  the target's.
- **`renderLayout` is the single persistence choke point** → `syncBranchLayout()` (`:3409`) →
  `localStorage` key **`synth-branch-layouts`** (mock only). Every split / drag / unsplit / resize
  saves. `hydrateLayouts()` (`:3419`) restores at boot; `layoutToJSON` / `layoutFromJSON`
  (`:3402` / `:3424`) are the serialization shape.
- A leaf whose session key **no longer resolves on restore** takes the **collapse-&-reflow** path (no
  empty pane) — e.g. the runtime browser session on reload.

> **Native persistence:** the mock's `localStorage` is a stand-in. Natively, the per-branch pane tree
> persists **to disk** under the existing restore-across-restarts mechanism (**ADR-0010**). Serialize
> the tree (dir / fraction / session identity per leaf) keyed by branch; on restore, unresolved leaves
> collapse. This is the one place the native work does *more* than the mock, not just mirror it.

## 10. Zoom / resize (keyboard-driven state)

- **`toggleZoom()`** (`:2579`): full-screen the active pane using the same `stashedSplit` mechanism;
  unzoom restores and re-focuses the zoomed pane. The echo band stays.
- **`resizeActive(dir)`** (`:2548`): push the bordering seam by axis; `minAlong` clamps to the
  360×240 floor; an over-subscribed split pins with no give. Seam-drag rewrites `node.split` + the two
  children's inline flex **in place, no re-render** (live surfaces preserved) — the mock uses
  `setPointerCapture` to carry the drag across iframes; natively the equivalent is hit-testing the drag
  across the terminal / browser NSViews.
- **`focusDir(dir)`** (`:2503`) spatial, geometry-based directional focus; **`cyclePane(step)`**
  (`:2493`) next/prev wrapping.

## 11. Keybinding table (the full layer — pure Mac-native chords, no leader)

Dispatched in the main keydown handler's **split block, `working.html:3661–3689`** — placed **before**
the browser page-verbs so `⌘⌥L` (focus-right alias) wins while a bare `⌘L` still reaches the omnibox.
Mirrored in the `⌘?` sheet's **"Split layout"** group (`:4634`).

| Group | Chord | Action |
|---|---|---|
| **Create** | `⌘⇧` + `→ ← ↑ ↓` | split toward the arrow (new pane on that side) |
| | `⌘⇧\` (`⌘\|`) · `⌘⇧-` | side-by-side · stacked aliases (fixed side: right / below) |
| **Focus** | `⌘⌥` + `→ ← ↑ ↓` **and** `⌘⌥ h j k l` | move focus directionally (spatial) |
| | `⌘1`…`⌘9` · `⌘0` | focus pane N by reading order · focus sidebar |
| | `` ⌘` `` · `` ⌘⇧` `` | cycle to next · previous pane (wraps) |
| **Size/state** | `⌘⌥⇧` + `→ ← ↑ ↓` | resize active pane (push bordering seam; honours 360×240 floor) |
| | `⌘⇧⏎` | zoom / unzoom the active pane (transient, tmux-sticky) |
| **Remove** | `⌘⇧U` | unsplit (detach, session → sidebar, keeps running) |
| | `⌘D` | close active session (existing; collapse & reflow) |

Three arrow-families read as one grammar: **`⌘⌥` move · `⌘⌥⇧` resize · `⌘⇧` create.**

- **Notification-jump `⌘⏎` is unmoved** (zoom took `⌘⇧⏎` to avoid the collision).
- **Keyboard-created pane fill:** a pane created by chord is filled by a **pick-a-session `⌘K` frame**
  (`splitFrame` `:2612`, entries built at `:2628`) — the keyboard mirror of the mouse drag-in: New
  terminal / agent / browser up top, then every session not already a pane here; an already-open
  session *moves*. Reuses the drilled-frame palette machinery.
- Global `⌘`-chords fire app-wide (like `⌘T`); directional focus/resize are no-ops with no split;
  create promotes a single pane into a split.
- **Native note (important):** in the mock the global handler always wins. Natively, a focused
  single-line text field must keep native `⌘⇧←/→` **caret selection** — reach split-create there via
  the `|` / `-` alias or `⌘K`, not the arrow chord. Scope the global arrow chords so they don't eat
  text-field editing.

## 12. Slice list for `port-working-html`

The slices below map 1:1 to the resolved tickets, which is the natural decomposition. **Slice A (the
spine) has no dependency and blocks every other slice — land it first, integrate, then fan B–H out.**
B–H are largely independent *concerns* but several touch the store; obey the skill's worktree-per-slice
rule. Native file names are best guesses from the ledger/ADRs — the skill's audit step confirms the
real ones.

| # | Slice | working.html anchors | Ticket | Likely native files |
|---|---|---|---|---|
| **A** | **Layout spine** — pane tree + multi-pane render; single-pane unchanged | §3; `:2262`, `:2420`, `:2451`, render `.split`/`.pane` | 009 | `Store`, content/pane views (new `Pane`/`Split` views) |
| B | Mouse drag-to-split + drop-zones + center-replace + drag-out | §5; `enableReorder :4320`, `computeDrop :4474` | 010 | Sidebar drag source, content drop targets, `Store` |
| C | Inter-pane resize seams | §10; `.pane-seam :359`, `resizeActive :2548` | 011 | `Split` view seam, `Store` fraction rewrite |
| D | Sidebar echo band + sidebar-create pairing | §7; `renderSidebarEcho :2387`, `.session-group :279` | 012 | `Sidebar` |
| E | Unsplit / close / reflow + ⌘K entries | §6; `unsplitSession :2470`, palette `:4976`/`:5166` | 013 | `Store`, `Palette` |
| F | Per-branch persistence + sticky full-screen nav (**to disk**, ADR-0010) | §9; `branchLayouts :2276`, `openSession :2646`, `syncBranchLayout :3409` | 014 | `Store`, persistence layer |
| G | Keybindings + `⌘?` sheet group + pick-a-session `⌘K` frame | §11; key block `:3661`, `splitFrame :2612`, sheet `:4634` | 007 | key handler, `Palette`, shortcuts sheet |
| H | Narrow-pane container-query chrome + micro-interactions | §4; container queries, `.pane--active :383` cross-fade | 015 | pane header view, animations |

## 13. ADRs the native work will need

- **ADR-0010 (persist & restore across restarts)** — the per-branch pane tree is new state to
  serialize; slice F lands under this. (Extend, don't replace.)
- **ADR-0009 (Ghostty terminal renderer)** — N panes = N concurrent terminal surfaces; confirm the
  renderer supports multiple live instances side-by-side.
- **ADR-0011 (embedded browser over CDP)** — the browser is a session that can host a pane; a split
  may render a live browser next to a terminal.
- **ADR-0003 (observable store + typed bus)** — the layout tree lives in the store; per-pane surfaces
  subscribe to their own leaf.
- **ADR-0013 (user-facing taxonomy)** — extend with pane / layout / split / active-pane / zoom.
- **Recommended NEW ADR** — *"Session layout is a per-branch binary pane tree with sticky
  full-screen."* The pane tree, per-branch ownership, and stash-based transient zoom are a genuinely
  new architectural primitive that no existing ADR captures. Worth recording when slice A lands.

## 14. Definition of done for the native effort (not this one)

Per the `port-working-html` checklist: `swift build` clean on the integrated tree; every slice visible
in a screenshot of the running app matching `working.html` served at `:8912`; persistence round-trips
across a real relaunch; the 360×240 floor hard-stops in the running app; console/logs clean. This
brief + `working.html` are the spec; the app is the deliverable of that separate effort.
