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
