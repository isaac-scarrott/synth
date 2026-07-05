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
`connectOverCDP(webSocketDebuggerUrl)`. Synth registers it as a local (stdio) MCP server and
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
