# The browser is a Synth session, and Claude drives it through our own MCP server over CDP

Synth already treats a browser as a first-class session type (CONTEXT.md, and the `data-type="browser"`
row in the designs). This ADR commits to what that session *is* and, more consequentially, to the
architecture that lets Claude Code drive it later — because the engine we pick for the visible browser
in stage one is constrained by the way we want Claude to control it in stage two.

The feature has three stages, and only **stage one** is being built now:

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
accepting a later engine swap; it is a schedule hedge, not the target.

**The seam that makes the engine swappable.** The browser panel is built against a `BrowserEngine`
protocol (navigate, back/forward, reload, current URL, title, snapshot) with the CDP endpoint exposed
as a separate concern. The rest of Synth — the session model, sidebar row, keybindings, the pane
chrome mocked in `design.html` — talks to the protocol, never the engine. This keeps the engine
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
chrome are already mocked and driven in `design.html`.

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
  (`browser_list`/`create`/`focus` over the app's control socket) that off-the-shelf servers can't
  express. Instance discovery: the app writes `~/Library/Application Support/Synth/instances/<pid>.json`
  ({pid, cdpPort, controlSocket, worktreePaths}); the server scopes to the instance whose worktreePaths
  contain `$CLAUDE_PROJECT_DIR`, resolving a nested `.worktree/<slice>` checkout to its deepest managed
  ancestor. Registration is a per-worktree `.mcp.json` the app writes (merge-preserving, never
  clobbering foreign servers), naming a stable install at `~/Library/Application Support/Synth/browser-mcp/`.
- **Session↔target mapping is a shim-stamped `window.__synthSessionId`** (CEF `ExecuteJavaScript` on
  every main-frame load end), evaluated by the server to map page targets back to Synth sessions.
- **Tool output must be capped.** A 30k-element page snapshots to ~1.5M chars (~400K tokens) — enough
  to blow a Claude session's context in one call. Cap at ~40k with a truncation marker.
- **Stage-three delivery is the PTY, not an MCP push.** There is no way to inject a message into a
  running Claude *conversation* from outside; the reliable channel is writing into the owning session's
  terminal (libghostty bracketed-paste + a trailing CR) — so a comment lands as a user turn the running
  `claude` acts on. Located context = clipped element screenshot + full-viewport screenshot + a composed
  text block (host+path, selector, position, React `file:line` when the page is a dev build, comment).
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
- **Sidebar: one containment indent, same session dials.** Owned browsers render directly under their
  owner, one indent step deeper, reusing the session-tier visual language — always expanded, no caret,
  no new visual register. This amends the three-tier hierarchy decision to "three tiers + a
  containment indent"; per the design workflow it lands in `design.html`
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
  SwiftPM build is an open item that blocks notarization/distribution.
- Comment delivery is gated on hook-confirmed Claude liveness — the shell-injection boundary above — so
  it depends on ADR-0008's hook seam being live; a session Synth can't confirm is never written to.
- Open follow-ups surfaced by the gates, orthogonal to the feature: a second co-resident CEF instance
  can die shortly after a Claude terminal pane takes focus (an IMKit/Ghostty focus-path issue, not the
  browser); and multiple instances share one `state.json` last-writer-wins (ADR-0010's known limit).

## References

- Supporting research (claims verified 2026-07-05, stage-3 prior art, CEF practicalities) —
  `docs/research/browser-agent-integration.md`
- Claude Code Chrome integration — https://code.claude.com/docs/en/chrome.md
- Claude Code MCP (transport, scopes, local/stdio servers) — https://code.claude.com/docs/en/mcp.md
- Model Context Protocol — https://modelcontextprotocol.io/
- CDP over `--remote-debugging-port`, `connectOverCDP` — https://www.browserstack.com/guide/playwright-connect-to-existing-browser
- WKWebView has no CDP (`isInspectable` is Web Inspector only) — https://developer.apple.com/documentation/webkit/wkwebview/isinspectable ; https://webkit.org/blog/13936/enabling-the-inspection-of-web-content-in-apps/
- CEF general usage / CDP via `remote_debugging_port` — https://chromiumembedded.github.io/cef/general_usage.html
- Cross-process embedding is not viable; talk to a browser over CDP instead — https://github.com/zed-industries/zed/issues/5310
- Cursor's browser tool (embedded webview driven over CDP) — https://cursor.com/docs/agent/tools/browser
