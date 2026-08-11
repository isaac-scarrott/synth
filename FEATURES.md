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
- **⌘K root shows one scope, not the whole ancestry (both designs; refines "grouping is scope-aware")** —
  the root frame's context block is now just the innermost focused level (Session *or* Branch *or*
  Workspace verbs), never all three stacked; the enclosing branch/workspace demote to a new **Go to**
  group of jump rows that drill into their own frame where their actions live. Acting on a parent is a
  deliberate step up, not a careless-Enter neighbour. Also fixed a duplicate `const ICON_EXTERNAL`
  merge artifact whose top-level `SyntaxError` had been killing the whole palette script.
- **Two build channels (Stable / Dev) + generated app icon** — `dist.sh` builds/installs the stable
  "Synth" (`tech.holibob.synth`) to `/Applications`; `dev.sh` builds "Synth Dev"
  (`tech.holibob.synth.dev`) for the live loop; a shared `lib.sh` keeps their bundles identical.
  `AppSupport.root` keys the Application Support sandbox off `CFBundleName` so the two coexist without
  colliding (state, worktrees, browser profiles, instances all isolated; `SYNTH_SUPPORT_DIR` /
  `SYNTH_STATE_DIR` overrides preserved). Icon is a Higgsfield-generated "liquid swirl" gradient in
  Synth's own accent hues (stable full-colour, dev amber), masked to a squircle and built to
  `AppIcon.icns`. Icon art is a champagne-on-charcoal "synthesis of instruments" mark (equalizer pins
  + violin-scroll curls); `app/icon/mockicon.swift` keys the mark, composites it at 74% on a clean
  charcoal squircle (no rim), and retints it amber for the dev variant (deterministic, no AI redraw),
  packed by `build-icons.sh`. The dev build also shows an amber "DEV" pill top-right
  (`.dev-tag` / `is-dev` in both designs; `DevTagBadge` gated on the `.dev` bundle id natively), absent
  on stable. Distribution to teammates via a private Homebrew cask (ad-hoc + quarantine strip,
  notarization later) is decided but not yet built. Verified: both channels built, launched, and
  running side by side; DEV tag confirmed in the design over CDP.

## [2026-07-09](docs/features/2026-07-09.md)

- **An agent can close the browsers it opened (`browser_close`; ADR-0011 stage two + four,
  extended)** — `browser_create` had no counterpart, so every browser an agent opened to check its
  own work outlived the turn and silted up the sidebar. New MCP tool + `browser.close` control verb
  (same path as deleting the row), with the norm written into the tool description: close what you
  opened only to check your own work; leave open what you opened *for* the user to see or comment
  in, and say so. Permission falls out of stage-four ownership rather than a new concept — a session
  may close what it owns and nothing else, so ⌘K browsers (unowned = the user's), detached or
  re-parented browsers, and external claudes (no Synth row) are all refused with their own message.
  *Rejected:* any-claude-closes-any-browser — the shared surface means any claude may **drive** any
  browser, but driving isn't destroying. One extra guard: a close is refused while comment mode is
  `engaged` (covers the in-flight CDP attach), since the user is composing the very thing that would
  be deleted. `sessionId` required, no implicit "close the focused one". Verified against a running
  app with a live CEF engine, over both the control socket and the real MCP server on stdio.
- **The storefront palette is derived from the app icon (both designs)** — sampled `AppIcon-source.png`
  rather than eyeballing it: the mark is `#eedfcc` (`hsl(34,50%,87%)`, cream not gold) and the squircle
  runs `#282b30 → #15181c` at a steady hue 223° / ~10% sat — the charcoal was never neutral. Surfaces
  are now the squircle's own gradient (`--raised` is its top stop, `--canvas` one past its bottom).
  All 19 iOS-system-blue call-sites are gone; champagne is the accent and stays scarce — selection,
  focus, ⌘K active row, send, awaited reply — with `--accent-rgb` backing every alpha wash so hue flips
  per theme without geometry moving. Light mode can't use the mark (fails contrast on white), so it
  takes a copper `#a86038` plus a new `--on-accent`. `--work` amber sits 4° from champagne, so it stays
  byte-identical, the copper clears it by 15°, and blue survives only as `--input` — a desaturated
  sibling of the charcoal's 223° hue, meaning "needs you", never brand. Workspace avatar chips muted
  onto the palette (34% sat, ≥15° from every reserved colour, ≥27° apart, ≥4.6:1 white letter) — identity
  survives, the shouting doesn't. Eight near-identical faint greys (within 5% lightness, several at
  ~2.4:1) collapsed into one `--ink-meta` at 4.63:1 — the only change that isn't a pure retint.
  *Rejected:* champagne-only chips (workspaces stop being distinguishable at a glance) and champagne as
  the needs-input state (collides with selection, drags back toward amber). Colour literals only: 117
  lines, no shadow offset, radius, border width or easing moved.

- **One 50pt titlebar band, and the traffic lights moved onto it** — the top strip was cramped and
  its tenants disagreed on where the top of the window was: the lights sat inside the 14pt corner
  radius, the collapse toggle centred 25pt from the sidebar's trailing edge while the `+` sat at 27
  and row indicators at 24, and the sidebar strip and pane header were near-misses (44/44/30pt),
  putting lights, pane title and DEV tag on three centre lines. Now one token (`--titlebar-h: 50px`
  / `Theme.titlebarHeight`) sizes the sidebar strip and all three pane headers, the lights take the
  macOS-standard 20pt inset centred at y=25, the toggle grows 26→28pt onto the sidebar's shared 24pt
  control axis (the `+` moved 3pt to join it), and collapsed the expand toggle sits at 82 with the
  title at 122. The lights are AppKit's: `.hiddenTitleBar` puts them at x=8/y=14 in a 28pt titlebar.
  *Rejected:* an empty unified `NSToolbar` (AppKit re-centres them for free, but its `NSToolbarView`
  swallows every click across the band, killing the toggle) and moving the buttons without growing
  `NSTitlebarView` (they draw but stop hit-testing outside its bounds). `WindowChrome.swift` grows
  the titlebar container and re-places the buttons inside it; the container is hit-transparent
  except on its widgets, so our band keeps its clicks and still drags the window, and AppKit's
  relayout reset is healed from the frame-change notification it posts. Fullscreen left to AppKit.
  Verified on the real app: circles at x=20/40/60 ⌀12 centre y=25, toggle 24.0pt from the edge on
  the same line, header hairline at y=49.5, and close/toggle hit-testing intact across a resize.
- **Synth hosts more than one coding agent: OpenCode joins Claude Code (ADR-0012; both designs +
  native app)** — `SessionKind.claudeCode` becomes `.agent(AgentID)`, so which agent a row hosts is
  data, not a case: adding a third agent is one `AgentDescriptor` + one `AgentSupervisor` and nothing
  else. Claude Code keeps its manufactured surface (PATH shim → injected `--settings` hooks → unix
  socket, ADR-0008); OpenCode is *subscribed to* instead — its own `/event` SSE bus drives status,
  title and needs-input, and text is delivered through its TUI prompt API rather than a paste+Enter.
  Liveness is now asserted by the supervisor (`.agentReady`), never by the launcher, because a
  launched-but-unreachable agent silently swallows a browser comment (and, for Claude, a paste into a
  fallback shell is arbitrary execution). Per-agent flags in Settings, per-agent notification copy,
  one create row per installed agent, per-agent browser-MCP registration (`.mcp.json` vs
  `opencode.json`), and a persistence migration that keeps old trees and resumes intact.
- **The coding-agent gate: everything the port claimed, driven end to end (`app/harness/agents/`)** —
  eight suites / 73 checks against a real CEF build over the control socket: template spawn, true
  conversation resume (`opencode --session <id>`), background done + needs-input toasts, per-agent MCP
  registration, a live OpenCode agent driving the embedded browser via `browser_navigate`,
  click-to-comment reaching its owning agent, abort-is-not-an-error, and Claude's hook path unchanged.
  Adds two `SYNTH_AUTOMATION` seams (`automation.notifRoute`, `automation.createWorktree`) and a
  fail-fast CEF guard. Surfaced a pre-existing truth: **a Claude row in a brand-new worktree stalls at
  Claude's "trust this folder" prompt** (Synth's own `.mcp.json` triggers it), so it is never live and
  never a comment/feedback target until answered; OpenCode has no such gate. Left unfixed on purpose —
  pre-accepting trust is a security decision.
- **Each agent wears its own official mark; OpenCode is spelled the way it spells itself** — labels
  become "OpenCode" (the command stays `opencode`, as does the persisted `AgentID`). `AgentDescriptor`
  gains a `mark` and one `SessionIcon` view chooses every session icon: Claude Code renders **Clawd**,
  pixel-exact from the sprite `claude` draws on startup (no vector exists), and OpenCode renders its
  **official square mark** in the brand's own light/dark colour pairs rather than Synth's terracotta.
  An owned browser now mirrors its owner's mark instead of a generic sparkle. Proving it surfaced a
  crash: a client that hung up before reading a control-socket reply killed Synth via `SIGPIPE` — any
  local process could take the app down. Now ignored at process entry.
- **Reverted: "⌘K root shows one scope, not the whole ancestry"** — `a93d280` backed out of both
  designs and the native app; the root frame stacks Session + Branch + Workspace verbs again and the
  **Go to** parent jump rows are gone. The earlier `ICON_EXTERNAL` SyntaxError fix and the OpenCode
  agent registry are both preserved across the revert; the workspace scope's Settings / Rename /
  Remove, which that commit had added, go away with it.
- **The terminal palette is its own contract, and light mode owed it 4.5:1** — the icon retint
  darkened `--tui-bg` and quietly pushed light-mode `green`, `white` and `dim` under the ≥4.5:1
  contrast floor that `TerminalTheme.swift` promises; repaired to `#1c7d40` / `#6c6c76` / `#696c76`
  (green tightest at 4.51), solving white and dim together so bright-black stays dimmer than white.
  The selection colours stay put in both themes: dark `#333a48` already sits in the retinted slate's
  hue family, and warming the light selection loses contrast against every ANSI hue. The twelve
  chromatic ANSI slots do not follow the accent — they answer to the programs running inside the
  terminal, not to Synth's brand.

## [2026-07-10](docs/features/2026-07-10.md)

- **Worktree create trusts the outcome, not the exit code** — `git worktree add` runs the repo's own
  `post-checkout` hook after the checkout has landed, so a failing hook (holibob's husky `pnpm
  install` finds no pnpm on a GUI launch PATH, exits 127) failed the whole create while leaving a
  fully materialised checkout behind: row dropped, error toast up, orphaned worktree + branch making
  the retry fail with "branch already exists". Now a non-zero `worktree add` is only an error when
  the worktree really isn't registered at the planned path on the requested branch — a hook's
  complaint goes to the log, and a retry resolves to the orphan an older failure left. Synth's
  contract is the checkout; the repo's hooks are the repo's business. Verified by driving the real
  binary over the control socket against a repo with a failing hook, both with the fix (ready row,
  no toast) and without (the reported failure, caught).
- **The user-facing taxonomy is settled, and every surface speaks it (ADR-0013)** — one noun per
  thing, one verb per consequence. Workspace becomes **Project** (it collided with *worktree*, one
  level down); the ⌘K surface stops naming itself three ways and becomes the **Command menu**;
  **Remove / Close / Delete** split by consequence and **red now means loss, not disk** (a busy Close
  wears it, a Remove never does, the glyph follows the word: trash destroys, minus drops a row, ×
  closes); `running` + `working` merge into one amber **Busy** dot, pulse deleted; toast becomes
  **Notification**; "Move under" becomes **Attach to** (the indent it promised went away on 07-08);
  you create a **New branch** and delete a **worktree**, and the asymmetry is load-bearing. **Agent**
  is now sanctioned vocabulary, which surfaced a real lie: comment mode's chip said "New Claude
  session" while the code spawns `AgentRegistry.default`. Internal symbols keep their old names.
  Swept across both designs (invariant held), 14 Swift files, and the storefront (all twelve product
  screenshots re-shot); every close path adversarially checked.
- **Gate-verified: ADR-0013's close semantics, driven against a real build (`app/harness/taxonomy/`)** —
  17/17 against a real CEF build and real OpenCode agents: an idle session closes with no dialog, a
  busy one confirms in red (`danger=[True, False]`), and an idle one owning a browser confirms
  without red (`danger=[False, False]`). `automation.palette` gains a `danger` array, because a rule
  nobody can observe is a rule nobody can keep. The 07-09 amber/champagne worry is measured and
  retired: 6.7° of hue apart but ΔE 65, and the busy dot clears 8.13:1 on the sidebar.
- **Signed, notarized, self-updating releases (`dist.sh` + `release.sh`)** — Developer ID + hardened
  runtime + notarization replace the `xattr -dr com.apple.quarantine` handshake; Sparkle 2.9.4 ships
  the appcast, with binary deltas so an update is a few MB against a 144MB bundle. Three latent bugs
  fell out: the bundle id claimed `tech.holibob.synth` for a personal project (now
  `io.github.isaac-scarrott.synth`), `CFBundleVersion` was a git short hash Sparkle cannot order (now
  a commit count), and `codesign --deep` cannot give CEF's renderer the `allow-jit` entitlement it
  needs to survive the hardened runtime (now signed inside-out, per-binary). Dev channel gets no
  `SUFeedURL`, so it never updates itself into a release build. Source stays private: artifacts go to
  a public Tigris bucket on Fly.io, because Sparkle downloads anonymously and a private repo's assets
  404 for it. Object storage over a second GitHub repo buys one flat prefix that serves every version
  forever, so no appcast enclosure needs rewriting per release. `release.sh` uploads binaries, proves
  an unauthenticated `curl` can read the new zip, and only then publishes the appcast naming it.

## [2026-07-11](docs/features/2026-07-11.md)

- **The browser MCP server records video (`browser_record_start` / `browser_record_stop`)** — CDP
  screencast frames (verified against CEF, surviving cross-page navigation) replayed onto a
  constant-fps timeline and piped through ffmpeg: H.264 mp4 with a full build on PATH, else VP8
  webm via Playwright's ~2MB bundled build, downloaded on demand. Zero new dependencies; the tool
  returns a file path — video is for the user, the model screenshots instead.

## [2026-07-12](docs/features/2026-07-12.md)

- **⌘N opens the new-session picker** — the ⌘K "New session" frame (terminal / agents / browser)
  for the branch you're in, resolved from context like ⌘T; natively it's `File > New Session…`,
  replacing the stock one-window-app-useless "New Window" binding.
- **Synth 0.2.0 (build 181)** — ⌘N, browser video recording, background updates, and a renderer that
  survives display changes. First release with a prior zip to diff against, so the delta path is
  finally exercised: 610KB delta against a 130MB full download. Note that Sparkle reads its install
  policy from the *running* app, so 0.1.0 users get 0.1.0's prompt-first behaviour on the way to
  0.2.0 — background updates only start being felt on the release after this one.
- **Sidebar tree drops its indent guide lines** — indentation alone carries the workspace → branch →
  session hierarchy; the hairline vertical rules were double-encoding it. Spacing untouched.
- **Synth 0.2.1 (build 185)** — patch shipping the sidebar indent-guide removal. First release
  updated *to* via 0.2.0's background-update policy, and first with deltas from two prior builds
  (497KB/622KB against a 130MB full download).

## [2026-07-13](docs/features/2026-07-13.md)

- **⌘D closes the current context (both designs + native app)** — one keystroke into the existing
  `d` close flow, resolved from context like ⌘T/⌘N: the ring's sidebar row when the sidebar owns the
  keyboard, else the open session; idle sessions close straight through, anything else confirms in
  ⌘K. Listed in ⌘? and as the key hint on ⌘K's Session Close; natively it's File > Close Session.

- **Session Close always confirms — the idle skip is gone** — an idle Claude Code session held a
  conversation worth losing, so the "idle and unowned closes with no prompt" carve-out above is
  removed: `d`, ⌘D, the ⌘K item, and the kebab menu all now confirm before every Close.

- **synth-app MCP server: approval-gated worktree creation + handoff** — a second bundled MCP
  server that lets agents drive Synth itself: `worktree_create(branch, base?, handoff?)` blocks on
  a native yes/no prompt (Enter creates, Esc declines; decline tells the agent to carry on where it
  is), an optional handoff brief seeds one Claude session in the new checkout via the feedback
  loop's delivery path, and Settings gains an "MCP servers" section — browser server on by default,
  app server off, with disabled servers reconciled OUT of every worktree's agent configs.

- **Synth 0.3.0 (build 191)** — minor carrying ⌘D close-context and the `synth-app` MCP server: the
  first release where an agent can drive the app itself, so it ships with the app server OFF and an
  explicit Settings opt-in. Six deltas / 3.9MB against a 132MB download; also untracked a committed
  `.pyc` that had been silently dirtying the tree against `release.sh`'s clean-tree guard.
- **synth-app MCP approval moves into ⌘K (supersedes the 0.3.0 modal)** — the agent-worktree
  approval prompt was the one action in the app that popped a modal sheet instead of the ⌘K confirm
  frame every other create/delete/confirm uses; now it's `PaletteModel.confirmAgentWorktree`, with
  `presentedAgentPromptID` preserving the old rule that closing it (Esc/⌘K/backdrop) declines, and
  queued prompts chaining automatically. `AgentWorktreeSheet` is deleted.
- **Fix: a hidden, stationary pointer could steal keyboard nav (native app)** — `AppStore.pointerStale`
  gates the ⌘K row hover, the sidebar's ring-dismiss-on-hover, and the notification deck's
  hover-to-fan, so a layout change scrolling a view under the pointer's last real position (hidden
  via `NSCursor.setHiddenUntilMouseMoves`) can no longer masquerade as a genuine hover.
- **Browser device mode (⌘⇧M): the page in a device frame (both designs)** — a fourth toolbar
  mode beside comment/DevTools/external: the page renders inside a hardware frame at a real
  device viewport, with a strip spanning the fleet smallest→biggest (iPhone SE 375×667 → iPad
  Pro 13″ 1032×1376), live CSS-point dims readout, rotate; frame scales down to fit, never up;
  composes with comment mode + DevTools, survives navigation; ⌘K Page group + ⌘? row.
- **Native port: browser device mode (⌘⇧M), CDP-emulated viewport** — the SwiftUI frame/strip
  port plus a real emulated viewport: `DeviceEmulator` drives CDP `setDeviceMetricsOverride`
  (mobile + per-device DPR + fit scale) on the session's page target, proven live (393×852@3,
  1px-exact clicks, survives navigation); clears on exit, frame-only on the no-CDP hedge; no
  mock "9:41" row — the full screen is the truthful live viewport.

## [2026-07-14](docs/features/2026-07-14.md)

- **Device mode: agents drive it too, and rotate stops dressing as reload** — new
  `browser_device_mode` MCP tool over a `browser.deviceMode` control verb (read/set on · device ·
  landscape; naming a device implies on, only `on:false` exits; no ownership gate — driving isn't
  destroying; absolute setters so agents can't race the user); and the strip's rotate control
  becomes the device glyph turned to the orientation a press would give — the circular arrow read
  as a second reload. Both designs + native + MCP server; verified through the full stack.

## [2026-07-15](docs/features/2026-07-15.md)

- **PR indicators: a branch's pull request, in the sidebar and the header** — every branch row
  carries a state-coloured glyph beside its name (green open, purple merged, red closed; merged
  wears git-merge, the rest git-pull-request), and the open session's header carries a clickable
  `#<number>` chip that opens the PR in the user's default browser. State comes from `gh pr list`
  read per repo off the main thread (strongest PR per head branch), derived not persisted, and
  refreshed on launch / add-workspace / app activation; a missing `gh` or non-GitHub repo just
  shows nothing. Both designs (subset invariant held) + native; verified in the running app
  against real GitHub PRs (`cli/cli`), including the `Text(verbatim:)` fix for `#13,874` digit
  grouping.
- **PR indicators gain the queued (merge-queue) state** — a fourth PR state beside open/merged/closed:
  a branch waiting in the merge queue shows the git-pull-request glyph in queued blue (`#0969da` light /
  `#4493f8` dark), in the sidebar and the header chip alike. State stays colour-only, so the header chip
  (which reads state generically) picked it up with no logic change. Both designs (subset invariant held).
- **Copy the branch name from the pane header** — a hover-revealed copy button after the
  `workspace / branch` crumb; one click copies the branch name and flashes a green check
  (`navigator.clipboard` in the mock, `NSPasteboard` native). Both designs + native.
- **Synth 0.4.0 shipped (build 212)** — minor release rolling up everything since 0.3.0 (device
  mode + `browser_device_mode`, PR indicators, copy-branch-name, native notifications from the open
  session, sidebar restyle, ⌘K worktree approval) plus the process-lifecycle/memory hardening.
  Notarized, stapled, 9 deltas (6.9MB) against a 136MB download; verified credential-less and
  installed to `/Applications`.
- **Synth 0.4.1 shipped (build 215)** — no code change over 0.4.0 (only the 0.4.0 ledger doc sat
  between the tags); reissued on request. Notarized, stapled, 367KB delta from 212; verified
  credential-less and installed to `/Applications`.
- **Quit always confirms** — every quit (⌘Q / Quit menu / logout) shows one native "Quit Synth?"
  alert via `applicationShouldTerminate`, the same shape every time: **Quit Synth** (default, Return)
  and **Cancel** (Esc). Only the informative line changes, naming any `busySessions` (agent `working`
  / process `running`) the quit would end. App-only (no in-window surface); reaches the store via a
  new `AppStore.shared` weak ref.

## [2026-07-16](docs/features/2026-07-16.md)

- **Anonymous product analytics (PostHog)** — opt-out, anonymous usage analytics via `posthog-ios`
  (SPM). One seam, `Analytics.swift`, is the only importer of `PostHog`; the app calls
  `Analytics.capture/error/isEnabled/setOptOut`. No `identify()` ever (random per-install id),
  `personProfiles = .identifiedOnly`, lifecycle events on for retention, screen-views off, no
  session replay / surveys (iOS-only). Three gates keep it inert: dev channel never reports, an
  unset placeholder `projectKey` stays silent, and the **Settings → Privacy** toggle
  (`analyticsEnabled`, default on) opts out immediately and from the first launch event. First
  events: `session_created {kind, agent_initiated}`, `worktree_created {from_template}`,
  `feedback_submitted {mode, has_body, length}` (never the text), plus app open/close. EU region.
  App-only toggle (no `working.html` Settings mock; subset invariant untouched). Follow-ups: native
  crash capture (only caught errors covered today) and pasting the real project key once the Synth
  PostHog project exists.
- **Synth 0.5.0 shipped (build 224)** — first release carrying product analytics + the native crash
  reporter, so real usage data starts here (dashboards filter `channel=stable`, excluding earlier
  dev/verification runs). Notarized, stapled, 15 deltas (~18MB) against a 130MB download; verified
  credential-less from the public bucket (spctl accepted / Notarized Developer ID, staple valid,
  appcast newest enclosure `Synth-0.5.0.zip` at `sparkle:version` 224 with `edSignature`).

## [2026-07-17](docs/features/2026-07-17.md)

- **Session layout & pane splitting — design settled in `working.html`** — the content surface goes
  from one open session to a splittable **layout** of panes: drag a session from the sidebar over the
  content area (VS Code / tmux edge drop-zones) or split by chord; nested binary pane tree, one active
  pane (copper ring), no empty panes, a 360×240 min-pane floor. Layout is **owned by the branch** (one
  per branch, persisted, restored on relaunch); full-screening a pane is a transient tmux-style view
  over a remembered split; the sidebar always mirrors the layout as a flat tile band. Full keyboard
  layer: pure Mac-native chords (`⌘⇧`+arrow create, `⌘⌥` focus, `⌘⌥⇧` resize, `⌘⇧⏎` zoom, `⌘⇧U`
  unsplit), no leader. Mouse-only design first, then bindings — both live in both designs (subset
  invariant held). Packaged as a **handoff brief** for `port-working-html` to build natively (that
  native effort is next, not this one).
- **Browser page zoom (⌘+ / ⌘−)** — keyboard zoom for the embedded browser, stepping a fixed ladder
  (25→300%, clamped); ⌘= is the unshifted twin of ⌘+. ⌘-modified (not bare +/−, which a focused page
  would eat); reset stays off ⌘0 (Synth's focus-sidebar) and lives on an omnibox **zoom badge** that
  shows only off 100% and clicks home — doubling as the live readout. ⌘K page group gains Zoom
  in/out/Reset; ⌘? Browser section lists it. Zoom re-applies across navigation (per-tab feel).
  Design only so far (`working.html` + big-picture, subset invariant intact); native `app/` port via
  `/port-working-html` is the follow-up.

## [2026-07-20](docs/features/2026-07-20.md)

- **Agent launch lines are arguments, not keystrokes** — the `exec claude …` line a new agent row
  runs is passed to the login shell as `-c` (via `$SYNTH_LAUNCH_COMMAND`) instead of written into its
  stdin. Queued tty input belongs to whoever reads it first: oh-my-zsh's update prompt takes one
  keypress, ate the leading `e`, and the row died on `command not found: xec` with the handoff seed
  undelivered. Shell-agnostic, still runs after the rc files (shim PATH intact).
- **Synth's shells don't stop to ask about updates** — every PTY carries `DISABLE_AUTO_UPDATE=true`,
  so an unattended session can't strand behind oh-my-zsh's update prompt. Synth's shells only.
- **⌘K is one command menu — the kebab matches the main window, and negative actions are red** — the
  ⋯ kebab / right-click now pins ⌘K's context to the clicked row and shows the same grouped, concise
  root actions as ⌘K on the focused row, retiring the bespoke verbose per-row frame. Red widens from
  the loss signal to the negative-action signal: Close (always), every Remove, and Detach/Attach join
  Delete in red. Supersedes ADR-0013's colour rule in part.
- **Synth 0.6.0 shipped (build 272)** — first release carrying native session layout / pane splitting
  (the 07-17 design, ported across the 009–015 slices), plus browser page zoom, the ⌘K/kebab
  unification + red negative actions, the agent-launch reliability fixes, default-branch/empty new
  worktrees, and the in-app Changelog. Minor bump for the pane-splitting headline. Notarized, stapled,
  15 deltas (19MB) against a 137MB download; verified credential-less (spctl accepted / Notarized
  Developer ID, staple valid, appcast newest `Synth-0.6.0.zip` at `sparkle:version` 272 with
  `edSignature`) and installed to `/Applications`.
- **A split stays within one branch / worktree — enforced, not just documented** — feature 003's rule
  is now a hard interaction-layer guard (`sessionCanJoinLayout`) shared by every split route: a
  cross-branch drag reads red/refuse, a cross-branch pair never highlights, and the ⌘⇧+arrow split
  picker lists only the anchor branch's sessions. Closes the gap where a foreign-worktree pane could
  be built momentarily before the next save silently dropped it.
- **Reorder drags mark their drop slot with a copper insertion line** — no list reshuffle mid-drag
  anywhere (sidebar tree + settings template list): the list holds still, a copper line above the
  drag ghost marks the landing slot (hidden when the drop is a no-op), and the reorder commits on
  release — restoring the placement feedback lost when the unified session drag moved to
  commit-on-release.

## [2026-07-21](docs/features/2026-07-21.md)

- **The sidebar's split band survives switching branches / workspaces** — the split echo (012) is
  per-branch: a background branch's band renders from its remembered `Branch.layout` (the tree a
  member click restores, 014) instead of dissolving when another branch takes the surface; its
  tiles' Unsplit / drag-out-to-unsplit keep working from the background. App-only — the
  `working.html` echo (single band, current branch) is a follow-up.

- **Split focus is a top-edge bar in the mark's colours** — the active pane's copper ring (004 §4)
  is superseded by a 2px top-edge bar in a new `--focus` token (charcoal on light, champagne on
  dark), ends inset by the app radius so it clears the shell's rounded corners; sweeps in from
  the left while the old pane's bar fades. Design files done; app port rides with the
  split-focus click fix.

- **Toasts anchor to the shell's corner and drain a countdown bar** — the notification deck moves
  to the bottom-left of the whole shell (over the sidebar, one fixed home whatever the sidebar or
  splits do), and a self-dismissing toast carries the focus bar's grammar as a clock: a 2px
  `--focus` bar along its bottom edge draining left over its lifetime, dismissal riding the bar's
  `animationend`; hover pauses it. Sticky toasts (input / error) carry no bar.

- **Unfocused notifications raise the toast as well as the banner** — the deck toast is raised
  for every background transition regardless of focus; unfocused, Notification Center posts on
  top of it, and the toast waits in the deck for focus to return. Losing focus joins hover as a
  brake on the done toast's drain clock — it only counts down while Synth is frontmost.
  `automation.notifRoute` now pins the focus rule (deck-only vs deck + NC). App change; design
  files comment-only (the mock is always "focused").

- **Closing a session drops you back to the one you were on before it** — sessions you view stack
  up (016); a close that would leave an empty surface pops the stack and opens the last live
  session you were on, across branches if need be. Splits are unchanged (the sibling still
  reflows). Also fixed: the row-exit handler ran twice and re-aimed the keyboard cursor at the
  closed row's parent.

- **Synth 0.7.0 shipped (build 293)** — this window's split + notification refinements on the 0.6.0
  pane-splitting base: corner-anchored toast deck with a draining countdown bar (hover / lose-focus
  brakes, raised-when-unfocused), the split-focus top-edge bar with click-to-focus, the per-branch
  split band surviving branch/workspace switches, the copper reorder drop line (sidebar + templates),
  single-branch split enforcement, and the keyboard two-pane Changelog. Minor bump for the new
  toast/countdown and split-focus surfaces. Notarized, stapled, 15 deltas (23MB) against a 137MB
  download; verified credential-less (spctl accepted / Notarized Developer ID, staple valid, appcast
  newest `Synth-0.7.0.zip` at `sparkle:version` 293 with `edSignature`) and installed to `/Applications`.
- **Crash reporting actually reports** — libghostty statically links sentry-native, whose Breakpad
  claimed the task's Mach exception ports and swallowed every crash (Mach preempts POSIX signals),
  leaving `CrashReporter`'s handlers dead from first terminal use. `GhosttyApp.start()` now runs
  before `Analytics.bootstrap` so PostHog's PLCrashReporter layers on top and chains back; the
  signal-marker path stays as a backstop.
- **Synth 0.7.1 shipped (build 294)** — patch release, two crash fixes on 0.7.0. The now-working
  crash reporting caught a Bluetooth `SIGABRT`: an embedded engine (CEF Web Bluetooth / libghostty)
  probes the radio and TCC hard-aborts an app with no `NSBluetoothAlwaysUsageDescription`.
  `write_info_plist` now emits the key. No user-facing surface change.
- **Liveness is a five-bar wave, not an amber dot** — the running / working indicator (sidebar
  rows, collapsed roll-up, the agent transcript's in-progress line) becomes an amber five-bar
  level meter breathing on a 1s cycle; the level meter is the loading shape an app named for a
  synth should use, and movement separates "live" from the flat unread dot by more than hue.
  Landed in both design files and the native sidebar.

- **Liveness becomes a cyan diamond beat** (supersedes the five-bar wave above) — the running /
  working indicator is a 5×5 lattice beating from the center outward as a diamond wavefront, in a
  new per-theme `--live` cyan (deep on light, bright on dark) that stops the indicator reading as
  Claude's amber mark inside Synth's own chrome. The dormant lattice stays visible between beats —
  an indicator that blinks out of existence makes a slow session look dead.

## [2026-07-22](docs/features/2026-07-22.md)

- **Synth 0.8.0 shipped (build 303)** — minor bump for the cyan diamond beat replacing the amber
  liveness dot. Notarized, stapled, verified credential-less; 0.7.1 users take a 697KB delta.
  Also folded the published-but-unmerged `v0.7.1` into main first: main had a higher build number
  but was missing that release's two crash fixes, so shipping from it would have auto-installed
  the regression everywhere.
- **Synth installs from a disk image (0.8.1, build 307)** — the download is now a `.dmg` with an
  `/Applications` drag target, ending the run-from-Downloads translocation that hid Synth's own
  `synth-hook` from it. Image and app are each notarized and stapled separately, since a
  dragged-out copy carries no trace of the image; Sparkle keeps its zip. Also documented the
  hand-sync from `landing/` to the separate `synth-site` deploy repo.
- **The release tag names the commit that was built** — `release.sh` pinned the commit before
  building instead of reading `HEAD` after Apple's ~20-minute wait, where a commit made meanwhile
  silently retargeted the tag onto a build that never shipped.
- **The liveness indicator is a sphere, in violet** — the cyan 5×5 lattice read as the slate-blue
  needs-input `?` at 14px, so liveness took the one hue nothing else on the right axis claims. The
  corners drop out and the dots shrink and darken toward the rim, so the mark reads as a ball lit
  from its near face; the beat now travels out by radial distance, not Manhattan, so its wavefront
  is a circle rather than a diamond. HTML and SwiftUI both.
- **Synth 0.8.2 shipped (build 312)** — the violet sphere liveness indicator reaches installed
  copies, so working and needs-input can no longer be mistaken for each other at a glance.
- **The browser MCP server survives a loaded engine** — an engine holding ~35 CDP targets broke
  every browser tool behind one opaque 10s attach timeout. The attach budget now scales with the
  engine's target count, session→page probes run concurrently and cache, reconnects are gated on
  the endpoint's own target list, and a navigation that runs out of time reports as still in
  flight rather than as a failure that silently ate a single-use URL. `browser_create` rolls back
  a session whose page never appears and `browser_close` accounts for the tab; new `browser_health`
  (target count, attach cost, per-session responsiveness, `reconnect`) and `browser_cookies`;
  `browser_snapshot` takes `selector`/`maxDepth`; every lookup is scoped to this worktree's own
  sessions. Left open: per-worktree engines, and target→PID mapping (CDP exposes none).
- **Every sidebar row ends in two buttons, not one ⋯** — delete plus the verb its level owns:
  + on a workspace or worktree, ⋯ on a session leaf. Bigger hit targets, and delete still routes
  through the ⌘K confirm.
- **Synth 0.9.0 shipped (build 317)** — the two-button sidebar rows, the evenly-lit liveness
  sphere, and the browser MCP server's survival on a loaded engine reach installed copies. A minor
  bump, not a patch: the row-action pair and `browser_health` / `browser_cookies` grow the surface
  rather than only correcting it.
- **A bare modifier key no longer kills the app** — `flagsChanged` sent modifier presses down the
  real-keystroke path, which reads `charactersIgnoringModifiers`; AppKit raises on that for any
  non-key event, so resting a finger on ⌘ crashed the process.
- **Synth 0.9.1 shipped (build 320)** — a same-day patch carrying only that crash fix, since the
  keys chained shortcuts start from were the ones taking Synth down.
- **The light terminal moves to cool near-white** — `#f7f8fa` carrying `--ink` as its text, with the
  16 colours rebuilt to even ratios (hues 7:1, brights 9:1, dim 6.1:1). ANSI 7/15 stop being
  inverted, taking selected rows and inverse video from 1.04:1 to 7.4:1. Claude Code was never
  reading this palette — it runs its own dark theme by default, which is a `theme` Synth still has
  to set.
- **Claude Code's theme follows Synth's appearance** — `AgentTheme.sync` writes `theme` into
  `~/.claude.json` alongside the Ghostty re-theme, so a light Synth stops running Claude Code's
  dark theme (white body text at 1.03:1). Verified against 2.1.217 under a pty. Custom variants
  like `light-daltonized` are left alone, and open sessions keep the theme they launched with.

## [2026-07-23](docs/features/2026-07-23.md)

- **Settings: flat list, two tabs, scope set by the tree** — the sidebar scope list (read as
  navigation) is gone; Settings renders in the content pane over a live tree, with `Synth` and
  current-project tabs and a remembered project. Flat rows with the control on the right edge
  replace the accordion; inheritance is a per-row `Override` switch over a dimmed inherited field,
  retiring the three-way relation control and the `RESULT` preview. Notification sounds, MCP
  servers, analytics and About finally get a home.
- **Project settings layer on the shared default** — a project holds only its delta, shown on top
  of the shared base in run order: setup script after a collapsible shared strip, flags as an
  inline `$ claude <shared> <yours>` launch line, sessions added below the locked shared ones.
  Empty = pure inheritance; `Clear` strips the delta. Replaces the `Override`/replace switch, since
  a project's values concatenate with the default rather than swapping it.
- **Settings redesign ported to the native app** — the SwiftUI `SettingsPane` is the flat two-tab
  layered surface; the sidebar tree stays live under Settings (scope list gone, foot button lit);
  `agentFlags`/`sessionTemplate` compose shared+project instead of overriding. Driven-app verified.
- **Add project drops the branch picker and the typed path** — a new project comes in with just
  its default branch (the checkout already at the repo root), collapsed; other branches are added
  later, one at a time. Both entry points — the sidebar `+` and ⌘K "Add project" — now open the
  native folder picker, so a repository path is never typed. Removed the "Add worktrees"
  multi-select sheet and the ⌘K path-input frame entirely. HTML and SwiftUI both.
- **Experimental Tabs — two-deep sidebar + a tab strip per pane (off by default)** — an opt-in,
  presentation-only view mode (one global Settings toggle) over the same `branch → pane-tree →
  sessions` store, so it flips losslessly. Sessions leave the sidebar (branch becomes the deepest
  row, roll-up only) and render as tabs inside the ADR-0014 panes; a tab is a session's handle,
  nothing more (`CONTEXT.md` **Tab**). ADR-0014's "one session per pane" amends to "a strip of ≥1,
  one active"; splitting *moves* a tab (a live surface can't render twice), never duplicates.
  Nothing pinned — the agent is a peer tab; an agent-opened browser lands in its owner's strip with
  an unread dot, no focus-steal. Keyboard: panes keep `⌘1–9`/`⌘⌥arrows`; tabs add `⌘⇧[`/`⌘⇧]`
  switch, `⌘W` close, and `⌘⇧arrow` to send a tab into a neighbour pane or a new split.
- **Tabs revised — single strip, split as a bonded cluster (supersedes the per-pane strips)** — one
  tab strip per branch, not one per pane: a split reads as a bonded cluster of its member tabs within
  the single strip, mirroring how the sidebar draws a split (the horizontal twin of the echo band),
  never a second strip. Selecting a lone tab full-screens it (split stays bonded, stashed); selecting
  a member returns to the split. Drops the per-pane tab machinery — leaves stay single-session
  (ADR-0014 spine unchanged); the strip is pure presentation over the existing openSession/stash
  model. ADR-0014's amendment rewritten to match.

## [2026-07-24](docs/features/2026-07-24.md)

- **⌘K palette opens instantly again — the ~240ms key-view stall is gone** — hosting the palette in
  its own borderless `NSPanel` scopes the autofill key-view gather to the palette's tiny tree instead
  of the whole app window; `sample` shows the gather stack drop from ~250ms/open to zero, and the main
  window stays *main* (traffic lights lit) while the panel takes *key*. Native app only.
- **⌘K reliably focuses the palette input again** — focusing the palette's `TextField` via
  `@FocusState` in `.onAppear` was losing a race with AppKit's autofill heuristic + SwiftUI's
  whole-window key-view gather (~240ms/open, scaling with the tree), so on a loaded session the
  input silently never focused and keys fell through to the pane. Now bridged from AppKit
  (`PaletteQueryField`) and focused imperatively via `makeFirstResponder`.
- **Synth 0.10.0 shipped (build 331)** — minor bump rolling up the two-tab Settings redesign,
  the simplified Add-project flow, the cool near-white light terminal with Claude Code theme-follow,
  and the ⌘K palette focus fix.
- **Every native text field focuses instantly — password-autofill key-view walk killed app-wide** —
  no-op'd `-[NSAutoFillHeuristicController _showPasswordAutoFillIfNecessaryForView:…]` at launch
  (`AutoFillSuppression`), the same whole-window gather the palette escaped via `NSPanel`; `sample`
  on the 30-session tree: inline rename 412ms→3ms, feedback field 358ms→90ms. Native app only.
- **Scaling-perf pass: persistence, palette/drag scans, browser-open off the main-thread hot path** —
  state save encode+write moved to a serial background queue (reorder 28ms→6ms; sync flush on quit);
  ⌘K search + drag-pair dropped O(N²)→O(N) by threading known ws/br; browser engine bootstraps a
  runloop turn after the pane paints instead of freezing the open. Native app only.
- **Perf follow-ups: feedback submit resolves its branch name off-main (no more `git for-each-ref`
  freeze), and the ⌘K palette builds its item list once per render instead of three times.** Native app.
- **Synth 0.10.1 shipped (build 342)** — a patch rolling up the responsiveness pass since 0.10.0: the
  ⌘K palette in its own `NSPanel`, the app-wide password-autofill key-view walk killed so every text
  field focuses instantly, and persistence / palette-drag scans / browser-open / feedback branch-name
  moved off the main thread. No new surface — just keeping large sessions instant. Notarized, stapled,
  verified credential-less (spctl accepted / Notarized Developer ID on the quarantined dmg + zip,
  staple valid, appcast build 342 with an EdDSA signature on the full download and every delta).
- **Experimental Tabs — the native port lands (off by default)** — the single-strip Tabs view mode
  is now implemented in the native SwiftUI app (`AppStore.tabsMode`, `TabStrip.swift`), a faithful
  port of `working.html` gated behind the same off-by-default global preference so tabs-off stays
  byte-for-byte today's behaviour. Two-deep sidebar, one bonded-cluster strip per branch, relocated
  PR chip, hidden pane header, tab keyboard chords (`⌘⇧[`/`⌘⇧]`, `⌃⇥`, `⌘1–9`, `⌘W`), a Tabs group
  in the ⌘? sheet, and the full reorder/pair/split/unsplit drag reusing the sidebar's drop ops.
  Runtime-verified by driving the built app; tabs-off confirmed unchanged.
- **A worktree Delete can no longer fire from one stray keypress** — Command-menu confirm frames
  pre-selected their first row, and the native remove-worktree confirm had inverted the design's
  order to lead with "Delete worktree" (rm from disk), so a single Enter — or ⌘D on a branch — deleted
  a checkout (it did, to a real `holibob` worktree). Now no `.confirm` frame opens on a destructive
  row: selection starts on the first non-danger item (Cancel), and the native order is restored to
  match `working.html`. Native + both design files; the detach/sweep machinery is unchanged.
- **Synth 0.11.0 shipped (build 346)** — minor bump: the experimental Tabs view mode (off by default)
  plus the worktree-delete safety fix. Notarized, stapled, verified credential-less; 0.10.1 users take
  an ~880KB delta. First release run was killed pre-publish to fold in the safety fix (nothing shipped);
  its leftover stale `0.11.0/345` appcast item was pruned from the re-run's feed so 346 + 342 are the
  only items, every enclosure signed.
- **Destructive mouse actions go instant, undo pill as the net** — closing a session / removing a
  project no longer confirms: the row soft-deletes immediately and an undo pill (`softRemove`, 8s
  `UNDO_MS`, draining the notif countdown bar) parks it — bring it back by clicking the pill or ⌘↩,
  else it commits when the bar empties (no restore surface; the window is the whole net). Deleting a
  worktree stays the one confirm (its sidebar-vs-disk fork is irreversible), then both arms soft-delete
  with the same pill. Every delete gesture funnels through the one `requestDelete` choke point; landed
  in both designs (subset invariant holds); native app is a follow-up.
- **Instant destructive actions + undo pill land in the native app** — the SwiftUI port matches
  `working.html`: `AppStore.requestDelete` soft-deletes instantly (no ⌘K confirm) and `UndoPill.swift`
  parks an 8s pill draining the notif countdown bar (click or ⌘↩ to restore, else it commits). The soft
  mutators defer the irreversible tail — process teardown + `deleteWorktreeFolder` — to the pill's
  commit; the worktree keeps its fork; hard `closeSession`/`removeBranch` stay for non-gesture paths.
  Driven-app verified over the control socket; `working.html` untouched.
- **Undo folds into the notification deck (supersedes the bespoke pill)** — the undo is no longer a
  third toast primitive: it's a session-less `.undo` card in the existing notification deck (same
  corner, glass card, countdown bar, ⌘↩), in both the design and the native app. `.fb-toast--undo` and
  `UndoPill.swift` are deleted; native `InAppNotif` gained a per-instance `life` so the 8s undo drains
  right, and the card reuses the deck's drain so it now pauses on hover / while unfocused (your undo
  window waits for you, like any notification). Driven-app + browser verified.
- **Close-session moves from ⌘D to ⌘W (supersedes the ⌘D binding)** — the close-current-context verb
  (focused sidebar row, else open session) is now ⌘W, matching every tab/session app; behaviour is
  otherwise identical (instant soft-delete + undo deck, no confirm; worktree fork still the sole
  confirm). Both designs (subset invariant holds) and the native app: `closeContext()` returns `Bool`
  so ⌘W falls through to the stock window-close only when nothing's closeable, and the local key
  monitor owns ⌘W in all modes so a real close never leaks to macOS's ⌘W. Shortcuts sheet, palette
  hint, and comments track ⌘W; the bare sidebar `d` key is unchanged. Builds clean.
- **Synth 0.12.0 shipped (build 353)** — minor bump carrying the single ⌘D→⌘W close-session remap.
  Notarized + stapled (zip + dmg), verified credential-less on the quarantined downloads; 0.11.0 (346)
  users take a ~727KB delta. Appcast newest is `sparkle:version` 353, every enclosure EdDSA-signed.
  Clean run — no killed pre-publish, no feed residue. Landing links unchanged (stable `Synth.dmg`
  alias), so no site republish.
- **Terminal colours: dark rides ghostty's default, light cools to near-white** — dark mode drops
  Synth's bespoke near-black override entirely (Claude Code paints its own dark theme, so the
  override only fought the surface); `TerminalTheme.swift` now emits no bg/fg/cursor/selection/palette
  lines in dark and lets ghostty's default scheme stand. Light mode cools its warm cream surface to
  the design's `#f7f8fa` (`Theme.tuiBg`) and drops the dead `.term:focus` copper ring that the
  top-edge focus bar (004 §4) had already superseded. Light keeps its palette (it earns its keep
  against Claude Code's `#fff` light theme); native app + both designs (subset invariant held).
- **Synth 0.12.1 shipped (build 359)** — patch bump carrying the two terminal-colour fixes above.
  Notarized + stapled (zip + dmg), verified credential-less on the quarantined downloads; 0.12.0 (353)
  users take a small delta. Appcast newest is `sparkle:version` 359, all 18 enclosures EdDSA-signed.
  Clean run. Landing links unchanged (stable `Synth.dmg` alias), so no site republish.
- **Dark terminal keeps the background override (supersedes the 0.12.1 drop)** — 0.12.1 dropped the
  dark override entirely, but `window-padding-color = background` then leaked ghostty's lighter
  default into the padding band, so the surface read lighter than the near-black frame — a pale halo
  inside a darker border. The complaint was the palette recolouring, not the dark surface. Fix: dark
  mode emits a single `background = 121317` (matching `--tui-bg`) and lets fg/cursor/selection/palette
  ride on Claude Code's own theme. Surface flush with the frame, no colours fought; light unchanged.
- **Synth 0.12.2 shipped (build 360)** — patch bump carrying the dark-terminal background correction
  above. Notarized + stapled (zip + dmg), verified credential-less on the quarantined downloads;
  0.12.1 users take a small delta. Landing links unchanged (stable `Synth.dmg` alias), no site republish.
- **In-app notifications stack, nothing replaces (supersedes "one pill at a time")** — a new
  notification joins the deck rather than evicting an unseen one, and each fades on its own timer. Two
  roots fixed in both designs (subset invariant held): `.fb-toast` confirmation toasts moved from a
  wipe-all + single shared timer into a bottom-centre `column-reverse` `.fb-toasts` stack where each
  toast owns its own dismissal; and the delete/close undo went from a single `pendingUndoKey`
  (committed by the next delete) to a `pendingUndos` Set, so several undo cards coexist, each
  committing/undoing its own key and ⌘↩ targeting the newest. Native app landed in the same change:
  its toasts already stacked in the shared deck, so only the undo needed fixing — `softDelete` drops
  its `commitPendingUndo()`, and undo resolution goes per-id (`performUndo(_ id:)`) over the deck's
  already-per-id drain, ⌘↩ targeting the front-most undo. Builds clean.
- **Tabs: double-click to rename, right-click for the ⌘K menu** — two tabs-mode gestures, each the
  horizontal twin of a sidebar-row one: double-clicking a tab renames it inline (whole name
  preselected, ↵ commit / Esc revert / blur commit, reusing the row's `renamingRowID` machinery), and
  right-clicking opens the command palette pinned to that session (the same `openRowActions` the row's
  ⋯ kebab opens — Rename / Close + the search groups). Design (`working.html` + big-picture, subset
  invariant held) and native app (`RenameField` reused; a `DoubleClickCatcher` overlay claims only the
  second click of a plain double-click so single-click open, tab drag, and close pass through). Both
  cover lone tabs and split-member cluster chips. Builds clean.
- **Tabs mode: the keyboard cursor is branches-only, stated outright** — in Tabs mode the sidebar is
  2-deep (sessions are tabs, not tree rows), so `J`/`K`/arrows must walk repos + branches only. The
  native app leaked the cursor into the hidden session rows because keyboard-nav membership was
  inferred from CSS visibility (`offsetParent`), which Tabs mode only *happened* to satisfy. `treeRows()`
  now drops `[data-session]` rows outright when `tabsMode` is on — the rule is explicit, not a side
  effect of `display:none`. Both design files (subset invariant held); native port is the follow-up.
- **Tabs mode: the rest of the sidebar shortcuts stop toggling a branch's invisible disclosure** — a
  branch is the deepest sidebar row in Tabs mode (chevron hidden), but `→`/`←`/`Tab`/`Enter`/click
  still treated it as an expandable group and silently flipped its now-hidden session accordion. One
  shared `canDisclose(row)` predicate (a `[data-toggle]` row that isn't a branch while `tabsMode` is
  on) now gates every disclosure path, so on a branch those keys just navigate; activating a branch
  runs `openBranch` — brings its tabs on screen + focuses content — instead of nothing. Repo heads
  still disclose; Tabs off is unchanged. Both design files (subset invariant held).
- **The native app lands the tabs-mode sidebar-keyboard fix** — port of the two entries above into
  SwiftUI (`Navigation.swift`/`Sidebar.swift`). The view was already tabs-aware but the keyboard model
  wasn't: `visibleRows` (native `treeRows`) now drops `.session` rows when `tabsMode`; `isToggle`
  becomes `canDisclose` (returns `!tabsMode` for a branch, workspaces still disclose) gating `→`/`←`/
  `Tab`/`↵`; and a shared `openBranch(_:)` (factored from the click handler) opens a branch's tabs on
  `↵`/click. `swift build` clean; driven headless + screenshot — Tabs on, `↓`/`↑` walk workspaces +
  branches only and `↵` opens a branch's tabs; Tabs off still walks into sessions. `working.html`
  untouched.
- **Clicking a sidebar row hands the keyboard to the sidebar** — a click now makes the tree
  keyboard-active (blurs content, selects the row) instead of `focusContent()`, so `r`/`d`/`a`/`j`/`k`
  act on the clicked branch/worktree/session immediately; the session still opens in the pane, ↵ or ⌘1
  dives in to type. `handToSidebar()` mirrors ⌘0. Both designs + native (`openFromSidebar` +
  a one-shot `suppressShellFocusOnOpen` so the terminal's mount-focus doesn't re-steal the keyboard).

- **Synth 0.13.0 shipped (build 376)** — minor bump: clicking a sidebar row now hands the keyboard to
  the sidebar (row shortcuts act at once, ↵/⌘1 dives in), plus the experimental-Tabs rename/right-click
  gestures and tabs-mode keyboard-nav fix, and two fixes riding along — in-app notifications stack
  instead of replacing, and the terminal re-scales across mixed-DPI displays. Notarized + stapled
  (zip + dmg), verified credential-less on the quarantined downloads; appcast newest `sparkle:version`
  376 / `0.13.0`, all 18 enclosures EdDSA-signed, deltas against 342/346/353/359/361. Clean run.
  Landing links unchanged (stable `Synth.dmg` alias), no site republish.

- **Archive replaces Delete worktree, with a background clean-up behind it.** A branch row archives
  (instant, undo card, folder untouched, restorable from ⌘K → `Archived`); the two-armed remove/delete
  confirm fork is replaced by `Delete worktree now` one level down. Archive confirms nowhere and Delete
  confirms everywhere — the dialog follows irreversibility, not the entry surface. A background pass
  reclaims a folder only once the work is provably recoverable from a remote, and its terminal act is a
  rename with a 14-day hold, never an `rm`. Both of the originally proposed conditions were unsafe as
  stated: a tracked-only cleanliness check is blind to untracked source (`browser-phase-01` holds
  seven untracked source paths in a 2.6 GB tree), and
  "PR closed is fine" is backwards while `pr == nil` was indistinguishable from being offline.
  Supersedes ADR-0007's "UI-only, labelled Remove never Delete" and this day's earlier no-archive-surface
  entry. Also untracks `.mcp.json`, which an agent committed in `da7f902` against the 2026-07-05 entry.

- **Toasts get three tiers, real buttons, and a dismiss that isn't the action.** All seventeen
  transient messages audited onto one chassis: attention (sticky), reversible (8s undo), ambient
  (6s result). Every card gains a real action button with ⌘↩ printed inside it and a hover ×, so
  leaving stops being the same click as acting. A card with no identity drops its who-line (the
  archive cards were floating a dot over an empty title); errors carry their evidence (exit code,
  git's reason — not git's first line, which is progress chatter); saturated state colour becomes
  a session's alone, with a new `.neutral` for the app's own housekeeping. The countdown stops
  terminating in mid-air: it fades out at its origin end and is clipped by the card's own corner
  at the far one. The deck re-anchors peeks by top edge, since card heights now vary. Deletes the
  mock's second toast surface (`.fb-toast`). Standalone exploration in `toast-audit.html`.
  Also makes the focus brake drivable, so the notification gate stops depending on which window
  happened to be frontmost.

- **Worktree creation works in repos with no `origin` again.** `GitService.originHead` checked
  git's output for emptiness but not its exit status, so in a remote-less repo it returned
  `fatal: ref refs/remotes/origin/HEAD is not a symbolic ref` *as the ref name* — every new
  worktree tried to fork off that sentence, and the main/master fallbacks below were unreachable.
  Pre-existing on `main`; found because the redesigned error card puts git's own reason on screen.

- **The agent gate reads the instance file the driven build actually writes.** `AppSupport` puts
  the dev build's registry under `Synth Dev`, but the harness hardcoded `Synth` — so `t4a`, `t4b`
  and `t5` failed on an absent CDP port and empty worktree list while the browser engine was
  demonstrably fine. Pre-existing since the channel split.

## [2026-07-27](docs/features/2026-07-27.md)

- **The light-mode terminal answers for colours it did not choose** — measured with a capture
  harness that speaks OSC 10/11 and DEC 2031 plus real-build screenshots, not by reading tokens.
  First finding was a harness artefact worth recording: with no 2031 answer Claude Code falls back
  to its dark theme and renders code at **1.00:1**, but ghostty *does* answer, so both agents
  already switch themselves — the `--settings {"theme":…}` injection that looked necessary would
  only have overridden a user's own choice. One real fix: **faint (SGR 2) sat at 3.2:1 where dark
  gets 5.3** from the identical halfway blend, since that mid grey is nearer white than black —
  light now keeps 0.65 of the ink (`faint-opacity`), measuring **5.1:1**. Two general fixes were
  tried and reverted: `minimum-contrast` (ghostty implements it by replacing the foreground with
  black or white, so at 4.5 every colour on screen went black) and **mirroring the 256-colour
  greyscale ramp** — which fixed foreground use (`38;5;250` 1.8:1 → 10.7:1) but made tmux's stock
  powerline status bar unreadable, since a `bg=colour236` band under pinned white ink inverts.
  The line that settles it: slots **0–15 are what a theme is for**, **16–255 are a fixed standard**
  a tool addresses by absolute value. So `38;5;250` as body text stays 1.8:1 and fzf's selected row
  stays a dark slab — a tool's own dark preset, answerable where the tool is configured. New
  `t13_termcontrast` gates it in pixels (light 4.5:1, dark pinned at 4.2 because ghostty's default
  red ships at 4.31), decoding PNGs with `zlib` so the gate stays dependency-free. Left standing as
  a design call: the light terminal card barely reads as a surface (ΔL\* ≈ 1.0 from the pane,
  against dark's 3.6).

- **An MCP server now knows which channel installed it** — `shared.mjs` hardcoded
  `Application Support/Synth/instances`, so a dev build's agents discovered *no* Synth (empty
  `browser_list`, nothing to drive) or — with a stable Synth also running — discovered **that** one
  and drove its browser, the exact cross-channel control the `AppSupport` split exists to prevent.
  `MCPInstaller` now injects `SYNTH_SUPPORT_DIR` (= `AppSupport.root.path`) into both config
  writers — `opencode.json`'s `environment` and `.mcp.json`'s `env`, which carried no environment
  at all — and `shared.mjs` roots instance discovery there. Covers both bundled servers, which
  share discovery. `t4a` asserts the variable in both files.
- **The harness follows the bundle it drives, everywhere it looks** — the remaining four hardcoded
  sandbox paths now go through `lib.support_dir()`: `t5`'s comment screenshots (looked under
  `Synth/comments`, written to `Synth Dev/comments` — check 10's `0 new png`), `lib.WT_ROOT` (had
  been sweeping the wrong sandbox silently since the split), and `t9`/`t10`, which hardcoded
  `Synth Dev` and so passed for a reason that isn't true. `run.sh`'s CEF precheck honours
  `SYNTH_APP` like the suites do.
- **A browser that opens straight onto a page could show `about:blank` forever** — the
  `addressDidChange` guard suppressed CEF's creation-time idle URL only `if address == nil`, but a
  restored / popup-born / agent-created session navigates inside `init`, on the same turn the engine
  is built — so the late callback overwrote the real URL with plumbing, `isHome` went false so home
  wouldn't cover it, and nothing re-fired until the next navigation. `about:blank` is never a
  destination; the guard is now unconditional. Caught by `t4b` check 4, where `browser.list` (session
  model) and `automation.state` (live controller address) disagreed in the same run.
- **Synth 0.14.0 shipped (build 380)** — minor bump headlined by the archive-not-delete worktree
  redesign (instant, undoable, background reclaim only once the work is safely on a remote), plus the
  three-tier toast redesign, the no-`origin` worktree-creation fix, and the `about:blank`-forever
  browser fix; the cross-channel MCP-sandbox / harness-path fixes stayed out of the user changelog.
  Notarized + stapled (zip + dmg), verified credential-less on the quarantined downloads (both
  Notarized Developer ID, app inside the dmg staples on its own); appcast newest `sparkle:version`
  380 / `0.14.0`, all 18 enclosures EdDSA-signed, deltas against 346/353/359/361/376. Clean run.
  Landing links unchanged (stable `Synth.dmg` alias), no site republish.

- **An available update announces itself.** A new build used to live only behind `Check for
  Updates…` and the Settings → About row — places you go once you already suspect there is one.
  It now raises a deck card when the download lands, and again once a day while it sits unapplied:
  attention tier (sticky, no countdown) but neutral-inked, no who-line, and the one attention card
  that never posts Notification Center when Synth is unfocused. The copy says the build installs
  itself the next time you quit, which makes `Restart` a shortcut rather than a price and the ×
  ("not now") a complete answer; the daily reminder swaps its sub-line for the age (`Downloaded
  3 days ago`), the only fact that changed. `Restart` with sessions busy goes through the ⌘K
  confirm frame. Settings → About states the same fact and offers the same `Restart`.

- **The deck's ⌘↩ stops the chord it has claimed.** The palette's `Enter` handler runs later in the
  same dispatch, so ⌘↩ on a card whose action opens a confirm raised the dialog and then activated
  its preselected Cancel — one keystroke asking and answering. Found building the update card.

- **Native: the update card.** The above, in the app. `UpdateBridge` takes Sparkle's
  `willInstallUpdateOnQuit` and hands the staged version plus its relaunch closure to the store,
  with Sparkle's own window suppressed for scheduled finds; the updater now starts at launch
  instead of waiting for someone to open the app menu. The arrival date and last-spoken date live
  in UserDefaults so the reminder ages and does not repeat every launch, while `stagedUpdate` is
  never restored without a working installer — a Restart that cannot restart is worse than no card.
  Gated by `t11_update.py` (22 checks).

- **The deck stopped eating its own words.** Two pre-existing fidelity bugs, found because the
  update card's copy was long enough to expose them: a `Spacer` between the text and the button
  made the card pay its 11pt gap twice, and the button's ⌘↩ caps were the palette's larger
  `.cmdk__key` rather than the card's own `.notif__act kbd`. Together they cost 30pt of a 320pt
  card, and `Synth 0.13.1 is ready` rendered as `Synth 0.13.1 is r…`.

- **Glossary: Update and Restart.** One noun for the newer build, one verb for what it costs you.
  Both surfaces say `is ready` / `installs when you quit` because the build is already downloaded,
  and nothing may frame `Restart` as the way to get it — it only accelerates an install that
  happens on the next quit anyway.

- **The audit of the port, and what it caught.** `applyUpdate` armed `AppTermination.forceQuit`
  before an installer that, on the demo and harness paths, returns instead of quitting — leaving
  the flag set and the next real ⌘Q free to kill busy sessions with no confirm. Also: the ageing
  sub-line divided by a hardcoded day while the reminder used an overridable one (so the gate could
  not watch a reminder age), Restart-from-Settings raised a card as a side effect of repairing one
  it never spent, and a stale record could announce the version you are already running.
- **Synth 0.15.0 shipped (build 386)** — minor bump headlined by an available update announcing
  itself (deck card on download + a once-a-day reminder, installs on next quit, mirrored in Settings
  → About), plus the two deck fixes its longer copy exposed (⌘↩ no longer asks-and-answers in one
  keystroke; long notifications no longer truncate); the native-port / audit / glossary work behind
  it stayed internal. Notarized + stapled (zip + dmg), verified credential-less on the quarantined
  downloads (both Notarized Developer ID, app inside the dmg staples on its own); appcast newest
  `sparkle:version` 386 / `0.15.0`, all 18 enclosures EdDSA-signed, deltas against 353/359/361/376/380.
  Clean run. Landing links unchanged (stable `Synth.dmg` alias), no site republish.

- **An archived row stopped walking back into the sidebar.** Archiving detaches the row at the
  gesture and stamps `archivedAt` only when the undo window commits — so the disappearance was the
  detach, and the commit's re-insert into `ws.branches` (what the Archived list reads and what
  persists) put the row back on screen, because the SwiftUI sidebar rendered `branches` while
  `visibleRows`, ⌘K and the config writer each open-coded the archive filter. One
  `Workspace.liveBranches` now serves the tree, its empty hint, both counts, and the
  which-branch-is-this-action-for fallbacks; reordering counts in drawn rows, not raw indices. New
  `automation.tree` verb, and `t9_archive` asserts the row leaves the tree — it only ever asserted
  it reached the Archived list.

- **What a fresh install starts with.** Four defaults flipped toward "what you'd have turned on
  anyway, and nothing you'd have to undo": the Synth-app MCP server is on (its one mutating verb was
  already approval-gated, so opt-in bought a confirmation that already existed), archived-worktree
  cleanup is on (held off one release by design; the refusals are asserted worktree by worktree and
  the conditions are conservative on their own), and both the shared setup script and every agent's
  default flags ship empty — a default script guesses about someone else's repo, and
  `--dangerously-skip-permissions` should be a flag the user typed. Unchanged: system theme,
  needs-input + command-failed sounds, browser MCP on, no template sessions, seven-day archive
  grace, analytics on and opt-out, Tabs off. Stored values win, so only a user who never touched the
  two toggles sees them switch on.

- **Synth 0.15.1 shipped (build 390)** — patch carrying one user-facing fix: an archived worktree row
  no longer walks back into the sidebar once its undo window commits (the tree now reads one
  `Workspace.liveBranches` instead of raw `branches`). Notarized + stapled (zip + dmg), verified
  credential-less on the quarantined downloads (both Notarized Developer ID, app inside the dmg
  staples on its own); appcast newest `sparkle:version` 390 / `0.15.1`, every enclosure EdDSA-signed,
  deltas against 359/361/376/380/386. Clean run; landing links unchanged (stable `Synth.dmg` alias),
  no site republish.

- **Synth 0.16.0 shipped (build 392).** The defaults change above, and nothing else. Changelog names
  the seam it creates: the two `UserDefaults`-backed toggles (Synth-app MCP, archive sweep) switch
  themselves on for anyone who never touched them, while the snapshot-backed setup script and agent
  flags only change for fresh installs. Notarized + stapled (zip + dmg), verified credential-less on
  the quarantined downloads (both Notarized Developer ID, app inside the dmg staples on its own);
  appcast newest `sparkle:version` 392 / `0.16.0`, all 18 enclosures EdDSA-signed, deltas against
  361/376/380/386/390. Landing links unchanged, no site republish. Took two attempts — a mid-upload
  session teardown (nothing published; stable `Synth.dmg` never at risk) and a `nohup setsid` that
  did nothing because `setsid` isn't a macOS command. Launch long releases via python3 `os.setsid()`,
  and make the watcher emit on process-gone, not just on success.
- **The scratch terminal (⌘⇧T) — a shell for the errand, not for the tree (both designs)** — a
  throwaway full terminal in the context branch (`contextBranch()`, like ⌘T/⌘N; lazily creates a
  dormant branch's worktree per ADR-0004), summoned and dismissed on the same chord. Deliberately
  **not a Session**: no row, no status, no roll-up — its own glossary term, because "a session
  that isn't in the sidebar" would split the central noun. **Dismissing kills it** (fresh shell
  every summon) to hold the rule that nothing runs that the sidebar doesn't show, which is why
  closing it while busy confirms and names what it ends (ADR-0013). **Esc closes only at an idle,
  empty prompt** — otherwise it reaches the shell, so vim/TUIs work; ⌃C and ⌃D are never
  intercepted; ⌘W closes too. A centred card over a 0.5 dim (deeper than a dialog's — a detour out
  of the app, not a step within it), no chrome but the branch name bottom-left. Listed in ⌘? and
  ⌘K. Overlay won over a curtain and a pane-inline panel, both built and driven first.
- **⌘? had been dead in both design files** — `scIcon` asked for `ICON_GLOBE`, declared nowhere
  (its own comment claimed it was "declared further down"), so `openShortcuts()` threw and the
  shortcuts sheet never opened. Now `ICON_BROWSER`; every category renders.
- **Native: the scratch terminal (⌘⇧T)** — the design above, running on a real PTY in the branch's
  worktree. `ScratchTerminal` holds a real `Session` (the terminal stack is keyed by one) but never
  appends it to `ws.branches` — that omission alone is what keeps it out of the sidebar, roll-up,
  ⌘K and `state.json`. Consequence: `apply` resolves bus events via `session(id)`, so the scratch's
  own events (including the `.exited` that fires on `exit`) would have been dropped — `applyScratch`
  takes first refusal, driving the busy dot and closing the overlay. ⌘N's context ladder extracted
  to one `contextBranchForNewSession()` so the two can't drift. Two forced divergences: Esc's
  "idle *and empty* prompt" becomes just "no foreground job" (a PTY's line buffer isn't ours to
  read), and the amber dot carries the whole busy signal since the foot hint was cut. New gate
  `t12_scratch.py` (26 checks) runs a real `sleep 30` through the real zsh reporter and asserts the
  absences *while it runs*; new `automation.shortcuts` verb makes the ⌘? sheet assertable — the
  thing whose absence let the HTML sheet stay broken. 13/13 suites, 201 checks.
- **Release-readiness pass on the scratch terminal — four real findings** — the 0.5 scrim had been
  tuned in dark only and crushed a light app to flat grey, so it becomes `Theme.shade(0.34, 0.5)`
  (a new helper, because `mono` inverts to white in dark and would lighten a scrim); **quit** could
  end a running scratch command while reporting only "This closes every session" (`busySessions`
  walks the tree, which a scratch terminal is deliberately not in) and now names it, with the copy
  moved to `quitInformativeText` so a harness can read it without answering a modal; **Restart** was
  worse — gating on `busySessions.count > 0`, it skipped its confirm entirely and installed over a
  running scratch job; and Reduce Motion was honoured in the CSS but not the app. ⌘⇧T staying
  ungated in Settings is confirmed as the rule (Settings gates tree actions; ⌘⇧T adds no row, like
  ⌘K/⌘?/⌘⇧F) and pinned by a check. Both design files carry the theme-split scrim.
- **Two suites had been asserting a default that shipped changed** — `t7`/`t8` failed on main and
  identically on pre-merge main, both tracing to 0.15.1 flipping `mcpAppEnabled` to `true`. `t8`
  asserted synth-app *absent* by default; it now forces the toggle explicitly in both directions
  with a new first phase pinning the shipped default (phase C had the same latent bug). `t7`
  answers Claude's startup gates until the hook lands instead of assuming one Return — because two
  servers in `.mcp.json` means Claude asks to approve them *as well as* trusting the folder, so a
  fresh worktree's first Claude now meets two prompts. That last part fell out of the default flip
  rather than being decided; the gate now matches reality, the product question is still open.
  13/13 suites, 205 checks.
- **The notification deck orders by what it costs to miss a card, not by severity** — `kind` ranking
  put a five-minute-old error ahead of a ten-second-old needs-input, so the toast you were just
  nudged about landed behind one you'd already dismissed in your head, ⌘↩ included. The sort key is
  now what missing the card costs: fused (an undo, actionable *and* expiring) → standing (sticky and
  asking, and carried by the sidebar anyway) → receipt (self-dismissing, asking nothing), newest
  first inside each. Error and needs-input are one band; recency decides.
- **A countdown you cannot see no longer runs** — a draining card folded under "+N" still drained,
  so a receipt with no other surface (sweep digest, "Handed to Mail") could expire having never been
  on screen. Burial joins deck-hover and app-unfocused as a drain brake; the app reconciles in one
  place (`settleDrains()` off `notifs.didSet`), working.html in one selector.
- **Synth 0.17.0 shipped (build 398).** The scratch terminal (⌘⇧T) reaches people, with the two
  release-readiness fixes as their own changelog lines (quit/Restart name a running scratch job;
  scrim tuned per theme). The ⌘? repair stayed out — design-file only, never shipped. Notarized +
  stapled (zip + dmg), verified credential-less on the quarantined downloads, app inside the dmg
  staples on its own; appcast newest `sparkle:version` 398 / `0.17.0`, all 18 enclosures
  EdDSA-signed, 5 deltas against 376/380/386/390/392 (28M). Landing links unchanged, no site
  republish. `generate_appcast` logged a "File exists" per archive failing to move into
  `old_updates/` — non-fatal, and it leaves the previous zips where the next release's deltas need
  them. Detached launch via python3 `os.setsid()` plus a watcher that exits on process-gone held up.

- **Branch names leave the monospace** — the sidebar's branch row goes to the UI sans, tracking to
  0 (mono's fixed advance was what the `-0.01em` compensated) and ink up to `--ink-2` (`--ink-3`
  was calibrated against mono's heavier stems). Mono elsewhere is untouched: it still means "the
  machine owns this string" for crumbs, PR chips, URLs, keys and terminals. Two knock-ons, both
  because mono had been load-bearing: the two rules that de-emphasised `.branch--active` are gone,
  so the branch you're checked out on no longer renders identical to the ones you aren't (the
  white pill still drops — a fill behind a fill double-encodes, a name at another level doesn't);
  and top-level projects separate by a 10px margin rather than indent, since the chip already eats
  the repo row's indent budget and sessions can't afford to move right. A leading branch glyph was
  considered and rejected — it would sit in the session-icon column.

- **Synth 0.17.1 shipped (build 407).** A patch: the notification deck's cost-to-miss ordering and
  the burial drain-brake, branch names out of the monospace with the checked-out branch visible
  again, sidebar rows pinned to a height that stops shifting under a click, and Light's faint
  terminal text back to 5.1:1. Notarized + stapled (zip + dmg), verified credential-less on the
  quarantined downloads (both Notarized Developer ID, app inside the dmg staples on its own, bundle
  reads 0.17.1 / 407); appcast newest `sparkle:version` 407 / `0.17.1`, all 18 enclosures
  EdDSA-signed, 5 deltas against 380/386/390/392/398 (4.2M against a 137M download). The 0.17.0
  `generate_appcast` "File exists" noise is now understood — 16 archives moved cleanly, and it fails
  only on the ones duplicated in `old_updates/` by an earlier bucket recovery. Landing links
  unchanged, no site republish. Clean single-attempt run on the detached `os.setsid()` launch.

## [2026-07-28](docs/features/2026-07-28.md)

- **The first tab's fill runs under the sidebar, not up against it** — in tabs mode the first tab's
  fill stopped square at the sidebar's rounded edge, leaving a wedge of panel colour against the
  curve so the tab read as clipped. Rounding the strip's own top-left was tried and rejected: two
  curves with a gap between them still show where the fill ends. It shouldn't end — it continues
  past the seam and the sidebar's corner occludes it, which is what the z-order already says. The
  mock needs a separate `.tab-bleed` block for that (`.content` and `.tabstrip__tabs` both clip
  their overflow, so the tab can't cross the seam itself), with `.sidebar` stacked over it; native
  has no such clip, so the run-on hangs off the tab as a leading background and `TabChip` routes
  active, hover and run-on through one `fill` property so they can't drift. Knock-on: `.tab:hover`
  out-specified `.tab--active` in the mock, washing the open tab's fill down under the pointer where
  Swift never did — settled in Swift's favour, since the wash means "you could open this" and
  there's nothing to open. Native hover is structurally guaranteed rather than screenshotted: a
  synthetic `mouseMoved` posted to the pid doesn't reach an inactive window's `NSTrackingArea`.

- **Device previews are drawn from real hardware, and show the page as the phone's browser would** —
  the simulator pane and the browser's device mode both drew a generic black rectangle: a fixed
  232×476 box with no cutout and the device's name where iOS puts the battery, and a frame whose
  island was decoration the page ran straight under. Both now render from one device model whose
  numbers are the hardware's own — bezel per edge, body and screen radii, status-bar and safe-area
  insets, side buttons on the rail — laid out at true viewport size and scaled to the pane, so the
  proportions hold at any width and rotating walks every edge one place round. The screen draws what
  the device draws: Safari's tab bar at the bottom in portrait and one top bar in landscape with the
  status bar dropped, iPad Safari on top with its tab strip, Chrome and a gesture pill on Android, a
  home button on the SE, and a real status-bar trio parting around the island. The simulator runs an
  app, so it gets an app's chrome and takes its device from the session's name. Device screens stay
  light in both themes — a separate machine showing a light page.

- **Synth 0.18.0 shipped (build 413).** A minor: device previews drawn from real hardware in both
  the simulator pane and the browser's device mode, each showing the page inside the browser chrome
  that device actually gives it — so the page gets the viewport a phone gets, not the whole screen —
  plus the first tab's fill running under the sidebar. Notarized + stapled (zip + dmg), verified
  credential-less on the quarantined downloads (both Notarized Developer ID, app inside the dmg
  staples on its own, bundle reads 0.18.0 / 413); appcast newest `sparkle:version` 413 / `0.18.0`,
  all 18 enclosures EdDSA-signed, 5 deltas against 386/390/392/398/407 (4.8M against a 137M
  download). The `generate_appcast` "File exists" noise recurred as understood at 0.17.1 and is
  harmless. Landing links unchanged, no site republish.

- **⌘K search ranks flat — the best match is the top row** — typing used to bucket results into
  Actions / Sessions / Branches / Projects, rank the buckets, then list the winning bucket whole, so
  the best match in the palette could sit six rows down under weaker siblings that shared its
  heading. A query now drops grouping entirely: one list, every candidate scored against the same
  query, best first, ties falling back to most-local build order. The scoring is unchanged, just no
  longer partitioned before it's applied. The icon and ctx path already say what each row is and
  where it lives, so the headings were spending a row to repeat the row. Cold ⌘K — Recent plus the
  context actions labelled by scope — keeps its groups.

- **Native port: ⌘K search ranks flat, and scoring reaches label-boost parity** — the flat ranking
  in the app: one scored list, `(score, build order)` sort key, `group`/`sec` stripped under a
  query; porting it surfaced that the native matcher lacked the exact/prefix label boosts the mock
  ranks by, so `itemScore` is ported exactly. `automation.screenshot` now prefers the ⌘K panel —
  it had been screenshotting the window under it. Verified over the control socket + screenshots.

- **Synth 0.19.0 shipped (build 418).** A minor: ⌘K search ranks flat, so the best match is the top
  row, with the native matcher's label boosts brought to parity so it ranks the same way. Notarized +
  stapled (zip + dmg), verified credential-less on the quarantined downloads (both Notarized
  Developer ID, the app inside the dmg staples on its own, bundle reads 0.19.0 / 418); appcast newest
  `sparkle:version` 418 / `0.19.0`, all 18 enclosures EdDSA-signed, 5 deltas against
  413/407/398/392/390 (666K from the previous build against a 137M download). Landing links
  unchanged, no site republish.

- **A split's tabs are tabs again, marked by an 8px map of the split** — split members had rendered
  as 22px chips borrowed from the sidebar's split band, which cost them the indicator slot (a member
  needing input showed nothing), the active bar, the hover wash and shrink-to-fit. A member is now a
  full tab, divided from its siblings by an inset hairline instead of a full seam, and grouping rides
  on one mark: an 8px map of the split in each member's icon corner with that tab's own pane filled,
  computed from the real pane tree, so it says which pane as well as grouped.

- **Native port: a split's tabs are tabs again, marked by the pane map** — `TabCluster`/`ClusterChip`
  deleted; a member is an ordinary `TabChip` carrying `groupPosition` (seams) and `paneMap` (the
  mark), fed by `AppStore.paneRects(for:)` walking the same tree `echoMemberIDs` flattens. The
  sidebar bleed now passes down to a group's first member, which is full-bleed like any tab.
  `automation.screenshot` gained `"window":"main"`, because a tooltip NSPanel had been hijacking
  every capture.
- **Antigravity CLI (`agy`) is Synth's third hosted agent — ADR-0012's promise, cashed** — a session
  can run **Antigravity** beside Claude Code and OpenCode, added as one `AgentDescriptor` plus one
  `AgentSupervisor` and nothing else (persisted `AgentID` `antigravity`, binary `agy`). Google's I/O
  2026 split matters here: the agent is the new Go TUI (v1.1.x, Claude Code's shape) replacing Gemini
  CLI, *not* the Nov-2025 Antigravity IDE, which ships a same-named shell launcher into
  `/Applications/Antigravity.app` that sits ahead of Homebrew on the login PATH — so detection
  resolves symlinks and rejects any candidate inside an `.app` bundle. No event bus, so transport is
  hook-driven like Claude's, but nothing of the user's is written: verified empirically that `agy`
  loads `.agents/hooks.json` from `--add-dir` dirs too, so the shim writes hooks into a Synth-owned
  per-session dir and appends `--add-dir`; `PreInvocation`/`PostToolUse` → working, `Stop` → idle +
  unread. Readiness can't be Claude's "first hook" rule — agy's first hook is a *turn* start, so a
  row would be undeliverable until someone typed — and it can't be a boot marker either: `agy`
  announces "CLI mode" in milliseconds but shows a sign-in spinner for ~1.5s and keeps redrawing
  for ~3s after, and a paste landing in any of that is lost silently. Readiness is therefore the
  model resolving *and* the log going quiet, and — on a path agy has never seen, i.e. every fresh
  worktree — the workspace trust prompt being answered: until it is, the row is needs-input and
  never live, because a comment delivered there is swallowed and its Enter answers the *prompt*.
  Synth reads that trust record and never writes it. needs-input has no hook either, so the shim
  appends `--log-file` and the supervisor tails it for "Surfacing tool confirmation", cleared by
  the next hook. `conversationId` from the hook payload gives true
  resume (`agy --conversation <id>`) and `transcriptPath` the row's name; text is
  a TUI paste; browser MCP lands in per-worktree `.agents/mcp_config.json`, never the global one.
  `AGY_CLI_DISABLE_AUTO_UPDATE=1` (an embedded agent must not swap its binary mid-session) and
  inherited `ANTIGRAVITY_CONVERSATION_ID`/`ANTIGRAVITY_PROJECT_ID` scrubbed so a nested agent isn't
  mistaken for the row's. Auth is Google sign-in, free tier sufficient, quota shared across the
  Antigravity surfaces; live harness gates skip until the machine is signed in.
- **Synth 0.20.0 shipped (build 425).** A minor: Antigravity (`agy`) as a third hosted agent, and a
  split's tabs restored to full tabs with the 8px pane map. Notarized + stapled (zip + dmg), verified
  credential-less on the quarantined downloads (both Notarized Developer ID, the app inside the dmg
  staples on its own, bundle reads 0.20.0 / 425, bundled changelog leads with 0.20.0); appcast newest
  `sparkle:version` 425 / `0.20.0`, every enclosure EdDSA-signed, 5 deltas against 418/413/407/398/392
  (850K from the previous build against a 137M download). `generate_appcast` swept 16 archives past
  its retained window into `releases/old_updates/`, so the feed lists three items. Landing links
  unchanged, no site republish.

- **Ctrl-C interrupts an opencode row, it doesn't quit it** — an opencode conversation 69 messages
  deep disappeared mid-turn, twice in one afternoon. opencode binds `app_exit` to
  `ctrl+c,ctrl+d,<leader>q` and `session_interrupt` to `escape` alone, so the universal *stop*
  gesture quits the app, measured exit code **0** — the clean exit on which Synth ends a row
  (features 2026-07-06), taking the captured `ses_…` id with it, and raising no toast at all because
  the closing card is only for rows you aren't looking at. Claude Code interrupts on the same key,
  so opencode is rebound inside Synth: `session_interrupt` gains `ctrl+c`, `app_exit` keeps `ctrl+d`
  and `<leader>q`. The seam is `OPENCODE_TUI_CONFIG`, an extra TUI config file merged after the
  user's own and before any project one, written to `<Application Support>/opencode-tui.json` and
  named from `decorate` — no file of the user's is touched, and a project `.opencode/tui.json` still
  overrides it. Keybinds are a TUI concern: `OPENCODE_CONFIG_CONTENT` has no `keybinds` key.
- **An agent that quits parks its conversation on a Reopen card** — a clean exit no longer closes
  an agent row that holds a conversation. The row still leaves the tree, but it lands on an undo
  card — the agent's mark, "OpenCode quit", the conversation's name, **Reopen** — and Reopen slots
  it back where it stood, the pane rebuilding its terminal with `--resume`. Unlike every other undo
  the card **never drains**: a fuse is right for undoing your own gesture, wrong for something you
  didn't do that can land while you're away, so `band` now asks whether an undo actually drains
  rather than assuming it does. Nothing parks when there is nothing to resume (a shell's `exit`, an
  agent quit before its first prompt) — the rule is never destroy a conversation Synth can restore,
  not never close a row. And it is raised whatever is on screen: `routeTransition` escalated only
  rows you weren't looking at, which is why the foreground case — the one that actually happened —
  was silent. Gate: `t17_agent_quit`.
- **Antigravity reports the states it stops in: a question, an interrupt, a cap, a failure** — the
  agent shipped with two self-moving statuses (working, idle) and a scraped permission prompt, so
  every other stop was reported as one of those and always the wrong one. `agy` publishes five hook
  events and no more; all five are now wired and their *payloads* read. `ask_question` is a tool, so
  a blocked agent is `PreToolUse` + `toolCall.name` — the strongest signal available, setting and
  clearing itself on the matching `PostToolUse` — not a log scrape. `PostInvocation` joins, because
  approving a permission prompt need not produce a `PostToolUse` at all (agy defers long commands to
  a later status step). `Stop` is one event for every ending, so `terminationReason` decides: `ERROR`
  and the caps (`MAX_*`) are error, `USER_CANCELED` is idle — agy's spelling of Claude's 130/143, and
  a row the user stopped themselves never wears red. A cancel never gets that far, though: agy calls
  the `Stop` hook with the cancelled context and kills it, so the log tail (already there for the
  permission prompt) also carries `Cancelling in-progress response` → idle, and the prompt's own
  answer, so both ends of that state are read in one place. Verified against live `agy` 1.1.8 in a
  PTY, including the negative that matters: under `--dangerously-skip-permissions` nothing is ever
  "surfaced", so the log-derived needs-input can't misfire on every tool call. Running the gates
  turned up something older on the way: a comment delivered to a freshly-live row is dropped about
  half the time, because readiness ("the TUI stopped redrawing") is close to but not the same as the
  input box being live. Delivery is now confirmed the way OpenCode's is — agy logs each prompt it
  takes, so the paste is re-sent until that receipt arrives (six tries), never blind-retried, and
  stood down when the user supplied their own `--log-file` and there is no receipt to wait for. Gate
  t18 asserts the
  full payload→signal table offline against a stub hook socket (plus the trap that an observing
  handler must print *nothing*, or agy denies the tool), and takes one live turn for the question.
- **Synth 0.21.0 shipped (build 433).** A minor: an agent that quits parks its conversation on a
  Reopen card, Ctrl-C interrupts an opencode row instead of quitting it, and Antigravity reports the
  four states it stops in. Notarized + stapled (zip + dmg), verified credential-less on the
  quarantined downloads (both Notarized Developer ID, the app inside the dmg staples on its own,
  bundle reads 0.21.0 / 433, bundled changelog leads with 0.21.0); appcast newest `sparkle:version`
  433 / `0.21.0`, all 18 enclosures EdDSA-signed, 5 deltas against 425/418/413/407/398 (721K from
  the previous build against a 131M download). Landing links unchanged, no site republish.

## [2026-07-29](docs/features/2026-07-29.md)

- **The active-pane focus strip is gone** — the 2px mark-colour bar across an active split pane's
  full top edge is removed. It was the heaviest rule in the window, spent on the least surprising
  fact on screen, and in tabs mode it ran the full width of a pane's content a few pixels under a
  tab strip already carrying the same 2px bar in the same colour. Which pane is active is still
  named where you look for it — the sidebar echo's copper open-tile, and the active tab's own bar —
  and the keyboard state `activePane` drives is untouched. `--focus` stays for the tab bar and the
  toast countdown.
- **An agent you don't use is switched off, and Synth stops offering it** — a switch per agent in
  Settings ▸ Synth ▸ Agent defaults; off drops it from every "New …" surface but never stops a
  session already running one. Enabled means enabled *and* installed; a switched-off template entry
  is skipped, not deleted, and "opens" hands off to the first survivor. Every agent off is allowed —
  the paths with no user in front of them (browser comment, feedback, MCP handoff) say so up front
  instead of swallowing what was typed. The row keeps its height when it dims, so nothing jumps.
- **A gate run happens on your machine without happening to you** — `SYNTH_AUTOMATION=1` now means
  invisible as well as drivable (`Automation.swift`): the app launches `.accessory` and never
  activates (no Dock icon, no ⌘Tab slot, no focus taken), its windows — its own and the ⌘K panel —
  are made unseeable rather than moved (`alphaValue = 0`, pointer-deaf, desktop level, out of Mission
  Control and ⌘`) while staying ordered in at full size so `automation.screenshot` still renders
  them — moving them away doesn't hold, AppKit constrains a titled frame back onto a screen and
  parks a whole legible Synth on the second display. A synthetic keystroke no longer hides the
  system-wide cursor, and a run no longer writes the developer's saved window frame. Notification
  Center posts are recorded instead of delivered, which makes the unfocused branch assertable
  (`automation.notifs` → `nc`) for the first time — t3
  proves a background needs-input reaches it, t11 that the update card never does. The porting
  skill's `TESTING.md`, which told agents to `osascript … frontmost` their instance to raise toasts
  and to fall back to `screencapture -l<WINID>`, is rewritten onto `notifRoute`/`notifFocus` and the
  in-process shot; `drive.swift` + `findwin.swift` are gone (`automation.key` lands keys without the
  app ever being frontmost). Running the gates against it surfaced a race of their own: t12 read the
  palette a fixed 0.4s after posting ⌘K and now waits for it, as t11 already did. Every verb still
  runs the exact product path — the run is quieter, not thinner.
- **Browser comments arrive as one batch, not one interruption each** — comment mode queues instead
  of sending: numbered pins accumulate on the page, a floating island owns the batch (count, target,
  one Send on ⌘⌥⏎ — not ⌘⇧⏎, which zooms a pane), and the host composes one numbered message with one
  viewport screenshot plus a clip per comment, running the ownership ladder once. A comment names an
  element, not a coordinate (element + box-fraction, so pins survive scroll/resize/zoom), and the
  composer's path widens the target up the tree — which is what a drag-a-region mode was really for,
  except exact. Empty comments cannot exist; leaving the mode parks the batch rather than dropping it.
- **Every clean agent exit parks on the quit card — exit 0 is not a gesture** — opencode exits 0
  dying on its own (observed mid-boot and ten minutes into an idle row), and its session is created
  lazily on the first submitted prompt, so the "nothing to resume → close outright" carve-out
  silently deleted exactly the row you were watching. Every agent row's clean exit now parks the
  "quit" card: Reopen resumes with `--session <id>` when one was captured, relaunches fresh when
  not. A shell's `exit` still closes a terminal row outright — there, the clean exit *is* the
  user's gesture. Gate: `t17_agent_quit`.
- **A batch of comments is only gone once it has landed** — send holds the queue on the page until
  the host confirms delivery; a rejection hands back the pins, the text and the count with the reason,
  because the last rung of the ladder can refuse (the target agent never reports live) and a batch
  cleared on the way out was lost from both sides. ⌥ is excluded from the ⌘↩ notification chord, which
  was quietly eating ⌘⌥↩ whenever a toast was up.
- **Synth 0.22.0 shipped (build 458).** A minor: browser comments arrive as one batch instead of an
  interruption per pin, an agent switched off in Settings stops being offered, every clean agent exit
  parks on the quit card (opencode exits 0 on its own, and the old carve-out deleted the row you were
  watching), and the active-pane focus strip is gone. Notarized + stapled (zip + dmg), verified
  credential-less on the quarantined downloads (both Notarized Developer ID, the app inside the dmg
  staples on its own, bundle reads 0.22.0 / 458, bundled changelog leads with 0.22.0); appcast newest
  `sparkle:version` 458 / `0.22.0`, all 18 enclosures EdDSA-signed, 5 deltas against 433/425/418/413/407
  (937K from the previous build against a 131M download). Landing links unchanged, no site republish.

## [2026-07-30](docs/features/2026-07-30.md)

- **A session reaps what left its process group** — `killpg` is the wrong unit for anything that
  `setsid`s away (Claude Code's Bash tool detaches its background shells, so an agent's dev server is
  outside the group from launch and reparents to launchd when its shell exits: 3.6 GB across 34
  processes, measured). `SessionProcesses` reaps by the `SYNTH_SESSION_ID` stamp instead, which
  survives leaving the group, reparenting, and the owning Synth exiting — recovering `setproctitle`
  renamers (`next-server`) through their parent, and killing only processes whose cwd is inside a
  folder Synth created, so the sixteen-day-old OrbStack carrying a dead session's id lives. Also at
  launch (orphans of dead instances) and on memory pressure (orphans only, never a live row's
  server). Entirely invisible: no UI, no setting. Gate: `t21_escaped_reap`.

## [2026-07-31](docs/features/2026-07-31.md)

- **A close hands off to its neighbour, not to your history (supersedes 016)** — the MRU view stack
  is gone. It popped to the last session you *viewed*, across a branch or workspace boundary, with
  the sidebar expanding and scrolling to reveal it — so where ⌘W left you was decided by state that
  appears nowhere on screen, and two identical closes landed in different repos. A five-lens panel
  agreed, and the prior art settles it: no comparable tool has an *unscoped* MRU (VS Code's is on by
  default but never leaves the editor group; tmux's never leaves the session; Chrome/Safari/Xcode/Zed
  use adjacency; list apps fall back to the parent). One sentence now: **closing a session hands you
  its neighbour in the same branch, and never takes you outside it** — the row below, else above;
  in tabs mode the strip *is* the branch, so that is the neighbouring tab; a split still just reflows
  its sibling (001); an owner's browsers can't be the successor (ADR-0011); an emptied branch stops
  at the empty pane. Closing a row you aren't viewing moves nothing but the cursor. The empty pane
  stops being a dead end (it names the branch and carries ⌘N), which is what made it worth routing
  around. Two older keyboard hazards fall out with it: the cursor lands on the successor session
  rather than falling up to the branch row (so a second ⌘W can't archive a branch), a close from the
  content no longer throws the keyboard into the sidebar (⌘W was rewriting its own scope between
  presses), and ⌘W ignores auto-repeat. *Rejected:* a setting, MRU merely scoped to the branch, a
  "returned to X" toast, a recents-list empty state. Both designs + native app. Gate:
  `t22_close_successor`.

## [2026-08-03](docs/features/2026-08-03.md)

- **An archived branch always has a way back** — archive was reversible in principle and, in three
  places, not in practice: reported on `hol-519-…` as "I can't add it back, it doesn't show up". An
  archived row keeps its slot in `branches` (that is what lets the Archived list reach it), and every
  other surface kept treating it as live. ⌘K → New branch filtered against *all* rows, so the name was
  taken and the frame came back empty — the ref exists, so even the "New branch “x”" fallback stayed
  away; it filters on `liveBranches` now and offers the archived match as a restore, with its age.
  `restoreArchivedBranch` returned false once the reaper had taken the folder, and the caller
  discarded the Bool — a silent no-op on the only route back; it can't decline any more, because **the
  branch is a git ref and the checkout is derived from it**, so the worktree is cut again at its old
  path and the row waits pending like a fresh create. And restore-from-disk dropped any archived row
  whose folder was held aside or reaped, so a relaunch forgot the branch and orphaned the held folder
  — only live rows are reconciled against disk now. The rule worth keeping: the branch is durable, the
  folder is a cache, and no gate on the restore path may end in "can't". Gate: `t9_archive` (+9).
- **A toast's × is where you aimed, not where the card ends** — reported against the update toast
  ("there's a close icon if you hover, but clicking it does not close"), and it was every toast: they
  share one `NotifCard`. The card's `contentShape` — there so the body is a big target for the primary
  action — sat *above* the × overlay, and a content shape confines everything beneath it, so the only
  live part of an 18pt disc hung 6pt off the corner was the crescent where it laps the 13pt radius.
  The centre answered nothing; you had to aim at the inside edge. The card's hit shape and tap gesture
  are pinned **under** the overlay now, and the target reaches 3pt past the disc it draws (real
  padding — an overlaid wider circle isn't hit-tested outside its parent's frame — hence offset 9 =
  6 overhang + 3 ring, leaving the disc on the design's -6/-6). Same invisible ring in both designs as
  `.notif__x::before`. Gate: synthetic clicks into the running app — centre dismisses without firing
  the action, 11pt out dismisses, 14pt out doesn't, Restart still works; pre-fix build fails at centre.
- **Geist, and a type scale with six steps instead of twelve** — the system face gave way to Geist +
  Geist Mono (variable TTFs, OFL), and the twelve sizes that lived between 9px and 15px, most half a
  pixel apart, collapsed into six at least 1px apart: 10 · 11 · 12 · 13 · 14 · 15. Floor up from 9,
  body from 11.5. All eighteen negative-tracking rules deleted — they were SF Pro calibration, and
  Geist already sets ~2.3% narrower, so keeping them ran ~4% tighter than intended; positive tracking
  on uppercase labels stays. Leading opened to 1.5–1.65 because Geist's line box is 10% taller than SF
  Pro's at the same size (a deeper descender; cap and x-height are within a hair), and containers grew
  to match. *Rejected:* retuning tracking on SF Pro alone, Geist sans with SF Mono kept, and Vercel's
  own 12px floor / 16px body — that is a page you read, not chrome you work inside. Both designs +
  native app.
- **Weight is an axis, not seven names** — the fonts ship variable because working.html uses 450, 550
  and 570, which `Font.Weight` cannot name; `.medium`/`.semibold` had been rounding all of them to the
  wrong side, turning the notification title's 20-unit distinction from its ambient sibling into a
  100-unit one. Call sites now pass the CSS number verbatim (`.sans(13, 550)`) and `Typography.swift`
  instances the `wght` axis; verified against the built `.app` as five distinct widths, the odd ones
  genuinely interpolated. Same file closes a trap: Geist's default figures are *proportional* (`'111'`
  barely half the width of `'000'`), so `tabular:` applies `tnum` explicitly where seven sites had
  leaned on `.monospacedDigit()`, which only knows the system face.
- **Three defects the type audit turned up, unrelated to the typeface** — the device status bar hung
  its size off `isTablet` but its weight off Android, where working.html keys both off Android alone
  (so an iPad's bar was sized like Android's, and an Android phone's like iOS's); the scratch-terminal
  confirm buttons carried `.dialog__btn`'s padding and fill but no font, leaving them in the system
  face; and the pane header title sat a step behind its siblings because the rescale matched bare
  literals and its size was a ternary. Also recorded: `.kerning()` and `.lineSpacing()` are absolute
  points and follow no size change on their own, and SwiftUI gives a custom font its natural line box,
  so the design's `line-height` never arrives for free.
- **Stem darkening off — the designs were never asking for heavier text** — `-webkit-font-smoothing:
  antialiased` had been in the design files all along, and besides naming an antialiasing mode it also
  switches off the dilation CoreGraphics applies on top of it. Both sides were already
  grayscale-antialiasing identically (subpixel left macOS in Mojave), so the whole difference was
  weight — and measured on the real AppKit path it is 11–15% more ink at our sizes, meaning identical
  nominal weights rendered ~12% heavier in the app than in the design. That was the "chunkier" read
  left over after the tracking, leading and pane-title fixes. `Typography.matchDesignFontSmoothing()`
  sets `AppleFontSmoothing` to 0 from `SynthMain`, before the first glyph; it must be the persistent
  domain, since CoreGraphics reads the key through CFPreferences and never sees
  `register(defaults:)`. *Still open:* the designs run two tiers (chrome thin, `auto` on `.term` /
  `.set-code` / `.scr__body`) and the app runs one — `.set-code` is a native `TextEditor` in the wrong
  tier — and 12% less ink at the scale's new 10px floor is a legibility cost worth eyes on.
- **The design files stop depending on the network** — Geist came from a Google Fonts `<link>`, which
  made both design files conditional on connectivity: offline they fall through to SF Pro and still
  render, just not as the design. Now an inline `@font-face` pair over vendored variable woff2s in
  `fonts/`, `font-display: block` because a flash of the wrong typeface is the failure mode for a file
  whose purpose is to be looked at. Verified: zero requests to Google, axis still interpolating.
- **Two dialog surfaces that had never matched** — `.field label` was sentence-case 11/500 against the
  design's 10/600 uppercase on 0.05em, and the dialog action buttons carried no font at all, leaving
  them in the system face; they now take `.dialog__btn`'s 13/550, set on the actions row rather than by
  restyling, so the native default/cancel affordances survive. *Not done:* a second smoothing tier for
  `.set-code` — per-view stem darkening has no clean SwiftUI seam and the payoff is unverified, so it
  is recorded rather than worked around.
- **A project is a git repository, or it isn't a project** — reported as a dead end: add a non-git
  folder, it lands looking fine, then "New branch" fails on `fatal: not a git repository` with no way
  to fix it from inside Synth. A panel of five was asked the open question and was unanimous: every
  branch is a worktree, so a folder that can't host a branch can't be a project — a branchless row
  can hold no session and does nothing. Two corrections came out of it. The test is **"does this
  folder have a branch", not "is this a git repo"**: four folders produced the same branchless
  project, and the likeliest is a repo — `git init` with no commit, where `refs/heads` is empty and
  `worktree add -b x <path> HEAD` dies on `invalid reference: HEAD` — so a repo-ness check would have
  shipped the bug again. And a **subdirectory** was accepted, which was worse than the dead end:
  `--is-inside-work-tree` is true for any descendant, so one repo became two projects with two
  `worktreeRoot`s; the pick resolves through `--show-toplevel` now, which also collapses symlink,
  `/tmp` and case-only spellings, so re-adding a project reveals the one you have. The refusal lands
  in `panel(_:validate:)` — once, on Add, leaving the panel on the folder you were looking at — as a
  filesystem probe for `.git` *existing* (it is a file inside a linked worktree), never a git spawn on
  the main thread under a modal; the same decision is made again where the project is created, for
  callers with no panel. Also: **a Retry button is a claim that identical input could produce a
  different output**, so the second identical failure withdraws it (a different reason is asked
  afresh, a materialised branch earns it back), "No worktrees yet" → **"No branches yet"**, and the
  Notification Center post carries the card's one line rather than the whole git dump. *Rejected:*
  offering `git init` (4–1) — the usual mistake is the *wrong folder*, so one click makes a slip
  permanent, and `init` alone leaves no branch, so Synth would have to author the first commit too;
  plain folders as a second kind of project. Gate: `t23_projectgate`.
- **Synth 0.23.0 shipped (build 478)** — a minor led by the typeface: Geist on a six-step scale with
  the designs' own tracking, leading, weights and stem darkening. Plus four kept promises — a close
  hands off to its neighbour in the same branch, an archived branch always has a way back, a project
  must be a git repository with a branch (refused at the picker, subdirectories resolved to the
  root), and a notification's × closes it wherever you click it — and two invisible fixes shipped as
  changelog lines because their absence was noticed: escaped-process reaping and the launch crash on
  a moved or unmounted project folder. Notarized + stapled (zip + dmg), verified credential-less on
  the quarantined downloads (both Notarized Developer ID, the app inside the dmg staples on its own,
  bundle reads 0.23.0 / 478, bundled changelog leads with 0.23.0); appcast newest `sparkle:version`
  478 / `0.23.0`, all 18 enclosures EdDSA-signed, 5 deltas against 458/433/425/418/413 (1.1M from the
  previous build against a 131M download). Landing links unchanged, no site republish.
- **…and stem darkening back on: the menu bar is not ours to restyle** — reverses the entry above, same
  day. `AppleFontSmoothing` is read per *process*, so switching it off thinned Synth's own menu bar
  along with its chrome, and a menu ~12% lighter than every other app's is Synth failing to look like a
  Mac app where the OS sets the vocabulary. `working.html` never modelled the menu bar;
  `-webkit-font-smoothing: antialiased` spoke about Synth's surfaces, not the process. No seam exists to
  scope it (the wall that also stopped `.set-code`), so the override is gone and the ~12% gap between
  app chrome and the design files is an accepted divergence — the cost of AppKit rather than WebKit
  drawing the text. Remember two things it cost: the preference *persists*, so deleting the code is not
  a revert until the key is deleted too; and the domain is *shared across worktrees* via `CFBundleName`
  "Synth Dev", so another checkout still carrying the override rewrites it for everyone.

## [2026-08-04](docs/features/2026-08-04.md)

- **The window is translucent, terminal included** — the window server blurs the wallpaper behind the
  window and every surface above it is a plain fill over that one sample. It is deliberately *not* an
  `NSVisualEffectView`: every AppKit material tints as well as blurs, and that tint multiplies with the
  surface alpha above it, so `.underWindowBackground` left ~4% of the wallpaper showing and greyed out
  light mode. `CGSSetWindowBackgroundBlurRadius` (radius 60) adds no tint — what CSS `backdrop-filter`
  does, and what Ghostty does. Private API, so it is `dlsym`'d once and treated as an enhancement: with
  it missing the window stays opaque, because the failure to avoid is not "no blur" but a translucent
  shell over a *sharp* desktop. One blur means one translucent coat (`Theme.windowCoat`), and anything
  differing from it is a tint **on** it — two compound to near-opaque, so the desktop would show through
  the pane but not the sidebar, and the sidebar's rounded corners cut a hole through to the wallpaper.
  Hence `sidebarStep` as `mono(0.04, 0.025)`: a tint of the ink holds its step where a fixed colour
  breathes with the wallpaper. Dark carries **0.11** more opacity than light (0.97 vs 0.86) and the gap
  is the finding — the same light is a ~3% change on light's 250 and a ~28% lift on dark's 25, so a
  near-equal pair read as too transparent in dark and too flat in light at once. Radius before opacity:
  radius decides how recognisable the desktop is and costs nothing, the coat costs legibility. It cost
  one grey — `--ink-meta` darkened 16 levels in light, because it cleared 4.5:1 with zero margin and no
  coat value could hold both (the sidebar only clears again at a fully opaque 1.00). The terminal
  participates rather than sitting on the effect as an opaque slab: chrome-only and
  everything-but-terminal were rejected because half the effect costs nearly all the legibility risk and
  buys none of the impression. Ghostty now paints the whole card, inset included, at 0.55/0.58 — a
  SwiftUI fill behind the cells made them a second coat and the terminal read as more solid than its own
  border. Three bugs surfaced, all the same shape — something quietly relying on an opaque surface to
  occlude what was behind it: that double-coated terminal, the card's own `.shadow` (SwiftUI blurs
  *alpha*, so it showed through the card it belonged to), and the tabs-mode first-tab bleed (a plain
  rectangle that an opaque sidebar used to hide all but the corner of).
- **Tabs are chips on a rail, and a split is a hairline tray** — the strip stops being one solid band
  welded to the window: each tab is a 28px chip on a 42px rail, and the open one lifts off it as a card,
  which is the whole of "open" — no seam, no bottom bar, no fill reaching the window edge. Three chip
  directions were built live in the shell (**inset** elevation, **track** recessed-well-and-thumb,
  **focus** icon-only-unless-on-screen) and inset won; track truncates first because everything shares
  one hugging container, and focus is unreadable at a glance when half the sessions share a terminal
  icon. Because nothing reaches the seam, `.tab-bleed` — an element plus a `radial-gradient` mask plus
  two `:has()` rules, existing only so the first tab's fill followed the sidebar's rounded corner — is
  **deleted**. A split's run of members got its own round (**tray** / **bracket** / **lead** glyph /
  **merged** into one chip); tray won, but its recessed *fill* was wrong and is gone: on this strip a
  background is what open means, so filling the tray handed every unfocused member the one signal
  reserved for one tab. It is a hairline container over the bare rail now. **Merged** is the direction
  to keep in reserve — the only shell that gets cheaper as a split grows (a four-pane split leaves every
  other tab its full name) — rejected on signal, not space: a non-active member loses its indicator, so
  a pane going to needs-input behind the chip says nothing. The members' refusal to shrink was
  `min-width: auto` on `.tab-group`: as a flex item its floor was its own min-content, where a lone
  `.tab` escapes that by setting `min-width: 34px` explicitly. Zeroing it puts a member on the same
  terms as every other tab, which is the premise — a member IS a tab.
- **Tabs-mode branches carry their session facts without growing a third tree level** — the branch
  row becomes a 46px two-line summary (`N sessions · activity`) with a fixed PR/status rail; classic
  sidebar mode keeps its original compact disclosure row. Both designs + native app.
- **The pre-notarization Gatekeeper check asserts *why*** — `spctl`'s expected `rejected` before
  notarization was indistinguishable from a broken-build `rejected` because the line ended in
  `|| true`; it now requires `source=Unnotarized Developer ID` and dies on anything else, and says
  so in the log. Release skill also records: never edit `release.sh` mid-run.
- **Claude Code answers for its own colours in light mode** — light mode was unreadable because
  `theme` in `~/.claude.json` is read **once at startup**: measured, a running session ignores a rewrite,
  so Synth's old sync only reached *new* sessions and every open one kept painting Claude Code's dark
  theme onto a near-white surface — body text `#ffffff` at **1.06:1**, **57 of 72 tokens** under 4.5:1.
  `theme: "auto"` is the trap: it enables DEC 2031 and then ignores every notification, so it resolves
  to dark regardless, and the old guard deliberately *skipped* it. Synth now ships its own
  `custom:synth` theme and re-themes by rewriting `~/.claude/themes/synth.json`, which Claude Code
  watches — proven to re-theme a **running** session both ways. One file, not a pair, because the
  tokens, the diff renderer *and* the syntax highlighter all follow the single `base`. **20 light
  overrides**, hue kept and only lightness lowered, worst being `subtle` at **2.06:1** (the grey every
  hint and timestamp uses). Left alone with reasons: `diffAddedWord`/`diffRemovedWord` are *fills* with
  black painted on them (deepening them drove that ink 17:1 → 4.28:1 — reverted), `inverseText` is white
  by design so its backing is fixed instead, `clawd_background` is the mascot. Recorded not fixed, no
  lever: the syntax highlighter (a separate wholesale palette, `#0086b3` at 3.90) and one hard-coded
  `#5769f7` (4.14) proven non-themeable by forcing every token magenta. Dark rides untouched and is
  pinned where it ships, not gated. New `t24_agentcontrast` replays a real session through a small
  terminal emulator and measures every run of ink against its own background, parsing the override
  table out of the Swift so the gate cannot pass a theme the app does not write.
- **The archive becomes a place you can stand, and the design files catch up to `ArchiveSweeper`** —
  Settings gains the app's clean-up switch and grace picker plus two new disk-budget rows (25
  worktrees, 50 GB), and a per-project list of what is still on disk carrying each folder's sweeper
  verdict — `PR still open`, `6 days left` — with Restore and a permanent delete that confirms in
  the ⌘K frame (one `deleteWorktreeFrame`, two callers — no dialog). The verdicts are the policy,
  so the section states no rule in prose. A budget brings an unblocked folder's turn forward; it
  never lets one past a gate. ⌘K's archived list is now project-scoped and drills in, and its
  confirm is the one Settings' trash opens. Both designs + native app.
- **A waiting build gets a button in the sidebar foot, in the mark's own hue** — Settings drops its
  `⌘,` hint (unchanged shortcut, still in ⌘? and ⌘K); a `Restart to update` row washed in the icon's
  champagne stands above it for as long as a downloaded build sits unapplied. The update notification
  card is gone — a waiting build never toasts, both its surfaces are pull. Both designs.
- **opencode's light half stops being too pale; `agy` has no lever at all** — the same measurement run
  against the other two agents, finding three different problems. **opencode's machinery already
  works**: it asks the terminal its colour (OSC 10/11), enables DEC 2031, and re-themes a *running*
  session on notification — the first reading, that it painted `#0a0a0a` on a light surface, was the
  2026-07-27 harness artefact again (a pty that records output without answering makes it fall back to
  dark). Its *values* were wrong: against the surfaces opencode paints for itself (it never lets the
  terminal's show through, so `#f5f5f5` is the reference) `textMuted` sat at **3.17:1** and
  `accent`/`warning` at **2.52:1**. Synth now installs `~/.config/opencode/themes/synth.json` with
  **11 values deepened**, hue kept, dark half copied through — which `t25` proves by extracting
  opencode's own theme from its binary and comparing rather than claiming. A partial theme *crashes*
  opencode, so this is a fork that will drift, and the gate renders a real opencode so a stale key
  fails loudly. **`agy` gets nothing**: it asks the terminal nothing, has no theme setting anywhere,
  and paints hard-coded truecolor (`GetThemeMode` in its binary is Chrome DevTools, a red herring), so
  `t26` pins at 2.70:1 and records `#4285f4` 3.35, `#d0d0d0` 1.45, and `#9296a1` 2.78 — that last one
  Synth's own ANSI slot 7, a documented dead end: darkening it for agy's ink drops t13's
  slot-7-as-a-fill from 4.5 to 3.64. `ccontrast` gained a **fill** role (block elements are surfaces,
  not controls — reported, never gated), which retired the `clawd_body` override.
- **Correction: `agy` does have a colour-scheme setting, and its default is still the right one** — the
  entry above claims it has none. It has **Color Scheme**, eight options with a live preview, invisible
  from outside (not in `--help`, not a subcommand, absent from `settings.json` until changed) because it
  lives in the interactive `/config` panel and persists as a plain `colorScheme` string. Synth still
  writes nothing, for a better reason: **no option is accessible and the default is the best of them**.
  On a real conversation, 168 runs, light surface — `terminal` 2 failing / worst text **1.45** (code
  fence); `light` and `colorblind-friendly light` 4 failing / worst text 2.80; `solarized light` 5
  failing. `terminal` wins because it draws most of its UI from the **ANSI palette** `TerminalTheme`
  already tunes to 7:1 — Synth's palette beats agy's own light theme, so switching schemes discards it,
  repairing the code fence while breaking the separator to 1.29:1 and adding two more: one bad value
  traded for four. `t26` gains a fourth screen (the settings panel) and prints the Color Scheme row, so
  an accessible scheme appearing upstream shows up rather than going unnoticed.
- **Two loose ends closed: the subagent hues are dual-use, and an ANSI light base was declined** — the
  eight `*_FOR_SUBAGENTS_ONLY` overrides were unverified, which is how the `diffAddedWord` mistake
  happened. They cannot be rendered from a transcript (a subagent tree never reaches for them; they are
  assigned live), so the code settled it: `bht()` feeds them to a badge as **`bgColor`**, and the badge
  resolves its foreground as `textColor ?? "inverseText"` — **white on the token** — while the same
  token is ink for the rule beside it. Both uses want darker, so the overrides were right: as ink
  2.75–3.53 → 4.60–4.64, as a fill under white **2.93–3.76 → 4.89–4.93**. `t24` now asserts the second
  half, which is the `diffAddedWord` check generalised. Separately, `base: "light-ansi"` was measured:
  Claude Code picks its syntax theme from the resolved base by substring, so an ANSI base routes the
  highlighter, the diff renderer *and* the hard-coded `#5769f7` through the palette `t13` already gates
  — **0 failing text runs** (2 chrome, worst 2.19) and no override table at all, versus 6 failing text
  runs (worst 3.52) today. **Declined on appearance, not contrast**: sixteen colours would make light
  read visibly flatter than dark, and light and dark ceasing to look like the same app is worse than
  six legible-but-poor runs. Recorded with the numbers so it stays a decision taken, not one to redo.
- **0.26.0 ships** — the version boundary: the eight entries above this line are 0.26.0, `CFBundleVersion`
  515, tag `v0.26.0`. Four reach the in-app changelog (the chip tab strip, agent light mode, Settings ▸
  Archived, the update row in the sidebar foot); the other four are the measurement behind them and stay
  ledger-only, because a decision the reader was never going to make is not a changelog line. The two
  agent-theme entries collapse into one, since from outside they are one thing — light mode is legible
  *inside* the agent now — and the line leads with the number a user can check (body text 1.06:1, 57 of 72
  colours under threshold) rather than with which agent needed which fix. Both artifacts were re-verified
  from the public bucket with no credentials and quarantine set: the `Synth.app` **inside** the dmg
  staples on its own, not just the image around it, and every appcast enclosure including all 5 deltas
  carries an `edSignature`. Landing page unchanged — its buttons point at the stable `Synth.dmg` alias,
  so the alias moved under it and `synth-site` needed no push.
- **The rail stops being deeper than the run it holds: 42px → 36px** — a split's tray sat in 5px of
  vertical air top and bottom while the gap to the tab beside it was 3px, and that mismatch is what read
  as too much space above the tab group. 36px is the 32px tray plus 2px — the same 2px the tray already
  gives its own members, so the clearance around the run matches the clearance inside it. Nothing inside
  the tray moved: 2px there is what keeps the tray's hairline off the active member's hairline, and taking
  it to zero would leave the tray visible only in the 2px side gaps. **Cost, taken knowingly:** the chip
  row is centred in the rail, so it rises 3px and now sits 7px (was 4px) above the centreline of the
  traffic lights and the sidebar toggle. Those can't come up to meet it — AppKit fixes the lights'
  vertical position — so the choice was a tight rail or an aligned top row, and tight won.

## [2026-08-03](docs/features/2026-08-03.md)

- **The simulator is a session, and its screen comes from the device's framebuffer** — the simulator
  existed as vocabulary and a drawn frame in the designs with no Swift behind it. Now a session claims a
  device from the installed fleet, boots it, streams its screen live into the pane, takes pointer and
  keyboard input as Indigo HID, and exposes the same device to Claude through a 13-tool
  `synth-simulator` MCP server. Pixels come from the device's own `IOSurface` off `SimDevice.io` into an
  `AVSampleBufferDisplayLayer`; **Simulator.app is never launched**. ScreenCaptureKit window-mirroring was
  rejected (dies when the window is minimised or on another Space, needs a Screen Recording grant, and
  `CGEventPostToPid` silently drops mouse-move and scroll), and Xcode 27 replaces Simulator.app anyway.
  Private API knowingly, as every shipping implementation does — Developer ID + notarized was tested and
  needs zero entitlements, at the price of the Mac App Store. v1 attaches and drives; it does not build
  your app. Devices are shared machine state, released by reference count, and carry no owner — an agent
  must not shut down a device you are looking at. The live screen sits inside 0.18.0's hardware frame with
  our drawn status bar removed, since iOS paints its own. Measured: 50.9 fps, gap p50 16.96ms, 22µs of our
  own cost per frame, 59–70ms tap-to-visible-change. Full entry has the traps — the inert duplicate
  display port, `UDID` vs `udid`, the boot race, and frames being live views rather than snapshots.

- **The simulator's screen can be read as text** — `simulator_describe` reads the frontmost app's
  accessibility tree off a booted device: role, label, `#identifier`, value and state, one element per
  line, each with its frame's centre in the same normalised 0..1 coordinates `simulator_tap` takes.
  Discovery through `describe`, action through `tap` at a centre. Settings' root is **1069 bytes against a
  219 KB screenshot** — 205× on the wire, ~300 tokens against ~1,500 — and it carries the identifiers a
  screenshot makes you guess at. No XCTest runner and no injected bundle: `SimDevice`'s
  `sendAccessibilityRequestAsync` plus `AXPTranslator` with our own `bridgeTokenDelegate`, which is the
  only reason the translator knows which device a request belongs to. Two request kinds, both needed — the
  frontmost-app walk, and a point hit test that reaches what the walk cannot (childless SwiftUI tab bars,
  and SpringBoard's status bar, which is not in the app's tree at all). A degraded session has no
  accessibility and refuses with the reason, because `simctl` has no such verb and an empty tree would read
  as an empty screen. Full entry has the traps — the single delegate slot, per-object token stamping,
  `mainScreenScale` not being a `double`, and the framework that exists only in the dyld shared cache.

- **The simulator session is finished — usable input, a fallback that has been run, and a type that stops
  lying** — typing had no delete, escape or arrows, so backspace in the pane silently did nothing; there was
  no scrolling at all, and trackpad phases now map onto a continuous touch drag rather than a burst of taps;
  the pane gained device name, runtime and Home/Lock buttons, none of which were reachable since the frame's
  side buttons are drawn hardware; and `simulator_terminate` completes the lifecycle set, because launching a
  running app only foregrounds it, so an agent could not reach a known starting state (15 tools). The
  designed `simctl` fallback is now exercised rather than assumed — one seam disables the framebuffer, Indigo
  HID and accessibility together, since the failure it exists for is an Xcode release moving the private
  frameworks, and running it found that input was not being declared degraded because opening the HID session
  is asynchronous. `BrowserDevice` became `HardwareDevice` now that it frames simulators too. The self-check
  guards persistence, including the `SessionKind` raw-value arm that would otherwise decode every persisted
  simulator as a bogus agent. Verified end to end: the real ⌘K route, the live pane, and the agent path
  running terminate → launch → describe → tap at the reported centre → describe, on one shared session id.

- **An unbiased review said do not ship, and five gating findings later it does** — the private-API layer
  survived the review (a simulated Xcode-27 framework relocation left screen and accessibility live, only
  input degrading, no crash); everything serious was the app integration around it. Worst, measured: the
  attach path shelled out to `simctl` on the main actor every retry tick, blocking 76% of it for the length
  of a cold boot. Also fixed: input verbs answering `ok` for taps that never left the process, a dead device
  serving its last frame as a fresh screenshot, devices never released, and an unsynchronised HID handle.
  Three of the fixes had bugs of their own that tests caught: scrolling was inverted (AppKit's delta sign),
  quit-time device release never ran (the signal path installs no handler without CEF — so claims are now
  recorded and reconciled at launch, verified by `kill -9`), and gating a claim on a cached `isBooted` meant
  nothing ever booted the device. 29 assertions pass live plus forced-degraded, memory flat over six minutes
  of 60Hz streaming, behind an Experimental toggle that is off by default.

- **The simulator rotates, and comment mode is written but withheld** — rotation goes through the device's
  `PurpleWorkspacePort` with the wire format read out of Simulator.app's own disassembly, since `simctl` has
  no orientation verb at any version; plus `simulator_shake`. Three assumptions died on contact: the
  framebuffer does not resize when the device rotates (iOS draws sideways into the same surface), there is
  no orientation read-back at all, and Settings is portrait-only so verifying against it would have proved
  a working mechanism broken. It exposed a real bug above it — the accessibility tree normalised landscape
  frames against the portrait profile, so describe→tap could not round-trip — and the assertion that shipped
  with rotation had encoded that bug as expected behaviour. Comment mode (click an element, send it to the
  owning agent, anchored on the accessibility identifier) is implemented, its delivery ladder now shared
  with the browser rather than copied, and **not offered**: delivering from an unowned simulator
  reproducibly exits the app and is not root-caused. 37 assertions pass live plus forced-degraded.

## [2026-08-04](docs/features/2026-08-04.md)

- **The simulator's comment mode is offered — the app-exit was one `%s`** — delivering a comment exited the
  whole app because the log line on the delivery ladder's success path passed a Swift `String` to `%s`,
  which hands `strlen` a tagged NSString pointer. It looked like nothing because libghostty's bundled
  Breakpad owns the task's Mach exception ports, so the fault never became a signal: no crash report, no
  marker, just `exit(1)`. Both rungs carried it, including the browser's shipped path. The toggle and its
  target chip are restored, both rungs are driven end to end on a real device with the comment landing in
  the agent's transcript, and the accessibility hit test moved off the main actor — it was a click that
  could freeze the window for over a minute.

- **`simulator_describe` answers in landscape, because the projection is confirmed rather than assumed** —
  accessibility frames arrive in the interface's coordinate space and `tap` addresses a display that never
  rotates, and nothing on this platform will say which way up an app laid itself out. The space is now
  *confirmed* per read by hit-testing where an element's centre is predicted to land and requiring that
  element back — possible only because frames come back in the interface's space while `objectAtPoint:`
  goes in in the display's. Costs one round trip; a portrait-locked app reads as portrait however many
  rotations it was sent. Three of the previous attempt's findings were corrected, and one new one found: a
  tree can be in two coordinate spaces at once, with the landscape keyboard's keys reported in the
  display's space as flat siblings of the app's own elements. The assertions now tap a reported centre and
  require a named consequence, after `tap-changed-screen` was shown to pass while the tap hit the wrong row.


- **Simulator sessions, verified across three independent reviews** — rotation, the landscape coordinate
  projection, comment mode, and the honesty rules the reviews forced. The projection normalises by the
  interface's own extent and then applies that orientation's transform, and rather than trusting arithmetic it
  **confirms the space against the device per read** — predict a centre, hit-test it, accept only if the same
  element answers. It also handles a screen in two coordinate spaces at once (with the keyboard up, app
  elements come back in the interface's space and every key in the display's). Comment mode clicks an element
  and sends it to the owning agent anchored on the accessibility identifier, sharing one delivery ladder with
  the browser because it is a security boundary. Round three found the previous rounds' rule surviving on the
  verb they each missed: against a device shut down underneath, `type` answered ok 4/4 and `tap` 3/8, because
  readiness asked whether a HID client existed — and the client outlives the device. Every input verb, plus
  `describe`, now asks the device; comment mode refuses to hand over a stale frame as evidence. The check's
  own device handling had reintroduced an earlier fix's bug, and its coverage gap for the mixed-space case is
  a failure now rather than a PASS that quietly meant "not run". 48 assertions plus forced degradation.

## [2026-08-05](docs/features/2026-08-05.md)

- **Active tab lift, fixed for dark mode** — dark mode was reusing light mode's black drop shadow at
  higher opacity, which reads as nothing against an already-dark rail; swapped in a top highlight +
  tight contact shadow, the standard dark-UI substitute for ambient shadow.

## [2026-08-06](docs/features/2026-08-06.md)

- **One coat, no seams** — sidebar tint/corner/shadow and every shell hairline (sidebar seam, pane
  header, sidebar foot) removed; the raised session card is the only surface, its left edge is the
  sidebar-resize grab (hover thickens it along the straight run, stopping at the corner radius),
  and Claude Code now renders as the TUI it really is, inside the same terminal card as the shells.
- **0.27.0 ships** — the version boundary: the ten entries above this line are 0.27.0, `CFBundleVersion`
  532, tag `v0.27.0`, minor for the simulator headline. Four changelog lines: the seven simulator entries
  collapse into one (from outside they are one feature, Experimental and off by default), the three
  tabs-mode entries into one, one coat stands alone, and the paste-hang fix gets a line despite no ledger
  entry of its own. Verified credential-less with quarantine set: dmg and the app inside it both notarized
  and stapled, appcast newest item 0.27.0 at `sparkle:version` 532, `edSignature` on all 18 enclosures
  including 5 deltas. Landing page unchanged — no `synth-site` push.

## [2026-08-07](docs/features/2026-08-07.md)

- **Branch hover card (tabs mode)** — hovering a branch row fades its whole rail, so a 300px
  read-only card to its right pays back what the hover hid: the hidden session rows unpacked one
  level, each cloning the tree row's own icon and indicator so the card can never disagree with the
  rail. A fact per session only where there is a real counter (`step 4/6`, `18 failed`) — no clocks,
  no percentages — a `+N idle` valve at seven rows, and one monochrome branch line carrying the PR
  number and diffstat. The branch name is never repeated. Pointer-transparent, 350ms cold / 60ms warm,
  repositions rather than rebuilds, and dies instantly on scroll, drag, blur or Esc.
- **Hover card ported to the app** — `BranchHoverCard.swift` (card + hover model + root anchor
  overlay), reusing `SessionIcon`/`Ind`/`StatusIndicator`/`OwnedIndicator`/`TabIcon` outright. Two
  gaps handled rather than faked: the meta counter has no data source in the app so the column
  renders empty, and the diffstat needed a new `DiffStatCache` (`FolderSizeCache`-shaped, 30s
  floor, refuses to guess a base branch) because every `GitService` call blocks. Card tracks its
  row on scroll instead of dismissing — the anchor cannot desync.
- **0.28.0 ships** — the version boundary: the two entries above this line are 0.28.0, `CFBundleVersion`
  544, tag `v0.28.0`, minor for the hover card. Two changelog lines: the hover card's design and port
  collapse into one (from outside they are one feature), and the tab-chip alignment fix (chips inset 8px
  against the content's 14px) gets a line despite no ledger entry of its own. Verified credential-less
  with quarantine set: dmg and the app inside it both notarized and stapled, appcast newest item 0.28.0
  at `sparkle:version` 544, `edSignature` on all 18 enclosures including 5 deltas. Landing page
  unchanged — no `synth-site` push.
- **Clicked file:// terminal links resolve instead of popping the OS "-50" dialog (native app)** —
  Claude Code's OSC 8 file links carry `:line` inside the path and sometimes a hostname;
  `openFileLink` now resolves both before opening, and a path not on disk raises an in-app toast
  naming it rather than Launch Services' bare numeric dialog.
- **0.28.1 ships** — patch carrying exactly one change, the file:// link resolution above:
  `CFBundleVersion` 548, tag `v0.28.1`, one changelog line told from the click. Verified
  credential-less with quarantine set: dmg and the app inside it both notarized and stapled,
  appcast newest item 0.28.1 at `sparkle:version` 548, `edSignature` on all 18 enclosures
  including 5 deltas. Landing page unchanged — no `synth-site` push.
- **The terminal cursor empties out when it isn't taking keys** — hollow, unblinking block in any
  pane that doesn't hold the keyboard and in every pane while Synth is in the background.
  libghostty already draws it; the app now tells it the truth (focus = first responder *and* key
  window), and both designs mirror it via `pane--active` / `body.unfocused`.
