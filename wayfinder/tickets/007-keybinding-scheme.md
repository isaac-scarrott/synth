---
id: 007
title: Keybinding scheme for split operations
type: grilling
status: closed
claimed_by: isaac
blocked_by: [006]
---

## Question

With the mouse design nailed, design the keyboard layer for every split operation — the part that
must feel *instant* to a tmux/neovim user while staying discoverable for everyone.

- Create split (H / V), move focus between panes, resize, close/un-split, zoom/maximise a pane,
  cycle panes — which bindings?
- Reconcile with existing Synth bindings: `⌘0`/`⌘1` focus split, `⌘T` new terminal, `⌘K` palette,
  `⌘B` sidebar, `⌘?` sheet, `r`/`d` sidebar. No collisions; consistent feel.
- tmux users expect a prefix/leader (`⌘-` style?) — decide whether Synth adopts a leader for splits
  or stays chord-based. "Works for all users" vs "fluid for a tmux user" — resolve.
- Land the bindings in `working.html` **and** the `⌘?` shortcuts sheet (both designs, invariant held).

HITL grilling, blocked by the build (design the mouse model first, then bind it). Feeds the handoff.

## Resolution

**Pure Mac-native chords — no leader/prefix mode.** The "fluid for a tmux user" requirement is met
by *dual-binding* (arrows + vim aliases, mirroring the sidebar's existing `↑↓`/`jk`), not by a modal
prefix — so the layer stays discoverable for every user and consistent with the `⌘`-chord idiom Synth
already teaches (`⌘K`/`⌘T`/`⌘B`). Five HITL forks decided it; the full table:

| Group | Chord | Action |
|---|---|---|
| **Create** | `⌘⇧→ ← ↑ ↓` | split toward the arrow (new pane on that side) |
| | `⌘⇧\` (`⌘\|`) · `⌘⇧-` (`⌘—`) | side-by-side · stacked aliases (fixed side: right / below) |
| **Focus** | `⌘⌥→ ← ↑ ↓` + `⌘⌥ h j k l` | move focus directionally (spatial, geometry-based) |
| | `⌘1`…`⌘9` · `⌘0` | focus pane N by reading order · focus sidebar |
| | `` ⌘` `` · `` ⌘⇧` `` | cycle to next · previous pane (wraps) |
| **Size/state** | `⌘⌥⇧→ ← ↑ ↓` | resize active pane (push the bordering seam; honours the 360×240 floor) |
| | `⌘⇧⏎` | zoom / unzoom the active pane (transient, tmux-sticky) |
| **Remove** | `⌘⇧U` | unsplit (detach, session → sidebar, keeps running) |
| | `⌘D` | close active session (existing; collapse & reflow) |

**The five forks (each a HITL decision):**
1. **Shape** → pure chords, no leader. (Consistency + discoverability over modal authenticity; the
   tmux user is served by dual-binding, not a mode.)
2. **Focus nav** → *both* directional (`⌘⌥`+arrows/`hjkl`) and numeric (`⌘1`–`9`, extending `⌘0`/`⌘1`).
   Adjacency move + teleport, each reusing an existing idiom.
3. **Zoom collision** → `⌘⇧⏎`; notification-jump keeps `⌘⏎` unmoved (zero disruption to a shipped
   binding, still in the Enter family).
4. **Create keys** → *both* arrows (discoverable primary, pick the side) and `|`/`-` aliases (compact
   power path). Three arrow-families now read as one grammar: `⌘⌥` move · `⌘⌥⇧` resize · `⌘⇧` create.
5. **New-pane fill** (the fork 004 deferred here) → a **pick-a-session `⌘K` frame** — the keyboard
   mirror of the mouse drag-in gesture. New terminal/agent/browser up top, then every existing session
   not already a pane here; choosing one binds it into the fresh pane (an already-open session *moves*,
   per 010's rule). Reuses the drilled-frame machinery from 003.

**Reconciliations (no collisions):** the split block sits **before** the browser page-verbs in the
keydown handler, so `⌘⌥L` (focus-right alias) wins while a bare `⌘L` still reaches the browser omnibox;
`⌘2`–`⌘9` were free; `⌘⇧U`, `` ⌘` ``, `⌘⌥`/`⌘⌥⇧`+arrows all clear. Global `⌘`-chords fire app-wide
(like `⌘T`); directional focus/resize are no-ops with no split; create promotes a single pane. Note for
the native app (008): a focused single-line text field should keep native `⌘⇧←/→` caret selection and
reach split-create via the `|`/`-` alias or `⌘K` — in `working.html` the global handler wins.

**Landed (execution in-map):** every chord wired to the real tree ops built in 009–015 (`splitPane` /
`removeLeaf` / `unsplitSession` / `stashedSplit` zoom / in-place seam rewrite for resize), the
`splitFrame` pick-a-session palette, and a **Split layout** group in the `⌘?` sheet — in **both**
`working.html` and `big-picture-design.html`, `diff` invariant green (only `<title>` + demo sessions).
Verified in a real browser: create→pick→2-pane, `⌘⇧↓`→3-pane, directional + `hjkl` + numeric focus,
`` ⌘` ``/`` ⌘⇧` `` cycle (wraps), `⌘⇧⏎` zoom (durable split preserved, echo band stays, zoomed pane
re-focused on unzoom), `⌘⌥⇧` resize hard-stopping at the 360px floor, `⌘⇧U` returning the detached
session to the sidebar unclosed, `\|`/`-` aliases (crumbs "Split right"/"Split down"), persistence
round-trip across reload (runtime browser correctly collapsed via the missing-session path). Console
clean throughout. **[008] handoff brief now unblocked** — the 006 → 007 → 008 spine is complete.
