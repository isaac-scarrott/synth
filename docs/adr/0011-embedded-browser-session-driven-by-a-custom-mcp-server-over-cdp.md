# The browser is a Synth session, and Claude drives it through our own MCP server over CDP

Synth already treats a browser as a first-class session type (CONTEXT.md, and the `data-type="browser"`
row in the designs). This ADR commits to what that session *is* and, more consequentially, to the
architecture that lets Claude Code drive it later — because the engine we pick for the visible browser
in stage one is constrained by the way we want Claude to control it in stage two.

The feature had three stages when this was written, and only **stage one** was being built. It has
five now; stages one to four are built, stage five is decided and not yet built:

1. **A browser you can use.** An embedded, Chromium-based browser that lives as a session inside a
   branch's worktree — navigable like any browser, opened at the same level as a terminal or a Claude
   Code session. Its primary job is checking your work.
2. **A browser Claude can use.** Claude Code drives that same embedded browser the way `claude --chrome`
   drives real Chrome today — navigate, click, screenshot, read DOM, read console/network — but rooted
   into Synth's browser instead of an external one. Claude can spawn, list, and connect to the browser
   sessions belonging to a branch.
3. **A browser you and Claude share.** A two-way mode: the user clicks/selects elements on the live
   page and leaves comments, which flow back to the Claude Code session that owns the browser as
   located context, and Claude acts on them.
4. **A browser that belongs to a Claude session.** (Added 2026-07-06.) Ownership becomes a real,
   visible containment relationship — see the stage-four section below.
5. **A browser that lasts, and knows what it is not.** (Added 2026-08-18.) State survives the
   session, the agent can drive a real page rather than a simple one, and the long tail of
   browser-shaped features Synth will never build is written down — see the stage-five section.

The stages are recorded here together because stage one must not paint stages two and three into a
corner. Everything below is the decision; the reasoning that ruled out the alternatives follows.

## The engine must expose the Chrome DevTools Protocol, so it is Chromium, not WebKit

**The visible browser and the agent-driven browser are the same surface.** Stage three only works if
the page the user is clicking on is the page Claude can read and act on — one browsing context, not a
user browser beside a separate agent browser. That single requirement is what forces the engine
choice, because agent control means the browser must speak the **Chrome DevTools Protocol (CDP)** — the
wire protocol Playwright/Puppeteer and the whole automation ecosystem expect.

`WKWebView` (Apple WebKit) is the tempting stage-one engine: an `NSViewRepresentable` wrapper is a few
dozen lines, it ships with macOS at zero bundle cost, and it sandboxes and notarizes cleanly. But
**WebKit does not speak CDP.** Its `isInspectable`/Web Inspector remote protocol is not wire-compatible;
driving it means either the partial RemoteDebug WebKit adapter (a translation hop, not the full
surface) or hand-rolling automation through `evaluateJavaScript` + injected user scripts. Choosing
WKWebView for stage one is choosing to throw the engine away at stage two, or to reimplement CDP by
hand.

**So the engine is Chromium, embedded via CEF (Chromium Embedded Framework).** CEF lives in our process
tree and exposes a real CDP endpoint with one setting (`remote_debugging_port` / `--remote-debugging-port`),
serving the exact `/json/version` + per-target WebSocket surface automation clients connect to. It is
the only option that is *both* embedded in-panel *and* natively CDP-drivable. This is essentially
Cursor's architecture (an embedded Chromium webview driven over CDP, wrapped in an agent tool layer) —
they got Chromium for free by being an Electron app; as a native SwiftUI app (ADR-0002) we pay for it
explicitly through CEF.

The cost is real and is accepted: a Chromium framework adds roughly **150–250 MB** to the bundle, CEF
requires **four separately-signed helper bundles** (GPU, renderer, plugin, main) each with their own
hardened-runtime entitlements, and notarization is fiddlier than a pure-Swift app. Distribution is via
Developer ID + notarization, not the Mac App Store, where Chromium's JIT entitlements invite scrutiny.
None of this is prohibitive — many CEF apps ship this way — but it is why the browser is its own
subsystem, not a one-file view.

**What we explicitly reject:** reparenting a separately-launched Chrome/Electron window into our
SwiftUI view hierarchy. Cross-process window adoption is not possible through public AppKit API on
modern macOS and breaks the sandbox; every serious project (Zed, the CEF community) routes around it.
The choice is genuinely binary — bring Chromium in-process (CEF) or accept a detached companion window
— and a detached window fails the "same surface" requirement above. If CEF integration proves too slow
to stand up, the sanctioned fallback is a WKWebView stage one *behind the engine protocol below*,
accepting a later engine swap; it is a schedule hedge, not the target. **(Retired 2026-08-18 — the
hedge was spent the day CEF shipped, and a fallback engine with no CDP is worse than no browser;
see stage five.)**

**The seam that makes the engine swappable.** The browser panel is built against a `BrowserEngine`
protocol (navigate, back/forward, reload, current URL, title, snapshot) with the CDP endpoint exposed
as a separate concern. The rest of Synth — the session model, sidebar row, keybindings, the pane
chrome mocked in `working.html` — talks to the protocol, never the engine. This keeps the engine
decision reversible and contains the blast radius if the CEF/WKWebView call is revisited.

## Claude drives it through a custom MCP server we own — not `--chrome`, not hooks

**Not the native `claude --chrome` path.** `claude --chrome` works through Chrome **Native Messaging**:
a closed, Anthropic-signed extension talks to a native-messaging host binary (installed under
`~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`) over length-prefixed JSON on
stdin/stdout, and that host brokers connections to real Chrome/Edge instances. The
`list_connected_browsers` / `select_browser` model is internal to that host. We cannot cleanly make
Synth's embedded browser register as one of those "connected browsers" without reimplementing the
native-messaging protocol against a closed extension — and it would bind us to Chrome's extension
lifecycle rather than our own.

**Not hooks.** Claude Code `PreToolUse` hooks can rewrite a tool call's arguments, but they cannot swap
which tool runs, register new tools, or take over browser selection. Intercepting `mcp__claude-in-chrome__*`
calls and redirecting them is too fragile to build on.

**The decision: a standalone MCP server, bundled in Synth, that presents the browser-tool surface and
drives our embedded Chromium over CDP.** MCP is Claude Code's official, first-party integration layer,
so this is the durable path. The server (Node/TypeScript with Playwright, or the equivalent driving CDP
directly) exposes the same tools the real integration does — `navigate`, `click`, `type`, `screenshot`,
`read_page`, read console, read network — and connects to the embedded browser's CDP endpoint via
`connectOverCDP(webSocketDebuggerUrl)`. The endpoint is per app instance, not per session
(`remote_debugging_port` is a global `CefSettings`; Synth bind-probes 9300–9399 once): the server
attaches to the instance endpoint and addresses each browser session as a page *target*, so the
list/spawn-per-branch tools map branch sessions to target IDs — per-session ports were never available. Synth registers it as a local (stdio) MCP server and
auto-registers on first run so a worktree's Claude sessions see it without setup — a `.mcp.json`
written into each worktree scopes the tools to that worktree's browsers. Open-source
reverse-engineered implementations of the browser-tool surface exist as references, but we present our
*own* tool server pointed at our *own* browser rather than depending on any of them. Stage two may
*start* by bundling Microsoft's Playwright MCP (`--cdp-endpoint` attaches it to an already-running
browser) and graduate to our own server when Synth-specific tools arrive (list/spawn per-branch
browsers, stage-three comment events); see `docs/research/browser-agent-integration.md`.

**Per-branch, per-worktree browsers fall out of this naturally.** Because Synth owns the server and the
browser lifecycle, "list the browsers in this branch" and "connect Claude to browser N" become our
tools over our session registry (scoped to the branch's worktree, per ADR-0004/ADR-0007), rather than
something we inherit from a host we don't control. Stage three's click-to-comment feedback is another
custom tool/event on the same server — the user's selection and comment become located context
delivered to the owning Claude Code session — so it composes onto stages one and two instead of needing
a new transport.

## Stage-one scope, and what it must get right for later

Stage one ships **only** the navigable browser session: create a browser (via the row kebab and ⌘K,
alongside New terminal / New Claude Code), open it to a "go to" home surface with recents, navigate
with an address bar + back/forward/reload, one page per session (more pages = more sessions, listed in
the sidebar like terminals), and a DevTools toggle in the browser bar that docks Chromium's own
DevTools under the page (CEF `ShowDevTools`; the same `remote_debugging_port` additionally lets an
external Chrome inspect the session via `chrome://inspect`). No agent control yet. The interaction and
chrome are already mocked and driven in `working.html` / `big-picture-design.html`.

Two things in stage one exist for the sake of stage two and must not be skipped: the browser sits
behind the `BrowserEngine` protocol, and — if we build directly on CEF — its CDP endpoint is turned on
from day one even though nothing consumes it yet. Get those right and stage two is *just the MCP server*;
get them wrong and stage two is a rewrite.

## What building it taught us (2026-07-05)

Stage one is integrated and working in-app (CEF 144, SwiftPM ObjC++ shim, `external_message_pump`,
async `SetAsChild` Alloy-style browsers — Chrome style is impossible for native-parent embedding on
macOS). The integration hardened into constraints that bind all future engine work:

- **Never rely on CEF's schedule callbacks alone to pump.** Chromium arms `OnScheduleMessagePumpWork`
  edge-triggered: any manual `CefDoMessageLoopWork` outside a scheduled callback consumes the only
  pending edge and permanently starves the pump (black view, CDP accepting TCP but never answering,
  no callbacks). The required shape is cefclient's: coalesced dispatch for `delay <= 0` *plus* a
  permanent ~30ms fallback timer driving `CefDoMessageLoopWork`.
- **Synth owns SIGTERM/SIGINT.** `CefInitialize` installs Chromium's own SIGTERM handler, which
  deadlocks under an external pump it doesn't drive. Synth takes the signals itself
  (`DispatchSourceSignal` → `NSApp.terminate`) so the normal quit path runs: state save → browser
  close → `CefShutdown` → helper reap → profile-dir removal. SIGKILL is covered without us:
  Chromium's parent-death cleanup collects helpers in ~2s, and the next launch sweeps the orphaned
  profile dir.
- **Browser close completes via the CEF wrapper view's dealloc** (`WindowDestroyed`), never CEF's own
  path: `DoClose` returning false makes CEF `performClose:` the browser's top-level NSWindow — the
  app's own window. Teardown must drop the view inside a local autorelease pool.
- **CDP is one port per app instance (9300–9399 bind-probed), not per session.**
  `remote_debugging_port` is a global `CefSettings`; each browser session is a page target on the
  shared endpoint. See the stage-two section for what this means for the MCP server's tools.
- **Every browser session gets its own profile dir, deleted when it closes.** *(Amended 2026-08-18:
  the isolation was right, the deletion was not — it made every browser incognito without the user
  choosing it. The profile is now per workspace and survives. See stage five.)*
- **The app must run from a bundle for CEF** — the framework and four helper apps resolve relative to
  `Contents/`. `dev.sh` assembles a symlinked dev bundle; a bare-binary run gets the loud WKWebView
  fallback (no CDP). The release bundle is ~309 MB, `--deep` ad-hoc signed.
- **The sandbox is currently disabled** (`no_sandbox`; `cef_sandbox` needs cmake integration not wired
  through SwiftPM). Acceptable for stage one; must be revisited before notarization/distribution.

## Stages two and three, and what building them taught us (2026-07-05)

Both stages are now built and gate-verified. Stage two is the bundled MCP server; stage three is
click-to-comment. Decisions that turned out to be load-bearing:

- **Stage two is a Synth-owned Node stdio MCP server, not bundled Playwright-MCP.** It uses
  `@modelcontextprotocol/sdk` + `playwright-core` `connectOverCDP` and adds Synth-specific tools
  (`browser_list`/`create`/`close`/`focus` over the app's control socket) that off-the-shelf servers
  can't express. Instance discovery: the app writes `~/Library/Application Support/Synth/instances/<pid>.json`
  ({pid, cdpPort, controlSocket, worktreePaths}); the server scopes to the instance whose worktreePaths
  contain `$CLAUDE_PROJECT_DIR`, resolving a nested `.worktree/<slice>` checkout to its deepest managed
  ancestor. Registration is a per-worktree `.mcp.json` the app writes (merge-preserving, never
  clobbering foreign servers), naming a stable install at `~/Library/Application Support/Synth/browser-mcp/`.
- **Registration moved off disk (amended 2026-08-17).** Nothing is written into the worktree any
  more: `MCPInstaller.launchEnv` hands the enabled servers to the launch and `synth-hook` turns them
  into each agent's own registration (`claude --mcp-config`, opencode's `OPENCODE_CONFIG_CONTENT`,
  `.agents/mcp_config.json` in the dir agy is `--add-dir`'d). A file in the user's repo that no user
  repo ignores was untracked noise in every worktree, and one had already been committed by mistake.
  Scoping is unchanged — the server still resolves its instance by worktree — except that
  `SYNTH_WORKTREE` now names it for all three agents rather than only where `$CLAUDE_PROJECT_DIR`
  was absent.
- **Session↔target mapping is a shim-stamped `window.__synthSessionId`** (CEF `ExecuteJavaScript` on
  every main-frame load end), evaluated by the server to map page targets back to Synth sessions.
- **Tool output must be capped.** A 30k-element page snapshots to ~1.5M chars (~400K tokens) — enough
  to blow a Claude session's context in one call. Cap at ~40k with a truncation marker.
- **Stage-three delivery is the PTY, not an MCP push.** There is no way to inject a message into a
  running Claude *conversation* from outside; the reliable channel is writing into the owning session's
  terminal (libghostty bracketed-paste + a trailing CR) — so a comment lands as a user turn the running
  `claude` acts on. Located context = clipped element screenshot + full-viewport screenshot + a composed
  text block (host+path, selector, position, React `file:line` when the page is a dev build, comment).
- **The delivery unit is a batch, not a comment (amended 2026-07-29).** A pass over a page is one piece
  of feedback, not six, and one PTY paste per remark meant the agent was interrupted — and started
  working — before the second thought had been typed. Comments now accumulate on the page and leave
  together: the overlay queues them and emits a single `commentBatch`, the host captures one viewport
  screenshot plus one clip per comment, composes one numbered text block, and runs the ownership ladder
  **once**. The security boundary above is unchanged and is the reason the ladder must stay single-shot:
  one batch is one delivery to one hook-confirmed-live session, so a page can no more reach a fallback
  shell with ten comments than it could with one. An unwritten composer is not a comment — blanks never
  count, never list, and are filtered before send.
- **Send is a request, not a result (amended 2026-07-29).** The page holds its batch until the host
  answers — `confirm(label)` empties it, `reject(why)` hands it straight back — because the last rung
  can fail: the target session may never report live, and delivery is refused rather than pasted into
  whatever shell is there. Clearing the queue optimistically meant a batch that never reached an agent
  was lost from the page too, which is precisely what the parked island exists to prevent. So an
  undelivered batch keeps its pins, its text and its count, and only its now-orphaned screenshots are
  discarded. A comment nobody received is still a comment somebody wrote.
- **The overlay runs in the MAIN world, injected via `Page.addScriptToEvaluateOnNewDocument`**, with the
  page→host channel a `Runtime.addBinding("__synthComment")`. Main world (not isolated) is required
  because React's `_debugSource` lives on DOM-node expando props an isolated world can't see. The picker
  UI is a closed shadow root behind a full-viewport event-suppressing veil, so a hostile page's own
  handlers never fire during a pick and page CSS can't reach the card.
- **A comment may only be delivered to a *confirmed-live* Claude session — this is a security boundary,
  not a nicety.** The composed message embeds page-controlled strings (title, selector, element HTML).
  If delivery targeted a session by persisted `.claudeCode` kind and pane-view existence, a restored row
  whose `claude --resume` fails drops to a bare `zsh` and the comment gets pasted-and-entered *as shell
  commands* — arbitrary code from a web page in the user's login shell. Liveness is therefore asserted
  only by the hook seam (ADR-0008): a session is a valid target only once it has fired `claude-start` /
  `claudeSessionCaptured` this run and not since ended. `submit()` is unreachable for a non-live row;
  a dormant-but-live-capable row is booted and delivery waits for the liveness signal, never for the
  terminal view; on timeout the comment is dropped and its screenshots deleted.

### The host half of the two rules above landed 2026-08-12, not 2026-07-29

Both amendments above described a page that keeps its batch and a host that answers. The overlay
implemented its side; the host never did, and using comment mode on a real app found both halves of
the gap at once:

- **Leaving the mode deleted the batch** rather than parking it, so the toolbar's comment button —
  which reads as a view toggle — was the only unlabelled Delete in the app. `exit()` now returns
  `'parked'` or `'off'` and the host believes the answer: parked keeps the CDP client, the binding,
  the injected script and the count, because the parked island's own Send still has to reach us. The
  batch outlives the document too (sessionStorage + a `restore` injection verb), since the likeliest
  thing to replace the page is the agent acting on the comments.
- **Nothing ever called `confirm`/`reject`.** Delivery reported a notice and no more, so a batch that
  *did* land kept its pins and its count forever, and one that never landed said so only in a notice
  that auto-cleared. `CommentDelivery` now reports its terminal answer and the browser turns it into
  the overlay's own two verbs.

One thing the ADR had not accounted for at all: the veil is not automatically the top of the page it
covers. The top z-index loses to the *top layer*, and a modal `<dialog>` beats even that — it inerts
everything outside itself and `elementsFromPoint` stops reporting the page (measured). The overlay is
a manual popover that re-promotes itself, and over a modal dialog it mounts *inside* it, the only
place that is both interactive and able to hit-test. Equally: the overlay's own events must stop at
its host, or the page's outside-click and focus-trap handlers treat every click on the composer as a
click outside and take the caret back.

## Stage four: a browser can belong to a Claude session (decided 2026-07-06)

Stage three routes a comment to "the branch's most-active live claude" — a guess that is usually
right but never stated. Stage four replaces the guess with structure: a browser session can be
**owned** by a Claude Code session, and ownership is *true containment* — sidebar nesting, cascade
lifecycle, and deterministic comment routing — not merely a stored routing hint.

- **Shared-visible, exclusive owner.** Containment does not shrink the shared surface: `browser_list`
  still returns every browser in the worktree (owned rows annotated), any claude may drive any
  browser, and the user can always take the wheel. *Rejected:* private-to-owner scoping (breaks the
  stage-two contract and blinds a second claude asked to "check the page") and read-only-for-others (a
  permission matrix for a conflict that barely exists).
- **Ownership is set at creation, changed only by the user.** `browser_create` stamps the calling
  claude as owner: the launch shim already mints the claude session id, so it exports it into claude's
  environment, the MCP server (claude's child) inherits it and passes it with the control-socket verb.
  ⌘K browsers are born unowned siblings. *Rejected:* driving-adopts (a background navigate visibly
  re-nesting a sidebar row is structure mutating as a side effect of automation). The row kebab gains
  "Move under <claude>…" / "Detach". An external claude (no Synth row) creates unowned browsers.
- **Cascade on delete, keyed to the row.** Deleting an owning claude row closes its browsers after a
  confirm that names them; Detach is the escape hatch. Ownership keys off the Synth row UUID — it
  survives claude exits and `--resume`. *Rejected:* orphan-to-sibling (a child that outlives its
  parent's deletion is a pointer, not containment).
- **Ownership is also the close permission (`browser_close`, added 2026-07-09).** An agent may close
  the browsers it owns and no others — so the user's ⌘K browsers, and any browser they detached or
  re-parented, are beyond reach, and an external claude owns nothing to close. Read stays shared;
  lifecycle is owned. *Rejected:* any-claude-closes-any-browser (driving a browser is not destroying
  it). A close is additionally refused while comment mode is engaged, which would delete the comment
  the user is composing.
- **Sidebar: one containment indent, same session dials.** Owned browsers render directly under their
  owner, one indent step deeper, reusing the session-tier visual language — always expanded, no caret,
  no new visual register. This amends the three-tier hierarchy decision to "three tiers + a
  containment indent"; per the design workflow it lands in `working.html` + `big-picture-design.html`
  before the native port.
- **Comment ladder: owner → boot owner → spawn-and-adopt.** A comment from an owned browser goes to
  its owner (booting it through the existing hook-liveness wait if dormant). A comment from an
  *unowned* browser always spawns a fresh claude session — silently, with the bar chip reading "→ New
  Claude session" pre-send — which receives the composed located context as its first message **and
  adopts the browser** (creation-time stamping, so the next comment hits the first rung; without
  adoption every comment would fork another session). Focus stays in the browser. *Replaced:* the
  most-active-in-branch fallback, for unowned browsers, and with it the "no claude → drop" dead end.
  The stage-three security boundary is untouched: delivery still submits only to a hook-confirmed-live
  session, including the freshly spawned one.
- **Consequences accepted knowingly:** commenting from a fresh ⌘K browser spawns a new claude even
  when an active one sits on the branch (re-parent first to route there instead), and an adopted ⌘K
  browser cascade-deletes with its spawned claude despite predating it (the confirm is the guard).

## Stage five: the browser lasts, and its non-goals get named (decided 2026-08-18)

Stages one to four asked what the browser *is*. Stage five came from asking what it is *missing*,
by auditing Synth's surface against Claude Code's Chrome integration, Cursor, Antigravity, Codex,
Copilot/VS Code, Windsurf, Replit, Devin, Cline, Playwright MCP, Chrome DevTools MCP and a
mainstream browser — 133 capabilities, read from our own source on one side and from shipped
binaries and vendor docs on the other.

The useful finding was that the gaps were not spread evenly. They clustered in two places — **what
survives a session** and **what the agent can do to a page** — with a long tail of browser-shaped
features that only look like gaps if you believe Synth is building a browser. So this stage decides
both halves: what gets built, and what gets written down as never.

### The profile persists, and it is keyed to the workspace

Stage one's per-session profile directory, deleted on close, is reversed. Isolation from the user's
real Chrome was correct and stays; throwing the profile away was not. It made every browser session
incognito without the user ever choosing incognito: no login survived, so an agent could not check
the same authenticated page twice in a row, and `browser_cookies` was the only door into an
authenticated state — a tool built to work around a problem we were creating. Synth was, across the
whole audit, the only product that actively deleted its own profile; every other isolated-profile
product treats persistence as the feature.

The profile is per **workspace** — the repo — not per branch and not global. Branches of one repo
are the same application, so per-branch profiles buy an isolation nobody asked for and charge for it
with a fresh login on every branch cut, which is the exact pain the deletion caused. A single global
profile abandons isolation between unrelated projects. Clearing is a user action ("Clear browsing
data"), never a lifecycle side effect: the reason the old behaviour was wrong is that the lifecycle
decided, and the user was not asked.

*Rejected:* per-branch (re-auth on every branch cut), global (no isolation at all), and staying
ephemeral while investing in `storageState` seeding instead (tooling built to route around a
constraint we impose on ourselves).

**Sequencing accepted knowingly:** persistence lands *before* the permission boundary below, so
there is a window in which an unconstrained agent drives inside real authenticated sessions. Synth
is a single-user tool on the user's own machine with the user's own logins, and the alternative —
shipping half a permission model early — buys less than doing it properly after. This is the
choice, not an oversight.

### Elements get refs, and CSS selectors stay

`browser_snapshot` returns an aria tree and `browser_click` takes a CSS selector, with nothing
joining them: the agent reads a page in one vocabulary and acts on it in another, guessing selectors
from source. Against generated class names that guess is where most click timeouts come from, and
every comparable product addresses elements by reference instead.

Snapshots will stamp refs, and the actuation tools will accept **either** a ref or a selector. Both,
not one: a ref is unambiguous for something the agent has just read, but Synth's agents write the
page they are testing, and forbidding `#save` when the agent authored `#save` would make a mandatory
snapshot the price of every action. A stale ref must fail with a message that says so and says to
re-snapshot — a ref that silently resolves to the wrong node after a re-render is worse than one
that errors.

*Rejected:* refs only (mandatory snapshot before every action, tokens spent re-reading a page the
agent wrote), and selectors only (cheapest, and leaves the gap that causes the failures).

### The agent gets the five verbs it is missing, and a network tool

Actuation today is click and type. Hover, key press, select-option, scroll and wait-for-condition
are each one driver call behind a tool definition, and together they are the difference between
driving a simple page and driving an application: a hover menu, a native `<select>`, a lazy list and
an element that appears a beat later are all currently unreachable, and each one fails as a click
timeout rather than as "I cannot do this".

`browser_network` follows the shape Chrome DevTools MCP settled on: **metadata inline, bodies to
disk**. The list returns method, URL, status, type and timing; a second call writes one request's
headers and body to a file and returns the path. Inline bodies were rejected because a single JSON
response can cost tens of thousands of tokens and because authorization headers would land in the
model's context by default; metadata-only was rejected because "the API returned the wrong shape" is
exactly the bug the tool exists for. The CDP session is already attached — this is a tool
definition, not new plumbing.

### Screenshots go to disk by default

`browser_screenshot` will return a **path**, with `inline: true` for when the agent actually needs
to look. The category's own evidence is that opt-in disk paths do not get opted into — Claude Code
ships `save_to_disk` and agents mostly do not reach for it — while inlined captures are the single
largest context cost in agent browsing, with reports of one screenshot at 232k tokens and a hard
model failure above 8000px per dimension. Defaulting the cheap path and making the expensive one
explicit puts the choice where the cost is. `browser_record_stop` already returns a path; this makes
capture consistent with itself. Full-page and element-scoped capture come with it.

### Free viewport for the agent, the device fleet for the user

The six-device fleet is the pane's device chrome and stays exactly as it is — it is real
`Emulation.setDeviceMetricsOverride`, which Cursor and Claude Code both lack, and it is a fleet of
*hardware*, which is the right register for a human choosing a phone. It is also, today, the only
viewport control that exists, so a 1440px desktop or a 900px tablet breakpoint cannot be checked at
all. The agent gets a free width × height; the pane's chip row does not grow a numeric field.

### The CEF handler set gets wired — except one, deliberately

`ShimClient` implements three of CEF's client handlers, and an unwired handler is not a missing
feature but a silently broken web platform. Wiring, in order of what blocks work:

- **Certificate errors and HTTP basic auth.** A self-signed certificate has no proceed path and
  basic auth has no prompt, so a local HTTPS dev server and any basic-auth staging environment are
  simply unreachable from the pane whose stated job is checking your work. This is the bundle that
  makes stage one's promise true.
- **JS dialogs and page permissions.** `alert`/`confirm`/`prompt` are undefined and can block the
  page; camera, microphone, geolocation, notifications and clipboard are denied with no prompt and
  no way to grant. An app that uses any of them looks broken in Synth and fine in Chrome, which is
  the worst possible failure — it reads as our bug in *their* code.
- **Context menu and find-in-page.** Right-click and ⌘F. Ergonomics on a surface people stare at.

**Downloads are deliberately left blocked.** A downloads *manager* is a non-goal (below), and wiring
`CefDownloadHandler` only to drop a file in `~/Downloads` was judged not to earn its place yet. The
consequence is named rather than hidden: an export link produces nothing, with no feedback to the
page and none to the user, and it will be reported as a bug because it looks like one. Revisit when
someone hits it.

### Popups become transient windows, not sessions

`didRequestPopup` currently routes `window.open` into a **new browser session** — a permanent
sidebar row that outlives the flow that opened it. That is consistent with one-page-per-session and
wrong in practice: the overwhelming use of a popup is OAuth, so signing into your own staging app
leaves litter behind every time, and a popup that closes itself leaves a dead row. Popups get a real
transient child window instead. This is also what makes third-party identity sign-in work at all —
the absence of it is why Google Identity fails outright in Cursor's pane.

*Rejected:* keeping the session and auto-closing it when the popup closes — it preserves the model,
but a sidebar row that vanishes on its own is the only thing in Synth's sidebar not driven by the
user.

### What Synth's browser will never be

The pane's job is **the agent's eyes, and a surface for checking your work**. It is not a browser
you live in, and the following are non-goals, not backlog: bookmarks, a downloads manager, a
built-in PDF viewer, reader mode, translation, a user-installable extension platform, and a
mainstream tab strip with groups, pinning and tear-off. Each was measured against the audit and each
is real in Chrome; none of them serves checking a page you just built, and all of them cost the
"simple at a glance" the product is for.

Two further absences are architectural rather than chosen, and are recorded so nobody re-litigates
them: **Lighthouse cannot run here** — it lives in Chrome's DevTools front-end bundle, not CEF's —
and **none of Chrome's browser-layer safety services exist in CEF**, so Safe Browsing, HTTPS
interstitials, mixed-content blocking and tracker blocking are not features Synth declined to build.

### Two things are removed, and one survived being removed

- **`browser_focus` goes; `sessionId` becomes required.** One focus pointer is shared by an agent and
  every sub-agent it spawns, which the tool's own description already warns about — it exists to save
  a parameter and costs correctness the moment two agents work at once.
- **The WKWebView fallback engine goes.** It produces a pane that looks like a working browser and
  has no CDP, so every agent tool fails against something the user can see rendering fine. Refusing
  to make a browser, loudly, is the better failure. Cost, named: a bare-binary run (no assembled
  bundle) gets no browser at all rather than a degraded one.
- **Video recording was proposed for removal and kept.** The argument against it was that the agent
  cannot watch its own output and the ffmpeg dependency is real; the argument that won is that it is
  a genuine capability lead — Cursor's local browser has the plumbing and no recorder — and the hard
  part, frames surviving cross-page navigation, is already solved and working.

### The sandbox item is now scheduled

`no_sandbox` has sat in Consequences as an open item since stage one. It is the only entry in the
whole audit that is a regression against every competitor rather than an absent feature, and it
blocks notarization regardless. Wiring `cef_sandbox` through the SwiftPM build is scheduled ahead of
the agent permission boundary; the boundary — an origin allowlist plus a read-only versus
state-changing split on the tools — follows persistence.

## Consequences

- The browser is its own subsystem with a Chromium/CEF engine, a bundle-size and notarization cost, and
  a multi-process tree to supervise and sign. This is the largest native dependency Synth takes on after
  the Ghostty terminal renderer (ADR-0009).
- A bundled, auto-registered MCP server becomes part of Synth's runtime. It is the integration point for
  all agent↔browser interaction across stages two and three.
- The "same surface" guarantee (user browser == agent browser == comment target) is the load-bearing
  requirement; any future shortcut that splits them (a headless agent browser, a detached window) breaks
  stage three and is out of bounds.
- Distribution is Developer ID + notarization, not the Mac App Store.
- Stage one ships with the Chromium sandbox disabled (`no_sandbox`). Wiring `cef_sandbox` through the
  SwiftPM build is an open item that blocks notarization/distribution. *(2026-08-18: scheduled — it is
  the one place the browser is behind every competitor on security rather than on features.)*
- The browser holds durable user state (stage five): a per-workspace profile with real logins in it,
  under Application Support, cleared only when the user asks. It is a thing to back up, to migrate,
  and to reason about when a workspace is deleted.
- Synth's browser has written-down non-goals (stage five). The pane is the agent's eyes and a surface
  for checking work; bookmarks, a downloads manager, a PDF viewer, reader mode, extensions and a
  mainstream tab strip are refusals, not backlog, and a request for one is answered with this ADR.
- The agent may act on any origin the user's profile is authenticated to, and will be able to before
  the permission boundary exists. Accepted deliberately for a single-user local tool; it is the first
  thing to revisit if Synth is ever driven by someone other than its owner.
- Comment delivery is gated on hook-confirmed Claude liveness — the shell-injection boundary above — so
  it depends on ADR-0008's hook seam being live; a session Synth can't confirm is never written to.
- Open follow-ups surfaced by the gates, orthogonal to the feature: a second co-resident CEF instance
  can die shortly after a Claude terminal pane takes focus (an IMKit/Ghostty focus-path issue, not the
  browser); and multiple instances share one `state.json` last-writer-wins (ADR-0010's known limit).

## References

- Supporting research (claims verified 2026-07-05, stage-3 prior art, CEF practicalities) —
  `docs/research/browser-agent-integration.md`
- Stage-five capability audit (133 capabilities, Synth vs. 12 agent browsers and the mainstream
  baseline, 2026-08-18) — `docs/research/browser-capability-landscape.md`
- Claude Code Chrome integration — https://code.claude.com/docs/en/chrome.md
- Claude Code MCP (transport, scopes, local/stdio servers) — https://code.claude.com/docs/en/mcp.md
- Model Context Protocol — https://modelcontextprotocol.io/
- CDP over `--remote-debugging-port`, `connectOverCDP` — https://www.browserstack.com/guide/playwright-connect-to-existing-browser
- WKWebView has no CDP (`isInspectable` is Web Inspector only) — https://developer.apple.com/documentation/webkit/wkwebview/isinspectable ; https://webkit.org/blog/13936/enabling-the-inspection-of-web-content-in-apps/
- CEF general usage / CDP via `remote_debugging_port` — https://chromiumembedded.github.io/cef/general_usage.html
- Cross-process embedding is not viable; talk to a browser over CDP instead — https://github.com/zed-industries/zed/issues/5310
- Cursor's browser tool (embedded webview driven over CDP) — https://cursor.com/docs/agent/tools/browser
