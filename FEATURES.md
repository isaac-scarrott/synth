# Synth — Features Ledger

Append-only record of features locked into Synth. This file is the **index** — one line per entry,
newest at the bottom; full entries live in per-day files under `docs/features/`. Never edit or
delete an existing entry — if something changes, append a new dated entry that supersedes it and
says so. (Rotating entries verbatim into `docs/features/` is the one permitted move: relocation,
never rewriting.)

**To append:** write the full entry — what the feature is, and the decision/rationale worth
remembering — to `docs/features/<YYYY-MM-DD>.md` (create the file if it's the day's first entry),
and add its one-line index entry below under that date.

**Product ethos:** AI-first, native-to-Mac dev environment. Speed is the top priority — chaining
keyboard shortcuts one after another must feel instant. Simple at a glance, with progressive
disclosure to dive deeper.

---

## [2026-07-03](docs/features/2026-07-03.md)

- **Foundation** — app shell (floating panel, layered shadows), three-tier sidebar (workspaces →
  branches → sessions), the liveness × unread indicator system with collapsed-repo attention
  roll-up, keyboard-first nav, and the animation principles every motion follows.
- **Iconography (Phosphor)** — all sidebar icons switch to Phosphor; attention states become glyphs;
  every right-side indicator centers in one fixed 16px slot.
- **Big-picture shell + branch-group roll-up** — file renamed to `big-picture-design.html`;
  "Workspace" label, sidebar collapse (⌘B), and branch groups roll up their sessions' highest-
  priority state (needs-input > error > working > running).
- **`working.html` (focused subset)** — the heads-down view: identical shell, session list narrowed
  to Claude Code + terminals.
- **Row actions: hover kebab, create, delete (in `working.html`)** — hover ⋯ popover with
  level-scoped actions; delete is a two-step inline confirm.
- **Sync + subset invariant** — working is always a strict subset of big-picture; the files stay
  byte-identical except `<title>` + the extra demo session rows, and the diff is the guardrail.
- **Add workspace** — `+` on the WORKSPACE header opens an add modal; the new repo row is seeded
  with a checked-out `main`.
- **Native app: first working cut (`app/`)** — SwiftUI + `@Observable` app (ADRs 0001–0006) renders
  the shell and spawns real PTY terminals (⌘T); liveness dots driven by real process state.
- **Delete-confirm morphs in place (both designs)** — the popover crossfades + height-animates
  between actions and confirm instead of swapping innerHTML.
- **Command palette (⌘K), Linear-style** — a unified command + jump surface: fuzzy search over
  actions, workspaces, branches, sessions.
- **Content pane: the open session renders (`working.html` + big-picture)** — content is a pure
  function of session type + derived state; exactly one branch group carries the active pill.
- **Command palette becomes a navigation stack (supersedes the flat ⌘K)** — Raycast-style
  drill-down frames with breadcrumbs; create/delete happen inline as text, never a modal.
- **Command palette: frame grouping, context labels, status (refines the nav stack)** — no Reveal
  item, branch-scoped New terminal, live colour-coded status labels, location context shown only
  where not already established.
- **Native app: ⌘K palette ported (navigation stack over the real store)** — frames built from the
  `@Observable` store; every action calls the store's existing mutation paths.
- **Branch rows are real worktree folders; curated add; Remove is UI-only** — ADR-0007: every
  branch row maps to a checkout on disk; multi-select branch picker on add; Remove keeps folders
  and git state.
- **⌘? keyboard-shortcuts sheet** — every binding discoverable in one grouped modal.
- **⌘K opens context-aware to where you are** — the root leads with actions on the open session /
  its branch / its workspace before the generic nav.
- **Explicit focus split: ⌘0 sidebar / ⌘1 session, and click follows focus** — two focusable
  halves; activating a session hands focus straight to the content pane.
- **Every branch is a group shell (uniform chevron alignment)** — all branches render a chevron +
  a (possibly empty) sessions container; presence of sessions is orthogonal.
- **Sidebar dot/chip cleanup** — the checked-out branch dot goes solid; the content pane's state
  chip is removed.
- **Native app: session ⌘K/focus/sidebar batch ported** — context-aware ⌘K, ⌘? sheet, ⌘0/⌘1 focus
  split, uniform group shells, state chip removed.
- **Native app: settings page + Claude Code session type + indicator/kebab polish ported** —
  settings scopes (global + per-workspace worktree script, both-run model), Claude Code on every
  creation surface, idle-indicator + alignment cleanup.
- **Claude Code detected live via hooks (supersedes the creation-time kind)** — ADR-0008: a PATH
  shim + Claude's hooks over a unix socket drive row kind and status live; Claude Code is a
  detected state, not a kind you pick.

## [2026-07-04](docs/features/2026-07-04.md)

- **Rename everywhere: contextual ⌘K Rename + sidebar `r`/`d` (both designs + native app)** —
  inline rename frame seeded with the current name pre-selected; `r` edits in place, `d` opens the
  delete-confirm popover.
- **Dark mode (both designs): system-default, global-only, terminal included** — token-driven with
  a single dark override block; Appearance control on the Global scope only; light mode
  byte-for-byte unchanged.
- **Sidebar batch: ⌘K row actions, resizable sidebar, Esc-to-content (both designs)** — the kebab
  opens the palette drilled to the row; drag-resize 200–460px persisted; Esc hands focus to the
  open session's surface.
- **Native port: dark mode + ⌘K row actions + resizable sidebar + Esc-to-content** —
  `Theme.swift` centralises appearance-adaptive colours; the rest lands 1:1.
- **Tab opens a sidebar group (both designs)** — Tab opens the highlighted group and steps inside
  (superseded two entries below).
- **Sidebar nav: h/l expand·collapse (both designs)** — vim-style aliases for →/←.
- **Tab toggles the group (supersedes "Tab opens a sidebar group")** — Tab toggles open↔closed,
  cursor stays on the group.
- **Native port: Tab toggles group + h/l expand·collapse** — the sidebar-nav additions, in the app.
- **Terminal renderer = embedded Ghostty (libghostty), replacing SwiftTerm** — GPU renderer, real
  font shaping, best-in-class VT; libghostty owns PTY/VT/Metal and Swift is a thin host; config is
  inline-only; hooks unchanged.
- **Sidebar toggle: one stable top-left position (both designs)** — first attempt at a stable
  toggle spot (superseded two entries below).
- **Adaptive terminal theme (both designs): light "paper" / dark card** — a dedicated `--tui-*`
  token family themes the whole terminal palette with the app.
- **Sidebar toggle placement, refined (supersedes the earlier "stable top-left" attempt)** — open:
  sidebar top-right on the traffic-light axis; collapsed: one clean toolbar row, no floating toggle.
- **State persists across restarts (native app; ADR-0010)** — versioned atomic JSON snapshot +
  backup; restored sessions come back dormant; Claude rows reopen with `claude --resume <id>`.
- **Browser session, stage one: a navigable browser in the pane (both designs; ADR-0011)** — one
  page per session, real chrome, "go to" home with recents; engine decision: embedded Chromium
  (CEF) for its CDP endpoint, behind a `BrowserEngine` protocol.
- **⌘K grouping is scope-aware (both designs; refines "frame grouping, context labels")** — browse
  groups context actions specific → broad (Session / Branch / Workspace headers); search order
  becomes Actions → Sessions → Branches → Workspaces.

## [2026-07-05](docs/features/2026-07-05.md)

- **Browser session: DevTools toggle (both designs; ADR-0011 amended + research doc)** — a docked
  DevTools panel toggle in the browser bar; plus a root-cause fix for address-input Enter
  re-rendering the session.
- **Browser session ships in the native app (ADR-0011 stage one, gate-verified)** — CEF 144
  in-pane behind `BrowserEngine`, CDP endpoint live from day one; three-round independent gate,
  all findings fixed.
- **Browser session, stage two: Claude Code drives the embedded browser (ADR-0011)** — a bundled
  MCP server (Node + playwright-core over CDP): instance discovery, session↔target mapping,
  control socket, 13 browser tools, per-worktree `.mcp.json` registration.
- **Stage two gate-verified: a real Claude session drove the browser (ADR-0011)** — 7/7 gate: a
  live `claude -p` created, navigated, and screenshotted a browser while the pane tracked it.
- **Browser session, stage three: user comments flow to Claude as located context (ADR-0011)** —
  comment mode: pick an element on the live page, comment; a CDP binding + page overlay compose
  screenshots and located context, delivered to the branch's Claude session via its PTY.
- **Stage three gate-verified: click-to-comment closes the human→Claude→code loop (ADR-0011)** —
  gate PASS after five findings fixed; security boundary verified: page-controlled strings can no
  longer reach the user's login shell.
- **Notifications: in-app deck + Notification Center (both designs + native app)** — background
  needs-input/error escalate to a stacked glass toast deck when focused, Notification Center when
  not (Focus/DND respected); per-type sound settings; terminals report command lifecycle over the
  hook socket too.
- **Notifications follow-up: Notification Center needs a first-run permission grant** — NC is live
  only in the packaged `.app` and needs a one-time macOS "Allow"; the banner is verified by hand,
  not CI.
- **Fix: a finished Claude session no longer strands a spurious `?`** — the Stop/needsInput socket
  race is made order-independent: a `?` is only accepted while the session has a live prior state.
- **Fix: `/clear` drops the previous conversation's ai-title** — a fresh SessionStart
  (startup/clear) emits `titleReset`; hand-picked names are preserved.
- **Keyboard use hides the mouse pointer until the mouse moves** — every keystroke calls
  `NSCursor.setHiddenUntilMouseMoves(true)`; native-only.

## [2026-07-06](docs/features/2026-07-06.md)

- **Row ⋯ frames carry the branch's session creates (both designs + native app)** — a workspace's
  dots gain New terminal / New Claude Code / New browser on its active branch, a session's dots
  gain them as siblings on its own branch (ctx chip names the branch); still a scoped slice of ⌘K,
  never the global actions.
- **Terminal "finished" joins the notification deck; cards widen to 320px (both designs + native
  app)** — a background terminal/browser settling live→idle now raises a transient green-✓
  "finished" toast (auto-dismisses in 6s, ranked error > input > done); Claude's done stays
  ambient; plus harness seams `automation.notifs` and `SYNTH_STATE_DIR`.
- **Every session kind auto-names its row** — terminals take the running command (0.5s-gated, via
  `synth-hook report --title`), browsers take the page title falling back to host+path, and Claude
  rows work again: inherited `CLAUDE_CODE_*`/`CLAUDECODE` markers made spawned claudes transcript-
  less "child sessions" (no ai-title ever), now scrubbed in `HookEnvironment.decorate`. Hand-picked
  names stay frozen (`titleIsCustom`).
- **Sidebar indicators: soft glow + entry pop, one shared axis (both designs + native app)** —
  liveness dots trade the hard halo ring for a two-layer blurred glow; every indicator slot
  spring-pops in on appear/state-swap (reduced-motion aware); branch/workspace/session levels now
  share one fixed 16×16 `Ind` slot so indicators and ⋯ kebabs align all the way down.
- **Claude's done now raises a transient toast (both designs + native app)** — a background Claude
  session settling to idle gets the same self-dismissing green-check done toast as terminals and
  browsers (was ambient-only: unread bullet + row pulse), matching the "Claude finished" banner the
  unfocused Notification Center path already posted.
- **Browser rows carry no status indicator (both designs + native app)** — the never-changing green
  "running" dot is gone: browser sessions stay status-less for life (empty indicator slot, no done
  toast, no roll-up contribution); the engine-mount status post is replaced by an observable
  generation counter that keeps the reentrant-render nudge.
- **`d` deletes through the ⌘K confirm frame (both designs + native app)** — the `d` shortcut now
  opens the palette's delete-confirm frame (one confirm surface, shared with the kebab and palette
  flows); the inline row confirm popover is unreachable legacy.
- **Terminal accepts file/text drops (native app)** — dropping Finder files onto a terminal pastes
  their shell-quoted paths (dropped text pastes as-is), so dragging an image into a Claude Code
  session hands it the path, matching Terminal/Ghostty/iTerm.
- **Browser ⌘K Page group, page shortcuts, and a home-page ⌘K hint (both designs)** — a browser
  session's ⌘K leads with a Page group (Go to address ⌘L, Reload ⌘R, Back/Forward ⌘[/⌘], Copy
  URL, Open in default browser, Show/Hide DevTools ⌥⌘I) that drives the visible toolbar controls;
  the shortcuts are real window-wide bindings (+ ⌘? Browser group); the browser home surface
  hints "Press ⌘K for quick actions".
- **A clean exit closes its session; the done toast outlives the row (native app)** — a session
  whose child exits cleanly closes itself after raising its self-dismissing done toast (which
  snapshots its display state); a failure keeps the row showing the error; Claude sessions `exec
  claude` so claude's end is the child exit, and a claude-spawned session never reverts to a
  plain terminal. macOS `login` (libghostty's PTY wrapper) zeroes every exit code, so the true
  status rides the hook socket instead (zshexit hook / the claude shim's spawn-wait-report);
  130/143 (user interrupts) close clean.
- **Removing the selected row drops the cursor up the hierarchy (both designs + native app)** —
  deleting the row under the keyboard cursor re-homes it: session → branch row, branch →
  workspace head, workspace → neighbouring workspace.
- **Browser ⌘K Page group: native port (app)** — the Page group, window-wide page shortcuts,
  ⌘? Browser group, and home ⌘K hint from the designs entry now run in the app, driving the
  toolbar's `BrowserSessionController` (one new seam: `focusAddress()`); plus `SYNTH_AUTOMATION`
  verbs (`key`, `screenshot`, `jump`, …) for verification on TCC-locked machines.
- **Browser session, stage four: a browser can belong to a Claude session (ADR-0011 amended)** —
  true containment on the shared surface: `browser_create` stamps the calling claude as owner
  (⌘K browsers born unowned; Move under…/Detach re-parent by hand), owned rows nest one indent
  under their owner and cascade-delete with a named confirm, and the comment ladder becomes
  owner → boot owner → silently spawn-a-claude-that-adopts (replacing most-active-in-branch).
- **Worktree ops never block the app (native app)** — all git subprocess calls move to a per-repo
  serialized background queue; creates show grayed pending rows (spinner, inert, never persisted)
  that activate in place; delete renames the folder aside and drops the row instantly (background
  rm + crash sweep); failures raise a persistent branch·workspace error toast; sidebar and
  branch-picker lists go lazy so hundreds of rows stay instant.
- **Branch-name inputs turn spaces into dashes as you type (both designs + native app)** — ⌘K's
  New-worktree frame and the Create-worktree dialog's Branch name field rewrite live (space→dash,
  leading whitespace dropped, pasted runs collapsed, caret preserved); rename and all other
  inputs keep their spaces.
- **New worktree sessions: a per-scope template names the sessions every worktree starts with
  (designs + native app)** — Settings gains an ordered, drag-reorderable list of kind+name entries
  (first one opens) with a live sidebar-subtree preview; a workspace's list replaces global outright,
  empty inherits (the flags model). Native app persists the template; spawn-on-create isn't wired yet.
- **New worktree sessions template now spawns (both designs + native app)** — creating a worktree
  (⌘K / dialog, new or existing branch) spawns the scope's template once the checkout lands: first
  session opens, the rest wait dormant until first opened; a non-stock template name spawns
  title-frozen so auto-naming never overwrites it. Adding a workspace (importing existing branches)
  deliberately doesn't spawn.
- **Agent-created browsers don't steal focus (native app)** — `browser.create` (MCP) and popups
  from claude-owned browsers now appear quiet: unread bullet in the sidebar, pane/cursor untouched,
  engine booted detached so the CDP target still appears immediately. Popups from unowned browsers
  (real user clicks) still open in front.
- **Browser tools target sessions explicitly (MCP server)** — every action tool takes an optional
  `sessionId` that overrides the focused session without moving it, because one server process
  serves a Claude session *and* its sub-agents (no caller identity in MCP) and a process-wide
  focus pointer had concurrent agents driving each other's browsers; superseded CDP connections
  now retire on a delay so a reconnect can't kill another agent's in-flight call.

## [2026-07-07](docs/features/2026-07-07.md)

- **⌘K rationalised — one vocabulary, five laws** — every palette label/order/affordance now falls
  out of fixed rules: navigate by *branch* and say *worktree* only for on-disk create/delete
  (Create worktree… / Delete worktree), Add workspace… matches the dialog, Remove≠Delete stays
  deliberate (ADR-0007) and every confirm states its consequence; ellipsis iff you must type or
  open Settings; bare verbs under a naming crumb (no "Rename synth…"); order create→navigate→
  modify→destroy-last. Nav category frames become pure lists; the redundant bulk delete-pickers
  (and dead `deletePicker`) are gone. Both designs; subset invariant preserved.
- **⌘K drops the ellipsis (refines the entry above)** — action labels become plain verbs
  (`Rename`, `Create worktree`, `Settings`); the `…` menu-bar convention is dead weight in a
  keyboard palette where Enter reveals the next frame instantly.
- **⌘K hardened by a fresh-eyes focus group (11 personas)** — ranking now lets an exact/name match
  beat loose-subsequence + actions (no destructive on the Enter line), fresh open pre-selects nothing,
  active Delete stays red in dark, the branch-remove fork defaults to the safe row, consequence copy
  is a visible wrapping line, Esc pops one frame; plus a Recent (frecency) group, "New branch"
  create wording, ⌘T new-terminal, and browser-ownership verbs inline in ⌘K. A11y ARIA/focus-trap
  deferred. Both designs; invariant held.
- **⌘K final polish (focus-group follow-ups)** — real focus trap + focus-restore (the copy is now
  true), reversible Remove de-emphasised so red only ever means destruction, worktree-remove clarifies
  the branch survives, new-branch create shows base + on-disk path in one quiet line, and the retired
  popover menu (JS + `.menu` CSS, ~11 KB) is deleted. Both designs; invariant held.
- **Native app: ⌘K session work ported** — the whole ⌘K rationalization + focus-group hardening now
  runs in SwiftUI on the real store: New branch / Add workspace / bare verbs, Remove≠Delete colours,
  name-beats-action ranking, fresh-open-highlights-nothing, wrapping consequence note, Esc-pops, Recent
  frecency group, ⌘T in the sheet; dead popover-menu deleted (~500 lines net removed). Behavior verified
  over the control socket; fidelity audit 13/14, 5 gaps fixed.
- **In-app feedback (⌘⇧F) — one textbox that forks (both designs + native app)** — ⌘⇧F (also a ⌘K
  action + ⌘? row) opens one textbox; ⌘↵ sends, Esc dismisses, draft persists. Resolved once at
  launch by git identity: the author turns a gripe into a real `feedback/<slug>` worktree with a
  Claude session already working it (reusing lazy worktrees + CommentMode's live-Claude PTY
  delivery, seeded with the text + structural context); everyone else gets a pre-filled
  `mailto:isaac.scarrott11@gmail.com`. Context is captured silently, allowlisted to scalar facts
  (session kind/status/counts, theme, version/OS) — never file contents, paths, terminal output,
  env or clipboard; the email attaches only version/OS.
- **Worktree creation switches optimistically; a slow checkout never yanks the pane (both designs + native app)** —
  the content-pane switch now rides the create keystroke, not the async `git worktree add`: creating
  a worktree shows a "Setting up worktree…" skeleton at once, and when the checkout lands it resolves
  in place *only while the user is still parked there* (`openSetupBranchID`); if they've moved on the
  ready worktree announces itself with the quiet unread bullet instead of stealing focus
  (last-intent-wins). Empty templates settle onto the bare row; failures keep the existing error toast.
- **Clicking a terminal link now opens it, routed by host (native app + both designs)** — the
  libghostty `OPEN_URL` action was unhandled, so clicked links went nowhere. Now handled, with a
  host-aware default: a loopback dev-server page (`localhost`/`127.0.0.1`/`0.0.0.0`/`[::1]`/
  `*.localhost`) opens in Synth's own browser — owned by the clicking Claude session, one row
  reused across clicks — so the agent can drive the exact page the human sees; every other web URL
  and every non-web scheme (`mailto:`/`file://`/`vscode://`…) goes to the OS default browser, which
  keeps the user's real auth and matches every macOS terminal. Browser toolbar gains an
  open-in-default-browser icon button (the ⌘K action, surfaced) next to DevTools.

## [2026-07-08](docs/features/2026-07-08.md)

- **Owned browsers are siblings with a Claude mark, not nested (ADR-0011 stage four, revised; both
  designs + native app)** — a browser owned by a Claude session no longer indents one step under
  its owner; it sits as a plain sibling on the shared session indent and carries a small accent
  Claude sparkle (12px, `session__icon--ai` terracotta) in its right-hand indicator slot instead —
  mirroring the owner's icon so the mark reads "belongs to Claude." Browsers are status-less, so
  this reuses the otherwise-empty slot and stays on the shared right axis; the row still sits
  directly beneath its owner and the tooltip names it ("… · belongs to Claude Code"). Adopt/detach
  animate the mark, not a margin (`.ind--owned` carries the tie; `.session--owned` drops its indent).
- **Unread roll-up indicator for a collapsed worktree/branch (both designs + native app)** — a
  collapsed row surfaced its live states (needs-input / error / working / running) but not a
  session that had simply *finished off-screen and not yet been seen*; that fell through to
  last-activity text, so a row with output waiting looked like one with nothing. Unread now joins
  the roll-up one rung below liveness (input > error > work > run > **unread** > idle): it surfaces
  only once the group has settled to idle, and only while collapsed. Shown as a flat blue dot (the
  row's gutter bullet, `--input` / `Theme.attention`, no glow) — setting the roll-up's grammar:
  dots = ambient status, glyphs = needs action, glowing/pulsing dots = live. Both designs (subset
  invariant held) + native (`Branch.hasUnread` + `UnreadDot` in `BranchRollup`); verified in the
  browser and by driving the built app over the control socket. En route, removed a duplicate
  top-level `const ICON_EXTERNAL` in `working.html` that was a SyntaxError silently killing the
  whole page script.
