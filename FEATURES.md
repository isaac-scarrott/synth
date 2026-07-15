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
- **Copy the branch name from the pane header** — a hover-revealed copy button after the
  `workspace / branch` crumb; one click copies the branch name and flashes a green check
  (`navigator.clipboard` in the mock, `NSPasteboard` native). Both designs + native.
