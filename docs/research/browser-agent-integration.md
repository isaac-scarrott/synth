# Research: routing Claude Code's browser control into Synth's embedded browser

Supporting research for ADR-0011 (embedded browser session, driven by a custom MCP server over CDP).
ADR-0011 holds the decisions; this file holds the evidence — what `claude --chrome` actually is, why
it can't be intercepted, what we'd bundle for stage two, how others built stage-three-style
click-to-comment loops, and what CEF costs in practice. Researched 2026-07-05 against current docs.

## 1. What `claude --chrome` actually is

- Works through **Chrome Native Messaging**, not a reroutable MCP endpoint: a closed, store-published
  Anthropic extension talks to a native-messaging host binary (manifest
  `com.anthropic.claude_code_browser_extension.json` under
  `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`) over length-prefixed JSON-RPC on
  stdin/stdout. https://code.claude.com/docs/en/chrome.md
- Officially supports **Google Chrome and Microsoft Edge only** — "isn't yet supported on Brave, Arc,
  or other Chromium-based browsers". No documented flag, env var, or config to point it at a custom
  Chrome binary, custom extension ID, or arbitrary CDP endpoint.
- The extension is **not open-source**; no official repo. Community reverse-engineering proves the
  protocol is replicable — [noemica-io/open-claude-in-chrome](https://github.com/noemica-io/open-claude-in-chrome)
  reimplements the extension (all 18 tools, any Chromium browser) and
  [stolot0mt0m/claude-chromium-native-messaging](https://github.com/stolot0mt0m/claude-chromium-native-messaging)
  extends the host registration to Brave/Arc/Vivaldi. So a CEF app that ran a Chrome-style window with
  extension support could *theoretically* join that dance — but it would mean shipping a
  reverse-engineered protocol against a closed extension whose lifecycle Anthropic controls.
  ADR-0011's rejection stands.

## 2. Why interception doesn't work

- **PreToolUse hooks** can rewrite a tool call's arguments (`updatedInput`), allow/deny it, or add
  context — they **cannot swap which tool runs, register new tools, or synthesize a response**.
  PostToolUse can rewrite output, but fires after execution. No newer tool-aliasing/proxy mechanism
  exists as of July 2026. https://code.claude.com/docs/en/hooks.md
- Conclusion unchanged: you can't hook `mcp__claude-in-chrome__*` calls into a different browser.
  The supported extension seam is a server we own.

## 3. Stage two: the MCP server we point at the embedded browser

- **Registration:** per-worktree `.mcp.json` (project scope) is the right vehicle — Synth writes it
  into each worktree it creates, so any Claude session spawned there sees the browser tools scoped to
  that worktree's browsers. One-time approval prompt per worktree is by design. `CLAUDE_PROJECT_DIR`
  is available to the server's env for scoping. Local/user scopes leak across projects; a
  launch-time `--mcp-config` flag is not a documented, reliable mechanism.
  https://code.claude.com/docs/en/mcp.md
- **Bundle vs build:** [Playwright MCP](https://github.com/microsoft/playwright-mcp) is the strongest
  off-the-shelf candidate — it explicitly attaches to an existing browser via
  `--cdp-endpoint=http://localhost:<port>` (exactly our CEF `remote_debugging_port`), drives via
  accessibility-tree snapshots, and is actively maintained by Microsoft. Google's
  [chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp) is Chrome-lifecycle-
  oriented (wants to own the browser it drives); browser-use and BrowserMCP have no clear
  attach-to-existing-CDP story.
- **Recommendation:** start stage two by bundling Playwright MCP pointed at the embedded browser's CDP
  endpoint — near-zero harness, full navigate/click/type/screenshot/console/network surface. Our own
  server only becomes necessary when we add Synth-specific tools (list/spawn browsers per branch,
  stage-three comment events); it can wrap or replace Playwright MCP then.

## 4. Stage three prior art: click-to-comment loops

Every existing tool's complexity is a workaround for *not owning the browser*:

- **stagewise** (gen 1): npm toolbar packages / CLI proxy injecting into your dev app, talking to an
  editor extension over a localhost WebSocket (SRPC), with an MCP path for other agents. Captured
  selector/XPath, React/Vue component tree, computed styles, source-map coordinates. **Gen 2 abandoned
  injection and became its own Electron browser using CDP** for screenshots/console/DOM, with selected
  elements @-mentioned into a chat sidebar — i.e. they converged on exactly the Synth architecture.
  https://github.com/stagewise-io/stagewise
- **Onlook**: is the browser (Electron→web); build-time plugin stamps an "oid" attribute per element
  mapping DOM → JSX AST location, edits patch the AST. Precise but requires owning the user's build
  toolchain. https://docs.onlook.com/developers/architecture
- **Vercel toolbar / v0 Design Mode**: toolbar injected server-side into previews; comments anchor to
  page locations with auto-screenshots. v0's Design Mode (hover-select element → describe change →
  agent edits code) is the closest UX match to our stage three. https://v0.app/docs/design-mode
- **Cursor**: embedded webview "controlled using an MCP server running as an extension"; element
  selection + visual-edit sidebar exists but is reportedly rough. https://cursor.com/docs/agent/tools/browser
- **Windsurf**: "Send element" from its preview into Cascade as context. https://docs.windsurf.com/windsurf/previews
- **click-to-component / LocatorJS**: in dev builds of React apps, per-element `file:line:col` is
  already on the fiber (`@babel/plugin-transform-react-jsx-source` / React DevTools hook) — located
  context for free, no instrumentation. https://github.com/ericclemmons/click-to-component

**Because Synth owns the browser and the CDP socket, the whole stack collapses to four CDP calls:**

1. `Page.addScriptToEvaluateOnNewDocument` — inject the selection/comment overlay on every page and
   frame (replaces proxies, npm packages, server-side injection).
2. `Runtime.addBinding` + `Runtime.bindingCalled` — page→host channel for "user commented on element X"
   with zero networking (replaces WebSocket bridges/port discovery).
3. `DOM.getBoxModel` + `Page.captureScreenshot` (clipped) — framework-agnostic located context
   (selector, box, pixels); optionally enrich with React `__source` file:line when present.
4. `Page.createIsolatedWorld` — run the overlay UI where page CSS/JS can't break it (the failure mode
   all toolbar tools fight).

The comment event then flows through our MCP server to the owning Claude session as a tool
event/context — same transport as stage two, no new machinery.

## 5. CEF practicalities (macOS, 2026)

- **Runtime state:** the Alloy bootstrap was deleted in M128; everything is the Chrome bootstrap now,
  with per-window "Chrome style" vs "Alloy style" (lightweight/OSR).
  https://github.com/chromiumembedded/cef/issues/3685
- **DevTools:** full Chrome DevTools ships inside CEF. `CefBrowserHost::ShowDevTools` can parent into a
  provided view (dockable — `cefclient` does it) but embedded child rendering is the fiddly path;
  a popup DevTools window is the well-trodden one. `OnBeforeDevToolsPopup` is the current interception
  point. Separately, `CefSettings.remote_debugging_port` exposes the standard CDP endpoint — which is
  simultaneously our MCP server's attach point *and* lets an external Chrome inspect via
  `chrome://inspect`. Plan: ship the popup/docked native DevTools for the in-app button; the remote
  port covers agent + external tooling.
- **Chrome extensions in CEF:** Alloy extension API is gone; Chrome-style windows support
  `--load-extension` only when showing Chrome UI. The Claude-in-Chrome extension (MV3 + side panel +
  tab groups + OAuth) sits squarely in the unsupported bucket for an embedded Alloy-style view —
  reinforcing "don't chase the extension, own the server".
- **Swift integration:** no maintained Swift/SwiftUI CEF wrapper exists (CEF.swift is abandoned,
  Swift 4.2-era). Realistic path: small C++/ObjC++ shim exposing the CEF browser as an NSView, wrapped
  in `NSViewRepresentable`. Bundle ships four signed helper apps; Developer ID + notarization
  (consistent with ADR-0011). Spotify/OBS/Steam ship CEF on macOS from AppKit hosts; nobody known
  ships it from SwiftUI — we'd be first, via the shim.
- **Spike-verified (2026-07-05, branch `spike/embedded-browser`, `spike/LEARNINGS.md`):** CEF 144's
  `remote_debugging_port` does work — `/json/version` + page targets served, and Playwright
  `connectOverCDP` drove a CEF page end-to-end (stage two proven against the target engine). The
  endpoint initially appeared dead because **macOS Keychain (os_crypt) access at startup** crashes or
  hangs CEF when launched from a background/harness context; `--use-mock-keychain` resolves it. A
  normally-launched signed GUI app shouldn't hit this, but any automated/CI-spawned engine instance
  must pass the flag. Also mandatory: per-session cache dirs and hard process teardown — the CEF
  process singleton silently absorbs relaunches. (Chromium 136+'s remote-debugging-port hardening is
  compile-time disabled for non-Google-branded builds, so it does not affect CEF.
  https://developer.chrome.com/blog/remote-debugging-port)
- **Spike #2-verified (2026-07-05, same branch): CEF embedded in a Swift-hosted window works.** Real
  Google typing (28 chars/~260ms), back/forward/reload, an 18,000px scroll of a heavy Wikipedia page at
  **~100fps** pixel-perfect retina, native DevTools window tracking the page across navigations,
  unicode/emoji input fidelity, two-way URL-bar↔agent sync (14 events), ~3% average CPU — all while
  Playwright drove the same surface over CDP. Two embedder facts to build with: (1) macOS forces
  **Alloy runtime style** when the browser embeds in your own window (Chrome style needs CEF's Views
  framework owning it), so Chrome-UI surfaces — error pages, permission prompts, print/PDF dialogs —
  remain the un-audited edge; (2) there is **no default popup handling**: `window.open()` blocks the
  renderer forever until the embedder implements `OnBeforePopup`. Synth must implement it regardless —
  and it's an opportunity, not a chore: route popups into a new browser session, which is exactly what
  the one-page-per-session model wants instead of an OS window.
- **Fallback worth knowing:** external Chrome subprocess + `Page.startScreencast` frames rendered into
  a native view (browserless's "hybrid automation" pattern). Trivial harness and perfect agent/CDP
  unification, but JPEG-frame fidelity, no native scrolling/IME, and visible input latency — Neko
  rejected screencast for WebRTC for exactly this reason. Acceptable as a stopgap, not the target.
  The spike measured it better than expected locally: ~60fps into a SwiftUI window with click-through
  via `Input.dispatchMouseEvent`, in ~150 lines of dependency-free Swift CDP client.
  https://docs.browserless.io/baas/interactive-browser-sessions/hybrid-automation
