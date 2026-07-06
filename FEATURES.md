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

## 2026-07-03 — Native app: session ⌘K/focus/sidebar batch ported

This session's working.html changes are now in the native SwiftUI app
(`app/Sources/Synth/`), ported via worktree-isolated slices, integrated on main,
and verified by driving the built app:

- **Context-aware ⌘K** (`Palette.swift`) — the palette root leads with the actions
  that act on where you are, headed by the context path (`workspace / branch`): New
  terminal in that branch, New worktree… in that workspace, Delete <session> for the
  open session; they fold into Actions when you type. Context resolves open-session
  first, else the nav cursor's row, with branch/workspace each falling back to the
  first available.
- **⌘? keyboard-shortcuts sheet** (`Shortcuts.swift`) — a modal grouped General /
  Sidebar / Command palette from one static table, reusing an extracted `KeyCaps`
  view; a "Keyboard shortcuts" ⌘K item and the ⌘? key both open it (closing the
  palette / row menu first), and it owns the keyboard while open.
- **⌘0 / ⌘1 focus split** (`SynthApp.swift` key monitor) — ⌘0 focuses the sidebar
  (ring on a visible row), ⌘1 focuses the open session's terminal; the existing
  first-responder deferral keeps nav keys in the content pane. Activating a session
  from the sidebar now follows focus into the content pane.
- **Uniform branch group shells** (`Sidebar.swift`, `Navigation.swift`) — every
  branch renders with a chevron and a (possibly empty) sessions container and is
  toggleable; emptying a branch leaves a valid empty group.
- **Content-pane state chip removed** (`ContentPane.swift`).

Not ported: working.html's checked-out-branch dot (its rollup shows a dot for an idle
*checked-out* branch) — the app has no HEAD/checked-out concept yet, so that stays
deferred rather than inventing one here.

## 2026-07-03 — Native app: settings page + Claude Code session type + indicator/kebab polish ported

The working.html batch (`d69cfda`) is now in the native SwiftUI app, verified by driving the built
app (settings global + workspace scopes, ⌘K New Claude Code + Settings, branch kebab menu, the
read/unread × liveness matrix):

- **Settings page** (`SettingsPane.swift`, `Store.swift`, `Sidebar.swift`) — a gear at the sidebar
  foot (⌘, / Esc, plus ⌘K) opens a full-screen mode sharing the shell: the sidebar swaps its tree
  for a scope list (Back / Global / per-workspace), the content pane renders the scope. The one
  setting so far is the worktree setup script; a workspace scope models the effective config as
  **run BOTH, global first** — the read-only global script ("runs first") + "Edit in Global" jump
  above the editable workspace script ("runs next"), with a "Global → <ws> · Both run · global
  first" strip. Dangling scope (removed workspace) falls back to Global; edits persist across scope
  hops. Scripts are an in-memory design surface — **no setup-script runner is wired up yet.**
- **Claude Code session type** (`Store.swift`, `Menu.swift`/`RowMenu.swift`, `Palette.swift`) —
  offered on every creation surface (branch kebab, ⌘K root context, ⌘K branch frame) via a shared
  `addSession`; reuses the sparkle/terracotta `ai` visual. (Superseded below: the kind is now
  detected, not chosen — see the hooks entry.)
- **Only the focused session is bold** — unread surfaces via colour + the gutter bullet, not weight.
- **Idle indicator cleanup** — the grey idle/exited dot is dropped on read rows, kept on unread as
  a "go look" cue; running/working dots unchanged.
- **Right-edge indicator alignment** across nesting (branch right-pad 10→8) and **kebab polish**
  (rounded 7px menu-open box, 13px glyph, even 2px inset).

## 2026-07-03 — Claude Code detected live via hooks (supersedes the creation-time kind)

A session is a terminal; **Claude Code is a detected state**, not a kind you pick. When `claude` runs
in a terminal it's detected and the row upgrades to the sparkle/terracotta Claude visual with a live
status dot; when it exits the row reverts to a plain terminal. "New Claude Code" stays as a
convenience launcher (spawns a terminal that runs `claude`), but the kind is now mutable and driven
by detection, not fixed at creation. See ADR-0008.

- **Detection = a PATH shim, not process polling.** Synth prepends a shim dir with a `claude` symlink
  to the `synth-hook` CLI; running `claude` execs the real binary with an injected `--session-id` +
  inline `--settings` (our hooks), deep-merging any user `--settings`/settings.json so both fire.
  Works in any cwd, zero on-disk footprint; `claude -p`/subcommands pass through. Verified end-to-end
  against real Claude Code 2.1.200 (auto-launch and manual `claude`-in-a-terminal both intercept).
- **Indicators = Claude's hooks → SessionStatus.** `UserPromptSubmit`→working (amber),
  `Stop`→idle (+ marks unread when off-screen), `PermissionRequest` / `PreToolUse` on
  `AskUserQuestion`|`ExitPlanMode`→needs-input (blue ?), `StopFailure`→error, `SessionStart`/
  `SessionEnd`→attach/detach. `SubagentStop` is ignored (must not notify like the parent).
- **Transport = a unix socket** (`/tmp/synth-hook-<pid>.sock`), not HTTP. Hooks (`synth-hook event`)
  write one signal line; the app's socket server turns it into a `SessionEvent` on the bus (ADR-0001).
- **Correlation = injected env** (`SYNTH_SESSION_ID` = row id), so a signal maps to one row even when
  terminals share a worktree. Degrades to a no-op if `synth-hook` or `claude` is missing.
- Design borrowed from cmux (a native-macOS terminal app running the same approach in production).

## 2026-07-04 — Rename everywhere: contextual ⌘K Rename + sidebar `r`/`d` (both designs + native app)

Renaming a workspace / branch / session is now first-class, reachable the same two ways delete is.

- **⌘K contextual Rename.** The palette gains a Rename action that acts on where you are: it leads
  the open session's actions (root frame, above Delete), and appears in the workspace and branch
  frames beside Remove. It pushes an inline `input` frame (never a modal) whose field **seeds with
  the current name, pre-selected**, so a keystroke replaces; the commit item stays disabled until the
  name actually changes. Renaming a live session updates the open pane title (free in the native app —
  the pane reads `session.title`; working.html syncs it manually).
- **Sidebar keyboard: `r` = rename, `d` = delete.** `r` on the highlighted row edits its name in
  place (white fill, blue ring, text selected; ↵ commits, Esc reverts, blur commits — typing is
  swallowed from the nav handler). `d` opens that row's existing delete-confirm popover (↵ confirms,
  Esc cancels) rather than deleting outright, so one stray keystroke can't destroy a session — matches
  the delete-safety design. An open menu owns the keyboard (no double-fire with nav ↵). Both are
  documented in the ⌘? shortcuts sheet.
- **Native port.** `AppStore` gains `rename`/`beginRename`/`commitRename` + inline-rename state, and a
  centralised `rowMenu(for:)` the kebab and `d` both use; the delete-confirm `confirming` flag is
  lifted into the store so the keyboard can drive it. Verified against the running app: ⌘K rename
  frame, `r` inline edit, `d` confirm, and ↵-commits-removal all captured in screenshots.

## 2026-07-04 — Dark mode (both designs): system-default, global-only, terminal included

Synth has a first-class dark mode. It is **token-driven**: the hardcoded colors in the design were
lifted into semantic CSS variables (`--ink*` text tiers, `--raised`/`--glass`/`--chrome` surfaces,
`--hover`/`--press`/`--line*` overlays, `--term-bg`), with light values in `:root` and a single
`:root[data-theme="dark"]` block overriding them — so the whole shell, sidebar, ⌘K palette, menus,
dialogs, settings and the **terminal** all move together. Property-aware conversion: backgrounds,
borders and text flip; box-shadows and modal scrims stay dark in both themes.

- **System by default.** A pre-paint `<head>` script stamps `data-theme` from
  `matchMedia('(prefers-color-scheme: dark)')` (no light flash); a live `change` listener follows the
  OS while the pref is "System".
- **Configurable globally only.** Settings gains an **Appearance** segmented control (System / Light /
  Dark) that appears solely on the Global scope — never per-workspace — persisted to `localStorage`.
- Light mode is byte-for-byte unchanged (dark is purely additive). Reviewed by independent visual +
  code agents; their contrast findings (unread session names, settings copy, ⌘K active-row label,
  palette status meta) were fixed so every dark surface clears legibility.

## 2026-07-04 — Sidebar batch: ⌘K row actions, resizable sidebar, Esc-to-content (both designs)

Three interaction refinements landed together:

- **Row ⋯ opens ⌘K, not a popover.** A row's kebab now opens the command palette drilled to that
  row's frame (`openRowActions` → workspace / branch / new `sessionFrame`) instead of the hover
  popover — one action surface. (The popover code stays, still used by the `d` quick-delete.)
- **Resizable sidebar.** A drag handle on the sidebar/content seam sizes the grid from `--sidebar-w`,
  clamped 200–460px, persisted to `localStorage` and restored on load; double-click resets. The grid
  transition is suppressed mid-drag for instant tracking; the handle hides while collapsed (⌘B wins).
- **Esc focuses the main window.** Pressing Esc while the sidebar has keyboard focus hands focus to
  the open session's surface (composer / terminal) and clears the nav ring — unless a dialog is open
  (it owns Esc first).

## 2026-07-04 — Native port: dark mode + ⌘K row actions + resizable sidebar + Esc-to-content

The working.html batch, landed in the SwiftUI app.

- **Dark mode** is centralised in `Theme.swift`: every colour became appearance-adaptive via a
  dynamic `NSColor` provider (`Theme.dyn(light,dark)` / `Theme.mono(lightα,darkα)` wrapped in
  `Color(nsColor:)`), so call sites are unchanged and the whole app themes from one file — the native
  analogue of working.html's `:root` / `[data-theme="dark"]`. `.preferredColorScheme` is driven by
  `store.colorSchemeOverride` (nil → System follows the OS live; else pins). A global-only Appearance
  segmented control (`ThemeSeg`) lives in Settings, persisted to `UserDefaults`. Terminal + code
  surfaces theme via `Theme.termBg` (incl. the SwiftTerm `nativeBackgroundColor`). Light values are
  byte-identical to the pre-port originals — no light-mode regression. Independent code review
  confirmed the port and caught ~8 inline `Color.black.opacity(…)` fills (tree indent guides, button
  hovers) that didn't adapt; all lifted to `Theme.border` / `Theme.rowHover`.
- **Row ⋯ kebab opens the ⌘K palette** drilled to the row (`store.openRowActions` →
  `PaletteModel.drill(to:)`, with a new `sessionFrame`), not the popover. The popover stays for `d`.
- **Resizable sidebar** — a `SidebarResizeHandle` on the seam drives `store.sidebarWidth` (clamped
  200–460, persisted to `UserDefaults`, double-click resets); the sidebar frame reads that width.
- **Esc in the sidebar** → `focusContent` (key-monitor keyCode 53), gated so the terminal and modals
  keep their own Esc.

## 2026-07-04 — Tab opens a sidebar group (both designs)

Pressing **Tab** on a highlighted group row (workspace or branch group) opens it and steps
selection inside to its first child — a fast "go into this group" motion, distinct from → (which
expands but keeps the cursor on the group). On an already-open group Tab drills to the first child;
on a leaf session it's a no-op, and a dialog owns Tab when one is open. Shown in the ⌘? sheet.

## 2026-07-04 — Sidebar nav: h/l expand·collapse (both designs)

Vim-style `l` / `h` join `j` / `k` in the sidebar: `l` aliases → (expand the highlighted group,
else move down), `h` aliases ← (collapse it, else move up). Shown as alternates on the ⌘? sheet's
"Expand · collapse" row.

## 2026-07-04 — Tab toggles the group (supersedes "Tab opens a sidebar group")

Refinement: **Tab toggles** the highlighted group open↔closed (cursor stays on the group), rather
than opening it and stepping inside. `l`/`h` remain the directional expand/collapse; Tab is the
toggle. ⌘? sheet now reads "Toggle group".

## 2026-07-04 — Native port: Tab toggles group + h/l expand·collapse

Landed the sidebar-nav additions in the SwiftUI app. `AppStore.toggleGroup()` (Tab, keyCode 48 →
guarded by `cursorIsGroup`) toggles the highlighted workspace/branch group open↔closed; `l`/`h` in
the key monitor alias `expandOrIn`/`collapseOrOut`. ⌘? sheet shows "Toggle group" + L/H alternates.
Verified by driving the built app (Tab open→close, l expand, h collapse) with screenshots.
## 2026-07-04 — Terminal renderer = embedded Ghostty (libghostty), replacing SwiftTerm

The native app's terminal is now rendered by **Ghostty's embedding library** (libghostty /
`GhosttyKit`), not SwiftTerm. Terminal fidelity is a first-class concern, and libghostty brings a
GPU (Metal) renderer, real CoreText font shaping (ligatures, powerline glyphs, truecolor, emoji),
and best-in-class VT compatibility — for free, at the cost of a large C-ABI integration.

- **Ownership inverts.** libghostty owns the PTY/shell, VT parsing, and the Metal renderer (it draws
  into the view's `CAMetalLayer` on its own thread, driven by a CVDisplayLink keyed to the display
  id). The Swift layer is a thin host: `GhosttySurfaceView` (an `NSView` that vends the Metal backing
  layer, forwards keyboard/mouse/IME/scroll, and keeps the surface sized in pixels) + `GhosttyApp`
  (the process-wide `ghostty_app_t`, runtime callbacks, and a coalesced wakeup→`ghostty_app_tick`).
- **Config is inline-only** (never the user's `~/.config/ghostty`), so behaviour is deterministic and
  parallel Synth instances can't perturb each other. `term = xterm-256color` avoids depending on the
  ghostty terminfo being installed on the host; colours/font match working.html's `.term` card.
- **Hooks are unchanged.** The Claude-detection env (`SYNTH_SESSION_ID`, socket path, shim-first
  `PATH`) now reaches the shell via libghostty's `surface_config.env_vars` instead of SwiftTerm's
  process env; a Claude session is a native login shell that runs `claude` via `initial_input`.
- **Distribution.** `GhosttyKit.xcframework` (MIT, ~538 MB) is gitignored and fetched by
  `app/vendor/fetch-ghostty.sh` (pinned by ghostty SHA + sha256); `dev.sh`/`build-app.sh` fetch it
  first. `swift build` can't link a static-library xcframework, so `Package.swift` vends the C module
  from a header target and links the fat `.a` via an explicit `-Xlinker` path.
- **Verified against the running app:** a plain shell renders + types + runs in the right cwd, and a
  Claude Code session launches through the shim (real `claude` exec'd with injected `--session-id` +
  `--settings` hooks), round-trips a `claude-start` hook signal back to the socket, and renders
  Claude's full truecolor TUI. Prebuilt libghostty comes from the cmux fork's release (see the
  earlier hooks entry — Synth's approach is modelled on cmux).

## 2026-07-04 — Sidebar toggle: one stable top-left position (both designs)

The collapse/expand toggle no longer jumps: it was at the sidebar's top-**right** when open (and
drifted with the resizable width) but top-**left** when collapsed. Now it sits at a fixed top-left
spot beside the traffic lights in every state (open · collapsed · settings), matching the native
window's real traffic-light cluster. When collapsed, the content pane header indents to clear that
control zone (traffic lights + toggle) so nothing underlaps it.

## 2026-07-04 — Adaptive terminal theme (both designs): light "paper" / dark card

The terminal surface now themes with the app instead of being a fixed dark card. In light
mode it's a warm "paper" card (`#f4f2ec`) with dark text (`#33333a`) and a muted-but-legible
accent set (deeper red/green/yellow/blue that read on light); in dark mode it's a deep
near-black card (`#131315`) with brighter, more vivid accents that pop on the darker bg.

- **A dedicated `--tui-*` token family** drives it — `--tui-bg/fg/dim/red/green/yellow/blue/
  magenta/cyan/cursor/sel/hair` — with light values in `:root` and a dark override block, so
  the whole palette (not just the background) moves with the theme.
- **The card chrome adapts too:** the inset hairline is a dark edge on light paper and a
  white hairline on the dark card, over a soft floating shadow, so the terminal reads as a
  distinct raised surface in both themes rather than blending into the pane.
- **Kept separate from `--term-bg`,** which still backs the Settings code editor (a dark code
  surface in both modes) — the terminal owns `--tui-*` alone, so theming one never touches
  the other.

## 2026-07-04 — Sidebar toggle placement, refined (supersedes the earlier "stable top-left" attempt)

Corrected per feedback + independent design review. OPEN: the collapse toggle sits at the sidebar's
top-RIGHT, vertically centered with the window's traffic lights. COLLAPSED: instead of a floating
toggle over a jagged header, the top becomes one clean toolbar row on the traffic-light axis —
traffic lights → expand toggle → session icon → title/crumb, tightly grouped, hairline divider, the
terminal/content below (no empty band). In the HTML the 3 mac buttons are now a persistent top-left
cluster so they stay visible when the sidebar is closed (matching the native window). Two design
critics flagged the prior collapsed state as "awful"; the reworked toolbar was re-reviewed as great.

## 2026-07-04 — State persists across restarts (native app; ADR-0010)

The tree you build now survives a quit. Workspaces, their worktree/branch rows (with labels, colour,
and expansion state), and your sessions are snapshotted to `~/Library/Application Support/Synth/
state.json` and rebuilt on the next launch. This is a native-app feature with no working.html
counterpart — persistence is invisible in the static design mock.

- **What's durable vs. not.** The tree + low-frequency facts (custom labels, chip colour, which rows
  are expanded) persist; process-bound facts (live status, unread, keyboard selection, the terminal
  process) do not. Restored sessions come back **dormant** (idle, no process); opening one respawns a
  fresh shell in its worktree. Restore is reconstruction, not process hand-off.
- **Storage.** A versioned, atomic JSON snapshot with a `state-previous.json` backup and a schema
  version gate — a corrupt primary falls back to the backup, a bad backup to a clean start, so a bad
  file can't wedge launch. Plain `Codable` DTOs kept separate from the `@Observable` models. Saved by
  a 4s autosave timer (skips writing when nothing changed) plus a flush on quit.
- **Reconciliation.** On load, a workspace whose repo folder is gone — or a branch whose worktree
  folder is gone — is dropped (you deleted it outside Synth); the pruned tree is what gets re-saved.
- **Claude sessions resume their conversation.** Synth's launch shim already mints Claude's session
  id; it's now captured (via the existing hook socket) and persisted, so a restored Claude row opens
  with `claude --resume <id>` and lands back in the conversation. Plain terminals just get a fresh
  shell. Verified end to end by driving the built app across a restart (workspace/branch/labels/
  expansion restored, both a terminal and a Claude session restored, and the Claude row reopening
  straight into Claude Code's resume UI with the captured id).
- **Not done (deliberately):** surviving live local processes (would need tmux/daemon backing — its
  own ADR), and multi-instance coordination (one `state.json` is shared; today's usage is a single
  instance, last-writer-wins).

## 2026-07-04 — Browser session, stage one: a navigable browser in the pane (both designs; ADR-0011)

The `browser` session type stops being a static skeleton and becomes a real, navigable browser in the
content pane — the same tier as a terminal or Claude Code session, living inside a branch's worktree.
This is **stage one of three** (ADR-0011): a browser you can use. Stage two (Claude drives the same
browser via a bundled MCP server over CDP) and stage three (click-to-comment two-way feedback to the
owning Claude session) are designed but not built.

- **One page per session.** A browser session is a single page with a URL bar; want another page, make
  another browser session — they list in the sidebar under the branch like terminals. No tab strip.
  Browser sessions are named by their current page, so navigating renames the sidebar row and the pane
  title (a fresh one is "Browser" until it goes somewhere).
- **Opens to a "go to" home.** Creating a browser (row kebab + ⌘K, alongside New terminal / New Claude
  Code) opens a new-tab surface: a centred globe, a "Go to…" address field, and a **Recent** list
  (seeded from demo data — a real build reads the branch's dev-server port + the session's history).
- **Real browser chrome.** Back / forward / reload + a lock-and-URL omnibox pill. Clicking the pill on a
  loaded page floats the same recents/address surface as a dropdown. History is live: back/forward walk
  it and enable/disable correctly; reload spins.
- **The page is a skeleton, on purpose.** A static HTML mock can't host a live web page, so a shimmer
  skeleton stands in for the WKWebView/Chromium surface a real session renders. The chrome and every
  interaction around it are real.
- **Engine decision (ADR-0011).** The real build embeds Chromium via CEF, not `WKWebView` — because the
  whole point of stages two/three is Claude driving the *same* surface the user sees, and that needs a
  CDP endpoint, which WebKit doesn't expose. Built behind a `BrowserEngine` protocol so the engine stays
  swappable. Claude control (stage two) is a custom bundled MCP server pointed at the embedded browser's
  CDP endpoint — not `--chrome` native messaging, not hooks.
- **Verified** by driving `big-picture-design.html` in a real browser: opening the browser session
  (loaded chrome), the omnibox dropdown, navigating via a recent (URL + sidebar row + pane title update,
  back/forward history correct), the fresh-session home surface, and typing an address + Enter to
  navigate from home — all with no console errors. Both `working.html` and `big-picture-design.html`
  carry the identical shell (subset invariant holds: diff is title + the browser/simulator demo rows).

## 2026-07-04 — ⌘K grouping is scope-aware (both designs; refines "frame grouping, context labels")

The root frame's groups now follow one rule everywhere: **specific → broad**, and context actions are
grouped by the scope they target instead of lumped under one path header.

- **Browse (no query), inside a session.** The context actions used to share a single group labelled
  with the full path (e.g. "synth / feat/command-palette"), mixing session, branch, and workspace
  actions. Now they split into three scope groups, most-local-first, each headed **"Level · unit"**:
  `Session · <name>` (Rename / Delete the open session), `Branch · <name>` (New terminal / Claude Code /
  browser), `Workspace · <name>` (New worktree…), then the nav/global block below. Because each header
  names its target, the rows drop the now-redundant right-side context chip and the target from their
  labels ("Rename", not "Rename api-tests").
- **Search (query).** Group order reversed to **Actions → Sessions → Branches → Workspaces** (was
  Actions → Workspaces → Branches → Sessions) — you most often jump to a session, least often a
  workspace. Under the single `Actions` group the context actions regain a context chip naming their
  unit, so "New terminal · feat/command-palette" stays unambiguous, and `itemScore` folding `ctx` into
  the match means searching a unit's name still surfaces its (now short-labelled) actions.
- **Verified** by driving `big-picture-design.html`: browse headers render `Session · Claude Code` /
  `Branch · feat/command-palette` / `Workspace · synth` with clean rows; a broad query yields group order
  `["Actions","Sessions","Branches","Workspaces"]`; searching "claude" still surfaces the Session
  Rename/Delete actions via the ctx match. No console errors; subset invariant intact.

## 2026-07-05 — Browser session: DevTools toggle (both designs; ADR-0011 amended + research doc)

The browser session grows a DevTools affordance — the user requirement "we need to be able to use
Chrome DevTools on this" was part of the browser concept but missing from the stage-one mock and ADR.

- **Toggle in the browser bar.** A code-brackets button at the right end of the bar (disabled on the
  fresh-session home, like reload) toggles a DevTools panel docked under the page. The button shows an
  on-state while open; the panel carries an Elements / Console / Network / Sources tab strip (tabs
  switch live) over a skeleton body — skeleton for the same reason the page is: the real panel is
  Chromium's own DevTools (CEF `ShowDevTools`), only the toggle and docked frame are ours. Panel and
  selected tab survive navigation, back/forward, and reload; closing removes it cleanly.
- **Root-cause fix that fell out of verification:** pressing Enter in the browser's address inputs
  re-rendered the whole session — `paint()` detaches the input mid-keydown, so the bubbled event's
  target no longer passes the document key handler's `.content` guard, and Enter activated the
  selected sidebar row (silently resetting browser history even before DevTools existed). The address
  inputs now stop propagation of the keys they fully handle (Enter/Escape).
- **ADR-0011 amended:** stage-one scope now names the DevTools toggle (docked CEF DevTools in-app;
  `remote_debugging_port` doubles as external `chrome://inspect` access), and stage two may start by
  bundling Microsoft's Playwright MCP (`--cdp-endpoint` attaches to an already-running browser) before
  graduating to our own server. New `docs/research/browser-agent-integration.md` holds the evidence:
  `--chrome` native-messaging internals verified against current docs (closed extension, Chrome/Edge
  only, hooks can't reroute tools), MCP registration scoping (per-worktree `.mcp.json`), stage-three
  prior art (stagewise's gen-2 pivot to owning the browser, v0 Design Mode, Cursor, click-to-component),
  and the CDP-native pattern that collapses click-to-comment to four CDP calls when you own the browser.
- **Verified** headlessly (Chrome extension unavailable this session) by driving both files with a
  Playwright harness: 23 checks on `big-picture-design.html` (demo-row path) and 24 on `working.html`
  (⌘K "New browser" → home → address-Enter path) — toggle on/off, default tab, dock position, tab
  switching, persistence across omnibox navigation and back, home-surface disabled state, dark-theme
  panel color, zero console/page errors. Subset invariant intact (diff = title + demo rows).

## 2026-07-05 — Browser session ships in the native app (ADR-0011 stage one, gate-verified)

The embedded browser is real: a `browser` session type in the SwiftUI app, at the same tier as a
terminal or Claude Code session, backed by CEF 144 (Chromium) embedded in-pane behind the
`BrowserEngine` protocol, with the CDP endpoint live from day one (stage two's attach point).

- **What shipped.** ⌘K "New browser" + row-kebab creation; "go to" home surface with per-branch
  Recents; loaded chrome (back/forward/reload, lock+URL omnibox pill with floating recents dropdown,
  DevTools toggle opening Chromium's native DevTools, closing it too, resyncing if the user closes the
  window directly); one page per session; `window.open` becomes a new pre-navigated session (never a
  popup, never a renderer hang); sessions rename to the page's host+path unless custom-named; URLs and
  recents persist and restore across restarts; per-session profile dirs and hard teardown (SIGTERM
  reaps every helper in <5s and removes the instance's profiles). Engine internals and constraints:
  ADR-0011 "What building it taught us".
- **Same surface proven.** A Playwright `connectOverCDP` client navigated a session and the pane,
  omnibox, and sidebar tracked it live — the stage-two contract demonstrated in the shipped app.
- **Three-round verification by independent agents.** Full 14-item gate: PASS with 3 findings
  (home-state delete orphaned its engine via a mid-delete lazy re-create; DevTools toggle-off was a
  no-op; about:blank polluted recents). All fixed (tombstoned termination + nil-rendering pane,
  engine close/hasDevTools with toggle resync, hostless-URL filter). Re-gate: core fixes held, two
  residual gaps (CEF's post-close flush resurrecting a profile husk; legacy recents surviving in
  state.json) — fixed with +2s/+6s re-removal and a restore-time scrub. Micro-gate: PASS, catching
  the husk appear and get scrubbed live, and confirming zero orphan targets/dirs/helpers.
- **Known limits, accepted for stage one:** sandbox off (revisit before notarization, ADR-0011);
  DevTools is a native window, not the mock's docked panel; app must launch from a bundle (dev.sh
  assembles one); WKWebView remains a loud no-CDP fallback when CEF assets are absent.

## 2026-07-05 — Browser session, stage two: Claude Code drives the embedded browser (ADR-0011)

Stage two of ADR-0011 ships: a bundled MCP server (`mcp/` in the repo, Node + playwright-core over
CDP) gives any Claude Code session in a managed worktree tools to list, spawn, and drive that
worktree's browser sessions — the same visible surface the user sees, never a headless twin.

- **Discovery.** Each running Synth writes `~/Library/Application Support/Synth/instances/<pid>.json`
  ({ pid, cdpPort, createdAt, worktreePaths, controlSocket }) at launch, refreshes it as
  workspaces/branches change and when the CEF runtime binds its per-instance CDP port, removes it on
  clean quit, and sweeps dead-pid leftovers at launch. The server picks the instance whose
  worktreePaths contain `$CLAUDE_PROJECT_DIR` (fallback: newest live instance; none → every tool
  returns a clear "Synth isn't running" error).
- **Session↔target mapping.** The CEF shim stamps `window.__synthSessionId = "<session uuid>"` on
  every main-frame load end, so any CDP client can map page targets back to Synth sessions.
- **Control socket.** The hook socket (ADR-0008) is one-way, so control verbs get their own tiny
  request/response socket (`/tmp/synth-ctl-<pid>.sock`, one JSON line each way): `browser.list`
  {worktreePath} → sessions, and `browser.create` {worktreePath, url?} → sessionId, creating the
  session exactly like ⌘K New browser (matching branch, pre-navigated, selected).
- **Tools.** browser_list / browser_create / browser_focus / browser_navigate / browser_back /
  browser_forward / browser_reload / browser_click (selector or x,y) / browser_type /
  browser_screenshot (PNG) / browser_snapshot (aria tree) / browser_console (live capture + a
  Runtime.enable replay for messages predating attach) / browser_evaluate. History navs wait for
  commit, not domcontentloaded (CEF fires none — the spike's lesson).
- **Registration.** On launch Synth syncs `mcp/` to `~/Library/Application Support/Synth/browser-mcp/`
  (npm install --omit=dev when node_modules is missing or package.json changed) and merges
  `{"mcpServers":{"synth-browser":…}}` into each managed worktree's `.mcp.json`, preserving other
  servers and skipping writes when already correct. **.mcp.json handling:** do not gitignore it —
  project-scope sharing is the point — but Synth never commits it, and neither should agents.
- **Hardening found by verification:** engine creation pumps the runloop, and a SwiftUI render pass
  nested inside that pump could re-enter BrowserManager and build a duplicate engine (two CDP targets
  claiming one session). Guarded with an in-flight set; the control verb relies on the pane's proven
  mount path instead of forcing the engine itself.

## 2026-07-05 — Stage two gate-verified: a real Claude session drove the browser (ADR-0011)

Independent gate, 7/7 PASS: scripted MCP client exercised all 13 tools end-to-end; a live
`claude -p` session (project-scoped `.mcp.json`, `mcp__synth-browser__*` allowed) created a browser,
navigated, screenshotted, and reported the page title correctly while the pane/sidebar tracked every
step; scoping isolated worktrees' sessions; teardown left nothing. Gate findings fixed and
re-gate-verified: tool text capped at 40k chars (a 30k-element page snapshot was ~1.5M), nested
`.worktree/<slice>` checkouts auto-scope to their deepest managed ancestor (unmanaged paths get a
⌘K "New worktree" adoption hint), a vanished focused session errors instead of silently retargeting,
ANSI stripped from errors, control socket unlinked on quit. Known minor: browser_create's 15s
target-mapping poll can warn spuriously under load (session still works); watch-item: one
unreproduced spontaneous instance exit during heavy concurrent probing.

## 2026-07-05 — Browser session, stage three: user comments flow to Claude as located context (ADR-0011)

The two-way mode. The user turns on comment mode in a browser session, selects an element on the
live page and leaves a comment; it reaches the branch's Claude Code session as a composed message
with screenshots and located context, and Claude acts on it — the same visible surface, no headless
twin, no new transport.

- **The contract (host ↔ page overlay).** Binding `window.__synthComment`; the page calls it with
  `JSON.stringify(payload)` where payload = `{type:"comment"|"exitMode", url, title, selector, xpath,
  rect:{x,y,width,height,scrollX,scrollY,dpr}, elementHTML(≤2000), elementText(≤500), comment,
  reactSource:{fileName,lineNumber,columnNumber}|null}` (rect in viewport CSS coords). The overlay
  ships at `app/Sources/Synth/Resources/CommentOverlay.js` and exposes
  `window.__synthOverlay = { enter(cfg), exit() }` (cfg `{targetLabel}`). A parallel slice builds the
  real selection UI; this slice ships a logging stub at that path that the real file replaces at
  integration (identical path, no other coupling).
- **Host wiring (CDP, four calls).** `CDPClient.swift` — minimal CDP over URLSessionWebSocketTask,
  per-target socket (flat attach: `GET /json/list`, match `window.__synthSessionId`, connect to the
  target's `webSocketDebuggerUrl` — no Target multiplexing). `CommentMode.swift` — per browser
  session: `Runtime.addBinding` + `Runtime.bindingCalled` (page→host, zero networking),
  `Page.addScriptToEvaluateOnNewDocument` (overlay on every future document) plus a `Runtime.evaluate`
  for the current one, `Page.captureScreenshot` clipped to the padded element rect (±24px, clamped)
  and a full-viewport shot. **World: main world, not isolated** — the payload's `reactSource` reads
  React's fiber `__source` off DOM expandos, invisible to an isolated world, and main-world keeps the
  binding target-wide with no executionContextId bookkeeping.
- **Located context.** Screenshots saved to `~/Library/Application Support/Synth/comments/<sessionId>/
  <ts>-{element,viewport}.png`; the message names host+path, selector, size/position, React source
  (when present), whitespace-collapsed elementHTML (≤400), both screenshot paths, and the comment,
  closing with "Please address this feedback in the code."
- **Delivery.** The branch's most-active Claude Code session (working/needsInput/running first, else
  any) receives the message through its PTY — `TerminalManager.submit` pastes via
  `ghostty_surface_text` then a trailing `\r` (`ghostty_surface_text_input`) to submit. No Claude
  session in the branch → a transient in-pane notice, comment dropped (v1, no queue).
- **UI.** A comment-mode toggle in the browser bar (phosphor chat-circle-dots), left of DevTools,
  disabled on home, active-highlight while on, with a "→ <Claude title>" target chip; ⌘K exposes
  Enter/Exit comment mode on a focused browser session. Esc exits (and the overlay's own `exitMode`
  binding call flips the button off through the same path). The page keeps its keys — no focus theft.
- **Verified (synthesized page side, no overlay needed).** Twice consecutively: `typeof
  window.__synthComment === "function"` on the page target; a synthetic comment payload produced two
  decodable PNGs (element clip = the padded button, full viewport) and a delivery log line; `exitMode`
  and the toggle both flipped the mode off; navigating while on kept the binding alive on the new
  page. Load-bearing check passed end-to-end: a real `claude` session received "make this button
  blue", and its own image-cache holds a screenshot of the now-blue button plus a git edit adding
  `background:#1d4ed8` — Claude read the located context, acted, and self-verified. `swift build`
  clean, `./dev.sh --check` PASS, clean SIGTERM teardown. Automation seam: `ControlServer` gains
  `automation.newClaude` / `automation.commentMode` / `automation.state` verbs, gated on
  `SYNTH_AUTOMATION=1`, each calling the exact UI path — the harness's stand-in on machines whose TCC
  denies synthetic keystrokes. Note: window-buffer screenshots fail for an off-active-Space window on
  this host, so terminal-pane capture was substituted by the transcript/image-cache/git evidence.

## 2026-07-05 — Stage three gate-verified: click-to-comment closes the human→Claude→code loop (ADR-0011)

Independent gate PASS after a fix loop. Confirmed twice: the user picked a page element, commented, and
Claude edited the served file (button → rebeccapurple, verified via reloaded computed style); the overlay
survives navigation without re-toggling; double-submit sends one payload; a hostile page's own
pointer/click handlers stay at zero during a pick; the no-target notice fires cleanly.

- **Security boundary verified.** The composed comment embeds page-controlled strings (title, selector,
  element HTML). Delivery now targets only a session a live `claude` has confirmed via the hook seam
  (ADR-0008) this run — never persisted `.claudeCode` kind or terminal-view existence. The gate aimed a
  shell-metacharacter canary at a Claude row that drops to a bare shell (unresumable): it was never
  executed and the dropped comment's screenshots were deleted. A page can no longer get a string into the
  user's login shell.
- **Five gate findings fixed and re-verified before PASS:** the shell-injection/silent-drop path (F1),
  overlay dying on navigation because it mounted before `documentElement` existed (F2), duplicate
  submissions and toggle-storm client leaks (F3), veil pointer events bubbling to the page (F4), and
  orphan screenshots for undelivered comments (F5).
- **Known follow-ups (orthogonal to the feature):** a second co-resident CEF instance can die shortly
  after a Claude terminal pane takes focus (an IMKit/Ghostty focus-path issue, not the browser); the
  Chromium sandbox is still off (blocks notarization); shared `state.json` is last-writer-wins across
  instances (ADR-0010). The comment overlay does not yet pick inside iframes (v1 scope).
## 2026-07-05 — Notifications: in-app deck + Notification Center (both designs + native app)

Background session state changes surface without pulling you out of the session you're in. Two
layers, tiered by urgency, and **only ever for background sessions** (never the open one — the
existing `openSessionID != id` rule).

- **Ambient (layer one, unchanged).** The sidebar dot + unread bullet already carry state. `done`
  (a live session settling to idle off-screen) stays here: the unread bullet plus one soft one-shot
  row pulse — **no toast**. Only needs-input and error escalate.
- **In-app deck (focused window, layer two).** needs-input / error on a background session rise as a
  quiet glass toast, bottom-left, hugging the sidebar — the sidebar indicator *escalated* (same blue
  `?` / terracotta `!`, the workspace chip, the session icon + title, a one-line verb). 2+ collapse
  into a **stacked deck**, most-urgent in front (errors before needs-input, then newest), that **fans
  out on hover**; a "+N" pill past three. Click a card to jump; **⌘↩** jumps to the front (most-urgent)
  card and only that card carries the muted "⌘↩ jump" hint. Driven by `setSessionState` /
  `notifyOnTransition` (HTML) → `AppStore.routeTransition` (app) — the single seam terminals and Claude
  both reach.
- **Notification Center (unfocused window).** Focus (`NSApp.isActive`) picks the surface at fire time;
  unfocused → `UNUserNotificationCenter`. needs-input / error → alert, `done` → a transient banner, all
  at `.active` interruption so **Focus / DND is respected** (never `.timeSensitive`). Grouped by branch
  (`threadIdentifier`), body carries the session identity, a tap activates Synth and jumps. macOS note:
  alert-vs-banner *persistence* is a per-app System Settings choice, not a per-request API — only the
  interruption level is set from code. NC activates in the packaged `.app` (bundle id `tech.holibob.synth`);
  the bare dev binary has no bundle id, so the path cleanly no-ops there.
- **Sound is a per-type Setting** (global scope): needs-input / error / done toggles, defaults on / on /
  off; the default sound attaches to a Notification-Center post iff its type is enabled. In-app toasts
  are silent.
- **Terminal parity.** A companion change makes a plain terminal report its per-command lifecycle
  (running / finished-unread / errored, signal-terminations neutral) over the same hook socket Claude
  uses — injected zsh preexec/precmd → a new `synth-hook report` subcommand — so terminal and Claude
  sessions feed one notification path.
- **Verified** by driving the built app: single toast, a 4-card deck with the error promoted to front,
  hover-fan, ⌘↩-jump (front card opens + its toast clears), the ambient done pulse (no toast), and the
  Settings sound toggles; `swift build` clean. Notification Center is implemented but end-to-end
  unverified in-harness (needs the packaged bundle + a one-time permission grant). Both designs carry
  the identical shell (subset invariant holds: diff is title + the browser/simulator demo rows).

## 2026-07-05 — Notifications follow-up: Notification Center needs a first-run permission grant

Addendum to the entry above, from verifying the packaged app.

- The Notification Center path is confirmed **live in the packaged `.app`** (`build-app.sh` sets bundle
  id `tech.holibob.synth`): on launch the app wires the `UNUserNotificationCenter` delegate and requests
  authorization — none of the dev "no bundle identifier — disabled" no-op. Running the bare SwiftPM
  Mach-O directly is *not* a valid notification client ("Notifications are not allowed"); only a
  LaunchServices launch (`open Synth.app`) is.
- A banner therefore requires a **one-time macOS "Allow"** grant on first launch, plus a real unfocused
  event — neither scriptable in-harness, so the banner itself is verified by hand, not by CI. The
  posting / branch-grouping / tap-to-jump / sound-per-toggle code is reviewed but not exercised
  end-to-end here.
- Dev caveat: the `#if DEBUG` notification triggers exist only in debug builds, which have no bundle id
  (NC no-ops), while the release bundle where NC is live has no triggers. To exercise NC, stage a real
  background event (a session needing input / erroring) while Synth is unfocused.

## 2026-07-05 — Fix: a finished Claude session no longer strands a spurious `?`

The needs-input `?` could linger after Claude Code finished a turn. Root cause is a signal-ordering
race: at end-of-turn both `Stop`→idle and Claude's ambient "waiting for your input" notification
(→needsInput) fire, each as a separate `synth-hook` process writing the socket, each applied on its
own `Task { @MainActor }` — so their arrival order isn't guaranteed. When needs-input landed after
idle, the row was stuck showing `?` on a session that had simply finished.

- **Fix = gate `needsInput` on a live prior state** (`Store.apply`): a `?` is only accepted when the
  session is already working/running/needsInput. A genuine question / permission / plan block always
  interrupts a turn in flight (preceded by `UserPromptSubmit`/`PostToolUse`→working), so it still
  lights; the ambient end-of-turn nudge arrives after the row has settled to idle and is dropped.
- **Why this shape:** the reorder can't be prevented at the transport (separate OS processes race the
  socket), so the reducer is made order-independent instead — whichever of idle/needsInput lands last,
  a finished turn settles on idle. Dropping the nudge also stops it raising a false "needs input"
  attention toast / Notification-Center alert for the finished background session.

## 2026-07-05 — Fix: `/clear` drops the previous conversation's ai-title

Mid-session ai-title refinement already worked (every hook forwards the *latest* `ai-title` from the
transcript; `.titleChanged` updates the row unless hand-renamed). The gap was `/clear`: it starts a
brand-new Claude conversation whose fresh transcript has no ai-title yet, so the row kept showing the
old conversation's name until Claude regenerated one turns later.

- **Fix = reset on a fresh SessionStart.** synth-hook now reads the `SessionStart` `source` and, for
  `startup`/`clear` (a genuinely new conversation), emits a `titleReset` line. `resume`/`compact`
  continue the same conversation and keep their title, so they never reset.
- **App side:** a new `.titleReset` bus event falls the row back to the neutral `Claude Code` default —
  unless the name is hand-picked (`titleIsCustom`), which is preserved across `/clear`. The next
  ai-title from the new conversation takes over normally via `.titleChanged`.

## 2026-07-05 — Keyboard use hides the mouse pointer until the mouse moves

While Synth is driven by the keyboard, the pointer gets out of the way. Every keystroke calls
`NSCursor.setHiddenUntilMouseMoves(true)` at the top of the global keyDown monitor (SynthApp), and
AppKit reveals the cursor automatically on the next mouse movement — the same affordance Terminal.app
and editors use.

- **One hook covers everything.** Terminal keystrokes route through the same local `.keyDown` monitor,
  so typing into a session hides the pointer too. Bare modifiers fire `flagsChanged` (not `keyDown`),
  so a lone ⌘/⇧ never hides it. Native-only — the OS cursor has no meaningful equivalent in the
  working.html/big-picture mock, so the design files are unchanged.

## 2026-07-06 — Browser session, stage four decided: a browser can belong to a Claude session (ADR-0011 amended)

Grilled to a decision set. A browser session can be **contained** by a Claude Code session in the same
branch — true containment, not just a routing pointer — while user-created browsers stay branch-tier
siblings. Slice A (design pass) lands with this entry; slice B is the native port, gated separately.

- **Semantic: true containment, shared-visible.** An owned browser nests under its Claude row and
  lives/dies with it, but stays on the shared surface: `browser_list` returns every browser in the
  worktree (owned rows annotated with their owner), any claude can drive any browser, and the user can
  always take the wheel. Ownership is exclusive only for nesting, cascade, and comment routing — the
  no-headless-twin ethos is untouched.
- **Establishment: create-only + manual re-parent.** `browser_create` stamps the calling claude as
  owner (the launch shim exports the claude session id into claude's env; the MCP server inherits it
  and passes it over the control socket). ⌘K browsers are born unowned. Driving a browser never adopts
  it — structure only changes on creation or explicit user action. Row kebab gains "Move under
  <claude>…" and "Detach".
- **Lifecycle: cascade with confirmation.** Deleting an owning Claude row closes its browsers; the
  confirm names them ("also closes 2 browsers"); Detach beforehand is the escape hatch. Ownership keys
  off the Synth row UUID, so it survives claude exits and `--resume`.
- **Sidebar: nested, same session styling.** Owned browsers render one indent step under their owner
  with the existing session-tier dials — no caret, no collapse state, no fifth visual register. Amends
  the locked three-tier hierarchy to "three tiers + a containment indent".
- **Comment ladder: owner → boot owner → spawn.** Owner live → deliver. Owner dormant → the existing
  boot-and-wait path. Unowned → **always spawn a fresh claude** (replaces the most-active-in-branch
  fallback for unowned browsers), and **the spawned claude adopts the browser** — creation-time
  stamping, so the next comment hits rung one. The hook-liveness security boundary is unchanged:
  submit only after confirmed liveness, including for the freshly spawned session.
- **Spawn moment: silent, stay in browser.** No confirmation — the bar chip reads "→ New Claude
  session" before send, so nothing is hidden. The claude row appears (with the browser re-nested under
  it), boots in the background, receives the standard located-context composition as its first
  message, and takes its ai-title from there. Focus stays on the page.
- **Chosen knowingly:** with an active claude already on the branch, commenting from a fresh ⌘K
  browser spawns a stranger rather than routing to the active one — re-parent first if that's what you
  want. And a ⌘K browser adopted by a spawned claude cascade-deletes with that claude even though the
  browser predates it — the confirm dialog is the guard.
- **External claudes** (running outside Synth in a managed worktree) have no Synth row to own, so
  their `browser_create` yields an unowned sibling. A detached browser is fully unowned again — its
  next comment spawns.
