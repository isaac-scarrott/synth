# Synth — Features Ledger

Append-only record of features locked into Synth. Newest entries at the bottom. Never edit or
delete an existing entry — if something changes, append a new dated entry that supersedes it and
says so. Each entry: what the feature is, and the decision/rationale worth remembering.

**Product ethos:** AI-first, native-to-Mac dev environment. Speed is the top priority — chaining
keyboard shortcuts one after another must feel instant. Simple at a glance, with progressive
disclosure to dive deeper.

---

## 2026-07-03 — Foundation

### App shell
Rounded off-white panel (`--radius-app: 14px`) floating on a grey canvas (`#ebebed`). Full-width
grey topbar (`#fafafa`) sits *behind* a full-height, rounded (`20px` right corners) sidebar, so the
sidebar's top-right corner stays visible and the topbar only shows across the content column.
Traffic-light window controls on the sidebar. Layered shadows: a soft two-layer right-cast shadow
on the sidebar, a lighter/tighter downward shadow on the topbar (reads as sitting lower in the stack).

### Three-tier sidebar hierarchy
Repositories → Branches → Sessions. Hierarchy is carried by four dials at once: font family
(sans → mono → smaller sans), weight, size, and color (dark → muted → faint).
- **Repositories** (tier 1): branded monogram chip + semibold SF text. Collapsed repos show a
  faint branch-count badge.
- **Branches** (tier 2): monospace refs, muted grey, connected by a tree guide line. The
  checked-out branch gets a white "active pill" + green "current" dot.
- **Sessions** (tier 3): live things inside the checked-out branch — Claude Code, terminals,
  browsers, simulators — each with a type glyph. The one branded color accent is the terracotta
  Claude Code glyph.

### Status indicator system
Orthogonal axes: **liveness** (right-side dot/badge) and **unread** (left gutter bullet + darker,
heavier row text).
- Claude Code states: running, working (amber pulsing dot), needs-input (`?` blue pulsing badge),
  error (`!` red badge), unread, read.
- Terminal states: running (green dot), idle (grey dot), error (`!` red badge), unread.
- Attention states (`?` needs-input, `!` error) use prominent glyph badges, not dots — they demand
  the eye. Liveness-only states use dots.
- **Progressive-disclosure roll-up:** a collapsed repo surfaces a `?`/`!` bubble on its row if any
  session nested inside needs input or errored — so attention is visible at a glance without
  expanding. The bubble hides once the repo is open (the detail is now visible).

### Keyboard-first navigation
The sidebar is fully keyboard-drivable, matching the speed-first ethos.
- ↑/↓ (or j/k) move a selection ring across currently-visible rows only.
- →/← expand/collapse the selected repo (or fall through to move).
- Enter/Space activate: toggle a repo, or focus a session (which marks it read).
- The selection ring only shows during keyboard use; moving the mouse dismisses it, keeping the
  resting state clean.
- Clicking a session marks it read (clears the unread bullet).

### Animation craft (per Emil Kowalski's design-engineering principles)
Skills vendored under `skills/` (emil-design-eng, animation-vocabulary, review-animations) inform
every motion decision.
- **Frequency rule honored:** expand/collapse is a frequent, near-keyboard action, so it stays fast
  and minimal (185ms grid-rows accordion + opacity fade, 160ms chevron rotate) — deliberately no
  stagger, which would make a frequent toggle feel slow.
- Custom stronger easing curves (`--ease-out: cubic-bezier(0.23,1,0.32,1)`, `--ease-in-out`), never
  `ease-in` on UI, all UI motion sub-300ms.
- Press feedback: rows `scale(0.985)` on `:active`.
- Ambient pulses reserved for genuine attention (needs-input badge, working dot) — justified as
  state indication, not decoration.
- Transform/opacity only (GPU). Hover states gated behind `@media (hover: hover) and (pointer: fine)`.
- `prefers-reduced-motion`: movement + looping pulses dropped, opacity/color kept.

## 2026-07-03 — Iconography (Phosphor)

Switched all sidebar iconography to [Phosphor Icons](https://phosphoricons.com/), regular weight
(256 viewBox, filled `currentColor` paths) — cleaner and less blocky than the previous stroked set.
Caret (chevron), git-branch, terminal-window (terminals), globe (browser), device-mobile
(simulator), and a terracotta sparkle for Claude Code.

- **Attention states are now glyphs, not blocks.** Needs-input uses Phosphor `Question`
  (circle-question) in blue; error uses Phosphor `Warning` (triangle) in red — replacing the earlier
  solid rounded-square badges. Same glyphs drive the collapsed-repo roll-up.
- **Unified indicator slot.** Every right-side indicator (liveness dot, attention glyph, active-branch
  dot) sits in one fixed 16px square that is right-aligned as a column and centers its contents on a
  shared vertical axis — so a 6px dot and a 15px glyph line up on the same center line and the same
  right edge.

## 2026-07-03 — Big-picture shell + branch-group roll-up

File renamed to `big-picture-design.html` (this is the canonical big-picture mock; the old
`index.html` is gone).

- **"Repositories" → "Workspace"** for the nav section label.
- **Bare attention marks.** Needs-input / error now use Phosphor `QuestionMark` / `ExclamationMark`
  (the borderless glyphs) instead of the circled/triangle variants — blue and red respectively.
- **Header removed** for now. The grey topbar is gone; the app is a single-row grid (sidebar +
  content), with traffic lights kept in the sidebar's own top strip.
- **Sidebar collapse.** A sidebar-toggle button sits top-right of the sidebar strip and fully
  collapses the sidebar (grid column animates 260px → 0, 240ms). While collapsed, an expand button
  appears top-left over the content. `Cmd/Ctrl+B` toggles it too (keyboard-first).
- **Branch rows lost their leading git-branch icon** — plain refs read cleaner; the tree guide line
  already carries the hierarchy.
- **Branch group = checked-out branch with live sessions.** It gets a leading caret (expandable) and
  a right-side status that *rolls up its sessions*: show the highest-priority session state by
  precedence **needs-input > error > working > running**, and only when every session is idle fall
  back to showing the branch's last-activity time. Computed in JS from the actual session states, so
  it stays truthful. (Item-count was tried here and removed — too noisy.)

## 2026-07-03 — `working.html` (focused subset)

New `working.html` — a subset of `big-picture-design.html` for the heads-down "working" view.
Identical shell, indicators, roll-up, collapse, and keyboard nav; the only difference is the session
list under the active branch is narrowed to Claude Code + terminals (Claude Code, dev server,
api-tests, shell) — the browser (`localhost:8733`) and simulator (`iPhone 15 Pro`) sessions are
dropped. The two designs now coexist: big-picture = everything at a glance, working = focused subset.

## 2026-07-03 — Row actions: hover kebab, create, delete (in `working.html`)

Every row, at every level, reveals a ⋯ kebab at its end on hover (the status indicator fades out
under it, no layout shift). Clicking opens a **popover menu** (origin-aware: scales out of the kebab,
`transform-origin` top-right, ~150ms ease-out). Actions are scoped by level:

- **Repo ("workspace") level** → **Create branch…** + Delete. Create opens a centered **modal
  dialog** (base-branch *picker* of existing refs + branch-name input; Create disabled until named;
  Enter submits, Esc/backdrop closes). On submit, the new branch is appended with "now" activity.
- **Branch level** → **New terminal** + Delete. New terminal is instant, no dialog (per decision).
  If the branch has no sessions yet, it is *promoted into a group* — gains a caret, a roll-up slot,
  and a sessions container — then the terminal is added and the group expands.
- **Session (leaf) level** → Delete only.

**Delete** is a two-step **inline confirm** inside the same popover (non-invasive — no separate
modal): clicking Delete swaps the menu to "Delete this <level>?" with Cancel / red Delete. Confirming
animates the unit out and recomputes affected branch-group roll-ups.

Decisions locked: branch-create is **terminal-only** (no session-type submenu); delete **confirms at
every level** via the inline pattern; **no keyboard shortcuts** for these yet (⋯/mouse only this
pass). Motion follows the Emil skills — popover origin-aware & sub-300ms, modal stays centered,
hover reveal gated behind `@media (hover:hover)`, press feedback, reduced-motion honored.

Bug fixed during build: in-menu clicks were bubbling to the document outside-click handler; because
the inline-confirm swaps the menu's innerHTML synchronously, the clicked node detached mid-event and
`menu.contains(target)` went false, so the menu closed instead of confirming. Fixed with
`stopPropagation()` on the menu's click handler.

Built in `working.html` only so far — big-picture still has the old rows. Next: either port this to
`big-picture-design.html`, or (better) factor the shared shell + row-actions into a common
`synth.css`/`synth.js` so the two pages stop drifting.

## 2026-07-03 — Sync + subset invariant

`big-picture-design.html` re-synced to `working.html` (row actions, dialog, delete, roll-up all
present). Established invariant: **working is always a strict subset of big-picture**. The two files
are byte-identical except the `<title>` and the two extra session rows (browser `localhost:8733`,
simulator `iPhone 15 Pro`) that only big-picture carries. `diff working.html big-picture-design.html`
should only ever show those. Every future shell/interaction/style change lands in both files.
(Recorded in `CLAUDE.md` too.) The shared-code refactor is still the eventual fix, but until then the
diff is the guardrail.

## 2026-07-03 — Add workspace

A `+` button on the WORKSPACE section header (always visible, faint; brightens on hover) opens an
**Add workspace** modal — a single "Repository" input (path or name; Enter submits, Esc/backdrop
closes, Add disabled until non-empty). On submit a new workspace/repo row is appended: monogram chip
(first letter, color cycled through a fixed palette), name = last path segment, seeded with a checked
-out `main` branch, and it animates in. Kebabs are wired onto the new rows automatically. Landed in
both designs (subset invariant preserved).

## 2026-07-03 — Native app: first working cut (`app/`)

The move from HTML mockups to a native macOS app begins. A SwiftPM app under `app/` (SwiftUI +
`@Observable`, macOS 14+) renders the shell, three-tier tree, and content pane natively, and creates
**real terminal sessions**. Grill decisions it's built on: `docs/adr/0001` (two-layer state:
firehose local, derived facts in the store), `0002` (SwiftUI-first hybrid), `0003` (@Observable store
+ typed event bus, supervisors off-main), `0004` (worktree-per-branch — modelled, physical worktree
creation deferred), `0005` (no "current branch"; nav-cursor + open-session; pill derived), `0006`
(SwiftTerm backend behind a `TerminalManager`/`TerminalSupervisor` seam so libghostty can swap in).

- **⌘T** spawns a terminal under the active branch, promoting a dormant branch into a live group.
- Terminals run a real PTY (user's `$SHELL`) with cwd = workspace root; the `LocalProcessTerminalView`
  is owned outside SwiftUI (keyed by session id) so switching sessions never kills the shell.
- Liveness dots are driven by real process state via the bus (the ADR-0001 seam), not hardcoded.
- **⌘B** toggles the sidebar; the WORKSPACE `+` opens a native folder picker to add a workspace.
- Deferred for now (per user): Claude Code state detection, browser/simulator sessions, keyboard
  row-nav, row kebab actions. Research on Claude Code state detection is captured for when it returns.

Verified end-to-end: launched the app, ⌘T created a `shell` session, ran a command, saw correct
output and cwd, and the branch roll-up + session liveness dots lit green from actual process state.

## 2026-07-03 — Delete-confirm morphs in place (both designs)

Refines the delete flow from the row-actions entry above: the two-step delete confirmation no longer
swaps the popover's `innerHTML` — the container **morphs** between states instead of replacing them.
The popover holds two stacked panes: an **actions** pane (in flow) and an absolutely-positioned
**confirm** pane. Pressing Delete adds `.confirming`, which crossfades actions out / confirm in
(`opacity 120ms`) while the `.menu__viewport` animates its height from the measured actions height to
the measured confirm height (`height 190ms var(--ease-out)`, driven by measure → set-start → reflush
→ set-end). `.menu` gets `overflow: hidden` so the growing content clips cleanly mid-resize.

Decision: a resize-and-crossfade morph reads as one continuous object, not a jump-cut — the earlier
synchronous innerHTML swap is superseded. Motion follows the Emil rules (sub-300ms, transform/opacity
+ height, `--ease-out`); reduced-motion zeroes the transitions so it degrades to an instant swap.
Structurally a two-state container morph — maps directly to a SwiftUI `.animation` on a resizing
container when this is ported to Swift. Landed in both `working.html` and `big-picture-design.html`
(subset invariant preserved).

## 2026-07-03 — Command palette (⌘K), Linear-style

A `⌘K` / `Ctrl+K` command palette — a centered, fading-in dialog modeled on Linear's command menu.
It is a unified **command + jump** surface: a search input over grouped results, fuzzy-matched and
re-sorted by score as you type.

- **Groups (fixed order):** **Actions** (Add workspace…, New terminal, Create branch…, Toggle
  sidebar — the sidebar row carries a `⌘B` hint), then **Workspaces**, **Branches**, **Sessions** —
  the latter three built live from the current tree, each item carrying the row's own icon/monogram.
- **Jump** items reveal the target row (expand its collapsed ancestors), select it, and mark a
  session read — reusing the existing nav/read machinery, so navigating via the palette is truthful.
- **Keyboard-owned while open** (matches the speed-first ethos): ⌘K opens, ↑/↓ move, Enter runs, Esc
  closes; the nav and row-menu keydown handlers early-return on `paletteOpen` so keys don't leak.
  Mouse hover highlights, click runs, backdrop click closes.
- Result list height resizes fluidly as results filter (capped ~340px); open/close motion stays
  sub-200ms, transform/opacity only.

Decision locked: the palette is the keyboard-first entry point to *both* running commands and jumping
the tree, reusing derived nav/read state rather than duplicating it — so it ports to Swift as a view
over the same store, not a parallel command registry. Landed in both `working.html` and
`big-picture-design.html` (subset invariant preserved).

## 2026-07-03 — Content pane: the open session renders (`working.html` + big-picture)

The content column was an empty `<section>`; it now renders the **open session** (CONTEXT.md's "you
are here"). Clicking a session — or activating it via keyboard / ⌘K jump — makes it the single open
session: content renders, the row is marked read and gains a sticky tint, and the white active pill is
**derived** from it. Exactly one branch group across the whole tree carries the pill (per CONTEXT.md —
there is no singular "current" branch); the old hardcoded pills on collapsed workspaces are gone.
Content is generated purely from (session type + name + derived state), so the script stays
byte-identical across both design files and the subset invariant holds.

- **Session surfaces (by type):** Claude Code → agent transcript + composer (when needs-input the
  composer breathes and surfaces the pending question); terminal → dark terminal surface with a
  boot/log transcript keyed to state (running dev server, failing test run, idle shell prompt);
  browser → URL bar + skeleton page; simulator → device frame. (browser/simulator rows exist only in
  big-picture, so only it renders those — but the generic renderer lives in both.)
- **It feels live:** a running terminal trickles a fresh vite/hmr line every ~2.6s; replying to the
  Claude Code composer appends the message, flips the session to **working** (sidebar dot + chip +
  branch roll-up all update from the real derived state), then settles it back to **running** — the
  full status loop, driven off the same DOM state the sidebar already reads.
- On load a session opens by default (the Claude Code hero) so the workspace looks alive; deleting the
  open session falls back to a "No session open" empty state. Motion stays sub-300ms / transform+opacity;
  the log stream and all looping pulses drop under `prefers-reduced-motion`.

Decision: content is a pure function of session type + derived state (no per-session data map) — chosen
so the two HTML files stay diff-clean and so the model ports cleanly to the native SwiftUI content pane.

## 2026-07-03 — Command palette becomes a navigation stack (supersedes the flat ⌘K)

The ⌘K palette is rebuilt from a flat fuzzy list into a **navigation stack of frames** — a Raycast/
Linear-style drill-down that ports cleanly to a SwiftUI `NavigationStack`. Supersedes the flat
command+jump palette from the earlier "Command palette (⌘K)" entry.

- **Simple at rest, progressive on search.** The root frame shows just five entries (Workspaces,
  Branches, Sessions, New terminal, Toggle sidebar). Typing switches it to a grouped, fuzzy-ranked
  search across every command + workspace + branch + session.
- **Drill the hierarchy with breadcrumbs.** Selecting a workspace pushes its frame (its branches),
  a branch pushes its sessions — each frame shows Reveal + a context-scoped create + Delete + the
  child list. Breadcrumb chips render in the search bar between the glyph and the input; click a chip
  (or Backspace on an empty query) to pop back a level. Sessions are leaves — Enter reveals/opens them.
- **Everything inline as text — the palette never opens a modal.** Create is a text-input frame
  ("Create workspace 'x'", disabled until named); Delete drills to a searchable pick-list → an inline
  confirm frame (Delete / Cancel). The old centered modal dialogs are bypassed entirely from ⌘K.
- **Keyboard-first, per the speed ethos.** ⌘K opens/closes; inside, ↑/↓ **and Ctrl+J/K (plus
  Ctrl+N/P)** move the active row, Enter drills or runs, Backspace on an empty query steps back, Esc
  closes. Ctrl+K is reserved for nav-up while open (only ⌘K closes), so the vim/emacs muscle memory
  works. The result list keeps the fluid height-resize as frames change.

Decisions locked: the palette is the single keyboard-first surface for both **navigating** the tree
and **acting** on it (create/delete), reusing the existing DOM-derived nav/read/mutation machinery
rather than a parallel command registry — so it ports to Swift as a view over the same store. Delete's
confirm frame highlights **Delete** by default (Enter confirms) for speed, since reaching it already
took a deliberate drill. Built in both `working.html` and `big-picture-design.html` (subset invariant
preserved). Verified end-to-end in-browser: drill + breadcrumbs, within-frame filter, progressive
grouped search, Ctrl+J/K + arrow nav, create round-trip, delete→pick→confirm (Cancel and Delete
paths), zero console errors.

Also this pass: (1) an expanded **active branch group no longer bolds/darkens its name** — the open
session inside is the "you are here", so the residual header highlight (which read as odd) is dropped
while expanded; the pill still shows when the group is collapsed. (2) Fixed a latent null-deref where
opening then closing the palette within 20ms left a deferred `pal.input.focus()` firing after `pal`
was nulled — guarded with `if (pal)`.

## 2026-07-03 — Command palette: frame grouping, context labels, status (refines the nav stack)

Feedback-driven refinements to the ⌘K navigation stack (the stack model itself is unchanged):

- **No "Reveal" item.** Drilling into a workspace or branch no longer lists a "Reveal …" action — you
  drill to navigate; an explicit reveal read as noise. (Sessions still open on select; that's the leaf.)
- **"New terminal" is branch-scoped.** Dropped from the root and from cross-category search — a
  terminal needs a branch to live in, so it only appears inside a branch frame. Root simple is now
  Workspaces / Branches / Sessions ─ Toggle sidebar.
- **Divider, not header, splits actions from the list.** Within a frame the *actions* (New…, Delete…)
  are separated from the *entity list* by a thin rule, no text header — via an item `sec` tag.
  Cross-category **search keeps text headers** (Actions / Workspaces / Branches / Sessions), where
  naming the entity type actually helps.
- **Sessions carry a live-status label**, colour-coded by derived state (running green / working amber
  / needs-input blue / error red / idle grey) — the status system the sidebar owns, surfaced in the
  palette. Reuses `sessionState` + `STATE_LABEL`, so it stays truthful.
- **Location context, shown only when not already established.** A session shows its `workspace /
  branch` and a branch shows its `workspace` — but *only* in views where that context is absent
  (Sessions/Branches categories, cross-category search, delete-pickers). Once you've drilled into the
  workspace or branch, the now-redundant location is omitted. Computed from DOM ancestry
  (`wsOf`/`brOf`), so it can't drift.

Decision: the palette mirrors the app's two orthogonal axes — *where a thing lives* (location) and
*its liveness* (status) — surfacing each only where it adds information. Ports to Swift as an item view
model with optional `context` + `status` accessories gated on stack depth. Landed in both
`working.html` and `big-picture-design.html` (subset invariant preserved; verified in-browser:
drill/back, Ctrl+J/K, context appears only out-of-context, status colours correct, zero console errors).

## 2026-07-03 — Native app: ⌘K palette ported (navigation stack over the real store)

The command-palette navigation stack (the three entries above) now exists in the native SwiftUI app
(`app/Sources/Synth/Palette.swift`), as designed: frames are built from the `@Observable` AppStore —
not a view tree — so context (`workspace / branch`) and colour-coded status come from the same derived
facts the sidebar reads, and every palette action calls the store's existing mutation paths (create
workspace/branch, new terminal, delete, jump-to-session = reveal ancestors + open + mark read). ⌘K
toggles from anywhere including over a focused terminal; inside, ↑/↓ + Ctrl+J/K (+ Ctrl+N/P) move,
Enter drills/runs, Backspace on an empty query pops, breadcrumb chips pop to depth, Esc closes;
Ctrl+K also opens when closed (outside text/terminal focus, so the shell keeps its own Ctrl+K).
Create-workspace stays the inline text frame (typed path → real git branch discovery), coexisting
with the sidebar's native folder picker. Verified by driving the real app end-to-end: create
workspace → drill → New terminal (real PTY) → Sessions category ctx/status → create + delete branch
via picker → inline confirm. Also ported from this pass: the kebab delete-confirm morph (crossfade +
animated resize), pill suppression on an expanded active branch group, and the open session's sticky
tint.

## 2026-07-03 — Branch rows are real worktree folders; curated add; Remove is UI-only

Each branch row in the native app now maps to a real checkout folder on disk (ADR-0007, refining
ADR-0004): the repo root for the branch checked out there, a Synth-created `git worktree` for the
rest, stored under `~/Library/Application Support/Synth/worktrees/<repo>-<hash>/<branch>` (sensible
default now, configurable later). Adding a workspace opens a **multi-select branch picker** —
branches with existing worktrees are pre-checked and reused; checking others creates their worktrees
on Add. The picker is keyboard-first like the tree: ↑/↓ move, Space toggles, Enter adds, Esc cancels.
More worktrees later via the workspace kebab's **"Create worktree…"** (existing branch, or new branch
off a chosen base) and ⌘K's "New worktree…" (new branch off HEAD). Terminals now start in their
branch's worktree folder, not the workspace root. Deleting a workspace/branch is renamed **Remove**
and is UI-only — sessions end, but branches and folders stay on disk (real deletion deferred);
sessions keep "Delete" because their process genuinely ends. Verified end-to-end in the real app:
picker pre-check + "will create"/"has worktree" tags, `git worktree list` shows the created folders,
`pwd` in a new terminal prints the worktree path, Remove leaves the folder and git state intact.

## 2026-07-03 — ⌘? keyboard-shortcuts sheet

Every binding is now discoverable in one place: **⌘/ (⌘?)** — or the "Keyboard shortcuts" action in
⌘K — opens a modal sheet grouped General / Sidebar / Command palette, rendered from one SHORTCUTS
table using the palette's key-cap styling (alternate bindings shown as "or", e.g. ↑/↓ or J/K). It
toggles from anywhere (closing the palette if open), and while open it owns the keyboard: Esc, ⌘?,
or a backdrop click dismisses it.

## 2026-07-03 — ⌘K opens context-aware to where you are

The ⌘K root now leads with the actions that act on your current location — the open session, its
branch, its workspace — before the generic nav. Grouped under the context path (e.g. `synth /
feat/command-palette`): **New terminal** in that branch, **New worktree…** in that workspace, and
**Delete <session>** for the open session, each labelled with its target. Context is resolved from
the open session first, falling back to the keyboard cursor, then the first workspace; branch/
workspace come from DOM ancestry so they can't drift. The same three actions fold into the Actions
group when you type, so "delete cla" ↵ ↵ removes the open session in three keystrokes. Decision: the
palette should answer "act on what I'm looking at" before "jump anywhere". Landed in both files
(invariant preserved); verified in-browser: context group with correct target labels, filtered
delete → inline confirm → session removed + roll-up recomputed + pane emptied, zero console errors.

## 2026-07-03 — Explicit focus split: ⌘0 sidebar / ⌘1 session, and click follows focus

The window is two focusable halves and the keyboard now moves between them deliberately. **⌘0**
focuses the sidebar (expanding it if collapsed, showing the keyboard ring on the current selection,
falling back to the open session then the first row); **⌘1** focuses the open session's surface (the
chat composer, or the terminal — now `tabindex="-1"` with a soft focus ring so arrows scroll the
scrollback natively). While focus lives in the content pane, sidebar nav keys (↑/↓/J/K/Enter/Space)
stay there instead of being hijacked — which also fixes typing j/k/space into the composer.
**Activating a session from the sidebar** (click or Enter/Space) now hands focus straight to the
content pane, so you can start typing immediately; palette jumps and initial load keep their own
focus. Sidebar arrow-nav also steps relative to the open session when there's no explicit selection.
Landed in both files; verified in-browser (⌘0 ring, ⌘1 composer/terminal focus, click→type, guard).

## 2026-07-03 — Every branch is a group shell (uniform chevron alignment)

Branch rows no longer split into two shapes (plain rows vs. session-holding groups) that indented
differently. Every branch now renders as a group shell — chevron plus a (possibly empty) `.sessions`
collapse — so all branch names align regardless of whether they currently hold sessions; an empty
one just expands to nothing. `rollUpGroups` shows the checked-out dot for an idle active branch
(preserving the active-branch cue), and `addBranch`/`addWorkspace` create group shells directly so
dynamically-added branches match. Decision: uniform structure over conditional indentation — the
chevron is the affordance, presence of sessions is orthogonal. Landed in both files; verified
in-browser: all branches aligned with chevrons, empty group expands cleanly, New terminal on an
empty branch nests a session and lights its roll-up.

## 2026-07-03 — Sidebar dot/chip cleanup

Two small resting-state simplifications. The checked-out **branch dot is now a solid mark** (dropped
its lighter outer ring) — the halo read as noise at that size; session liveness dots keep their ring,
which still earns it. And the content pane's **state chip is removed** from the pane head: liveness is
already carried by the sidebar indicator and the session's own surface, so the header chip
double-encoded. `STATE_LABEL`/`sessionState` stay (the palette still surfaces status). Landed in both
files; verified in-browser.
