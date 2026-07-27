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
