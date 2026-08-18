// Synth's browser MCP server (ADR-0011 stage two, stdio).
//
// A coding agent drives the embedded CEF browser of the Synth instance that manages
// its worktree — named by $SYNTH_WORKTREE (opencode, which Synth sets explicitly in the
// server's `environment`) or $CLAUDE_PROJECT_DIR (Claude Code, which sets it itself),
// falling back to the cwd. Discovery: each running Synth writes
// ~/Library/Application Support/Synth/instances/<pid>.json (pid, cdpPort, createdAt,
// worktreePaths, controlSocket). Session list/create go through the app's control
// socket (the app owns the session model); everything else is CDP via Playwright's
// connectOverCDP. The CDP endpoint is per app instance; each Synth browser session
// is a page target, mapped back to its session by window.__synthSessionId (stamped
// by the app's CEF shim on every main-frame load end).
//
// One server process serves a whole Claude session INCLUDING its sub-agents (they
// share the parent's MCP connections, and calls carry no caller identity). Any
// process-wide "current session" pointer is therefore shared by agents that cannot
// see each other — which is why there isn't one (ADR-0011 stage five). Every tool
// that acts on a page names its sessionId.

import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { chromium } from "playwright-core";
import { z } from "zod";
import { controlCall, exitWithParent, makeTool, projectDir, requireInstance,
         requireScope, text } from "./shared.mjs";

// ---------------------------------------------------------------------------
// CDP connection — lazy, reconnect on drop or port change.

let cdp = null;        // { browser, port, at, attachMs, targetsAtAttach }
let connecting = null; // { port, promise } — racing callers share one dial

/** Close a superseded connection only after any in-flight op on it is done
 *  (longest tool timeout is 20s) — closing immediately is how one agent's
 *  reconnect kills another agent's screenshot mid-flight. */
function retire(browser) {
  setTimeout(() => browser.close().catch(() => {}), 30_000).unref?.();
}

/** The engine's page targets straight off the HTTP endpoint (`/json/list`) — one
 *  cheap request, no per-target attach, so it answers "how loaded is the whole
 *  browser" even when connectOverCDP can't finish. Null when the endpoint is
 *  unreachable. Counts targets from EVERY worktree and agent on this Synth. */
async function cdpTargets(inst, ms = 3000) {
  try {
    const res = await fetch(`http://127.0.0.1:${inst.cdpPort}/json/list`,
                            { signal: AbortSignal.timeout(ms) });
    const list = await res.json();
    return list.filter((t) => t.type === "page" && !String(t.url).startsWith("devtools://"));
  } catch { return null; }
}

/** connectOverCDP attaches to every target on the endpoint, so its cost grows with
 *  the whole engine's target count — not with anything this agent owns. A fixed
 *  budget therefore turns "the machine is busy" into "every tool is broken". */
function attachBudget(targetCount) {
  return Math.min(120_000, Math.max(20_000, targetCount * 1500));
}

async function connectedBrowser(inst) {
  if (!inst.cdpPort) {
    throw new Error(
      "Synth is running but its browser engine isn't up yet (no CDP port). " +
      "Create a browser session first (browser_create).");
  }
  if (cdp && cdp.port === inst.cdpPort && cdp.browser.isConnected()) return cdp.browser;
  if (connecting?.port === inst.cdpPort) return connecting.promise;
  if (cdp) { retire(cdp.browser); cdp = null; }
  const promise = (async () => {
    const targets = await cdpTargets(inst);
    const count = targets?.length ?? 0;
    const budget = attachBudget(count);
    const started = Date.now();
    let browser;
    try {
      browser = await chromium.connectOverCDP(
        `http://127.0.0.1:${inst.cdpPort}`, { timeout: budget });
    } catch (e) {
      if (!/Timeout .* exceeded/.test(e.message)) throw e;
      throw new Error(
        `couldn't attach to Synth's browser engine (port ${inst.cdpPort}) within ` +
        `${budget / 1000}s while it was hosting ${count} page targets across all ` +
        "worktrees and agents. Attaching enumerates every target, so this is " +
        "engine-wide load, not one wedged page of yours — browser_health lists the " +
        "targets and which respond. Closing browsers nobody needs is what makes " +
        "this faster.");
    }
    browser.on("disconnected", () => { if (cdp && cdp.browser === browser) cdp = null; });
    cdp = { browser, port: inst.cdpPort, at: Date.now(),
            attachMs: Date.now() - started, targetsAtAttach: count };
    // Instrument existing and future pages right away — console events buffered by the
    // browser replay asynchronously on attach, and a listener must already be there.
    for (const context of browser.contexts()) {
      context.on("page", instrument);
      for (const page of context.pages()) instrument(page);
    }
    return browser;
  })();
  connecting = { port: inst.cdpPort, promise };
  try { return await promise; }
  finally { if (connecting?.promise === promise) connecting = null; }
}

// ---------------------------------------------------------------------------
// Page ↔ session mapping, per-page console capture, per-page network log.

const pageLogs = new WeakMap();    // Page -> [{ level, text, at }]
const pageNet = new WeakMap();     // Page -> { seq, entries: [entry] }
const netEntry = new WeakMap();    // Request -> entry
const instrumented = new WeakSet();
const CONSOLE_CAP = 200;
const NETWORK_CAP = 300;
// Bodies are kept, but only the ones worth keeping. Fetching a body on demand is what the
// tool's shape asks for and what its cost argument is about — but the engine drops a finished
// response's body the moment the page moves on, and "the API returned the wrong shape" is
// usually asked about a request from before the last navigation. So the text-shaped responses
// are read off the wire as they finish and held, under a total cap; anything bigger, or of a
// type nobody diagnoses by reading (images, fonts, media), is left to the on-demand path and
// its honest failure. Nothing here ever reaches the model — the body still only leaves as a
// file path.
const BODY_TYPES = new Set(["xhr", "fetch", "document", "script", "stylesheet", "manifest"]);
const BODY_MAX = 512 * 1024;        // one response worth keeping
const BODY_TOTAL_MAX = 8 * 1024 * 1024;

function instrument(page) {
  if (instrumented.has(page)) return;
  instrumented.add(page);
  const logs = [];
  pageLogs.set(page, logs);
  const push = (level, text) => {
    logs.push({ level, text, at: new Date().toISOString() });
    if (logs.length > CONSOLE_CAP) logs.splice(0, logs.length - CONSOLE_CAP);
  };
  page.on("console", (msg) => push(msg.type(), msg.text()));
  page.on("pageerror", (err) => push("error", String(err?.message ?? err)));

  const net = { seq: 0, entries: [], held: 0 };
  pageNet.set(page, net);
  page.on("request", (req) => {
    const entry = {
      id: `r${++net.seq}`, method: req.method(), url: req.url(),
      type: req.resourceType(), startedAt: Date.now(), status: null, ms: null,
      bytes: null, failed: null, body: null, req,
    };
    netEntry.set(req, entry);
    net.entries.push(entry);
    if (net.entries.length > NETWORK_CAP) {
      for (const dropped of net.entries.splice(0, net.entries.length - NETWORK_CAP)) {
        if (dropped.body) net.held -= dropped.body.length;
      }
    }
  });
  page.on("response", (res) => {
    const entry = netEntry.get(res.request());
    if (entry) entry.status = res.status();
  });
  page.on("requestfinished", (req) => {
    const entry = netEntry.get(req);
    if (!entry) return;
    entry.ms = Date.now() - entry.startedAt;
    req.sizes().then((s) => { entry.bytes = s.responseBodySize; }).catch(() => {});
    if (!BODY_TYPES.has(entry.type)) return;
    req.response().then((res) => res?.body()).then((body) => {
      if (!body || body.length === 0 || body.length > BODY_MAX) return;
      entry.body = body;
      net.held += body.length;
      // Oldest first: a body from ten navigations ago is the one nobody is about to ask for.
      for (const older of net.entries) {
        if (net.held <= BODY_TOTAL_MAX) break;
        if (older.body) { net.held -= older.body.length; older.body = null; }
      }
    }).catch(() => { /* already gone, or not readable — the dump says so */ });
  });
  page.on("requestfailed", (req) => {
    const entry = netEntry.get(req);
    if (!entry) return;
    entry.ms = Date.now() - entry.startedAt;
    entry.failed = req.failure()?.errorText ?? "failed";
  });
}

async function evalWithTimeout(page, expression, ms) {
  return Promise.race([
    page.evaluate(expression),
    new Promise((_, rej) => setTimeout(() => rej(new Error("evaluate timed out")), ms)),
  ]);
}

/** Page -> sessionId, for pages that answered the probe. A session's stamp never
 *  changes (the CEF shim re-stamps the same id on every main-frame load), so one
 *  answer per page holds for the page's life — and every tool call after the first
 *  skips the probe entirely. Only truthy answers are cached: a page that hasn't
 *  loaded yet reports null, and that must not stick. */
const pageSession = new WeakMap();

/** All Synth session pages on the endpoint: [{ page, sessionId }]. Unmapped pages
 *  are probed CONCURRENTLY — serially, a browser holding N stalled targets costs
 *  N × the probe timeout on every single tool call, which is how these tools get
 *  slower the longer a session runs. */
async function sessionPages(inst) {
  const browser = await connectedBrowser(inst);
  const pages = [];
  for (const context of browser.contexts()) {
    for (const page of context.pages()) {
      const url = page.url();
      if (url.startsWith("devtools://") || url.startsWith("chrome://")) continue;
      instrument(page);
      pages.push(page);
    }
  }
  await Promise.all(pages.filter((p) => !pageSession.has(p)).map(async (page) => {
    try {
      const id = await evalWithTimeout(page, "window.__synthSessionId || null", 2000);
      if (id) pageSession.set(page, id);
    } catch { /* mid-navigation or crashed — probe again on a later call */ }
  }));
  return pages.map((page) => ({ page, sessionId: pageSession.get(page) ?? null }));
}

/** sessionPages, retried once on a fresh connection when `want` finds no match —
 *  CEF's CDP endpoint emits no attach events for targets created after a client
 *  connected, so a page opened since then is invisible until we reconnect. The
 *  endpoint's own target list says whether anything IS hidden: when it isn't, the
 *  miss is real and a reconnect would only pay the attach cost to learn nothing. */
async function sessionPagesSeeking(inst, want) {
  const pages = await sessionPages(inst);
  if (pages.some(want)) return pages;
  const targets = await cdpTargets(inst);
  if (targets && targets.length <= pages.length) return pages;
  if (cdp) { retire(cdp.browser); cdp = null; }
  return sessionPages(inst);
}

/** This worktree's browser sessions, from the app — the authority on which sessions
 *  exist, which branch they belong to, and who owns them. Every target lookup goes
 *  through it, so one worktree's agent cannot drive (or close, or wreck) a browser
 *  belonging to another worktree sharing the same engine. */
async function worktreeSessions() {
  const scope = requireScope();
  const res = await controlCall(scope.inst, { verb: "browser.list", worktreePath: scope.path });
  return res.sessions ?? [];
}

async function requireOwnSession(sessionId) {
  const sessions = await worktreeSessions();
  if (sessions.some((s) => s.sessionId === sessionId)) return;
  throw new Error(
    `browser session ${sessionId} isn't one of this worktree's — browser_list shows ` +
    "the ones you can drive. (Synth's engine is shared across worktrees and agents; " +
    "the tools only reach your own branch's sessions.)");
}

/** The { page, sessionId } a tool acts on. Always named outright: this server has no
 *  current-session pointer to fall back on, because sub-agents share it and one
 *  agent's retarget would silently move another's. */
async function targetEntry(inst, sessionId) {
  await requireOwnSession(sessionId);
  const pages = await sessionPagesSeeking(inst, (p) => p.sessionId === sessionId);
  const hit = pages.find((p) => p.sessionId === sessionId);
  if (!hit) throw new Error(`no live browser session ${sessionId} — see browser_list`);
  return hit;
}

async function targetPage(inst, sessionId) {
  return (await targetEntry(inst, sessionId)).page;
}

const sessionIdParam = z.string().describe(
  "session to act on — the sessionId browser_create returned, or one from " +
  "browser_list. Required: this server is shared with every sub-agent, so there " +
  "is no ambient current session to inherit");

// ---------------------------------------------------------------------------
// Addressing an element: a snapshot ref, or a CSS selector (ADR-0011 stage five).
//
// Both, not one. A ref is unambiguous for something the agent has just read, but
// Synth's agents wrote the page they are testing — forbidding `#save` when the agent
// authored `#save` would make a mandatory snapshot the price of every action.

const refParam = z.string().optional().describe(
  "element ref from this session's last browser_snapshot, e.g. e12 — the exact " +
  "element you read, no selector guessing");
const selectorParam = z.string().optional().describe(
  "CSS selector, for an element you already know (the one you wrote); the first " +
  "match is used. Pass this or ref, not both");

/** The Locator a ref or a selector names.
 *
 *  A ref that no longer resolves is always STALE, never a wrong node: Playwright
 *  keys each ref to the element object captured when the snapshot was taken and
 *  drops it the moment that element leaves the document (a re-render, a
 *  navigation, a new JS world). So the miss is reported as "re-snapshot", not left
 *  to time out looking like a bad selector — and nothing was acted on. */
async function resolveTarget(page, { ref, selector }) {
  if (ref && selector) throw new Error("pass ref or selector, not both");
  if (ref) {
    const loc = page.locator(`aria-ref=${ref}`);
    if (await loc.count() === 0) {
      throw new Error(
        `ref ${ref} doesn't point at anything on ${page.url()} any more — the page ` +
        "has re-rendered or navigated since the snapshot that issued it, so the ref " +
        "expired. Nothing was acted on. Call browser_snapshot again and use a ref " +
        "from the new one (or pass a CSS selector instead).");
    }
    return loc;
  }
  if (selector) return page.locator(selector).first();
  return null;
}

/** How an action names its target in a reply — the caller's own words. */
const targetLabel = ({ ref, selector }) => ref ? `ref ${ref}` : selector;

// ---------------------------------------------------------------------------
// Helpers.

/** working.html's browserNorm plus files: schemeless input gets https://, loopback
 *  gets http://, and local paths (absolute, ~, relative-if-it-exists) get file://. */
function normalizeURL(text) {
  const t = text.trim();
  if (t.includes("://")) return t;
  const asPath = t.startsWith("~/") ? path.join(os.homedir(), t.slice(2))
    : path.resolve(projectDir, t);
  if (t.startsWith("/") || t.startsWith("~/") || t.startsWith("./") ||
      t.startsWith("../") || fs.existsSync(asPath)) {
    return String(pathToFileURL(asPath));
  }
  if (/^(localhost|127\.|\[::1\]|0\.0\.0\.0)/.test(t)) return `http://${t}`;
  return `https://${t}`;
}

/** Post-action settle: wait for a load if the action triggered one, silently move
 *  on if it didn't (or the page navigated via history — CEF fires no
 *  domcontentloaded for those, the spike's lesson). */
async function settle(page, ms = 3000) {
  await page.waitForLoadState("load", { timeout: ms }).catch(() => {});
}

// ---------------------------------------------------------------------------
// Server + tools.

const server = new McpServer({ name: "synth-browser", version: "0.1.0" });
const tool = makeTool(server);

tool("browser_list",
  "List this worktree's Synth browser sessions (sessionId, title, url, branch; " +
  "owned sessions carry an owner field — the Synth session UUID of the owning claude). " +
  "url is read through to the live page; a session whose url could not be read that " +
  "way is marked lastKnownUrl instead.",
  null,
  async () => {
    const scope = requireScope();
    const res = await controlCall(scope.inst, { verb: "browser.list", worktreePath: scope.path });
    // Read through to CDP. The app's copy of the url lags a navigation in flight, and
    // an agent that trusts a stale url diagnoses the wrong thing entirely — so either
    // the value is live, or it says it isn't.
    const live = new Map();
    try {
      for (const { page, sessionId } of await sessionPages(requireInstance())) {
        if (sessionId) live.set(sessionId, page);
      }
    } catch { /* engine unreachable — every row falls back to last known */ }
    const sessions = res.sessions.map((s) => {
      const page = live.get(s.sessionId);
      if (!page) {
        const { url, ...rest } = s;
        return { ...rest, lastKnownUrl: url,
                 note: "no live CDP target — url is Synth's last-known value" };
      }
      return { ...s, url: page.url() };
    });
    const note = scope.exact ? "" : `\n(scoped to enclosing managed worktree ${scope.path})`;
    return text(JSON.stringify(sessions, null, 2) + note);
  });

tool("browser_create",
  "Create a new Synth browser session in this worktree's branch (visible in the " +
  "sidebar, selected), optionally pre-navigated to a URL. " +
  "The browser belongs to this Claude session — user comments made in it are routed " +
  "back to this session. Returns the sessionId: keep it, and pass it as sessionId " +
  "on every subsequent tool call. " +
  "Close it with browser_close once you're done, unless you opened it for the user.",
  { url: z.string().optional().describe("URL to open (scheme optional)") },
  async ({ url }) => {
    const scope = requireScope();
    const res = await controlCall(scope.inst, {
      verb: "browser.create", worktreePath: scope.path,
      ...(url && { url: normalizeURL(url) }),
      ...(process.env.SYNTH_SESSION_ID &&
          { ownerSessionId: process.env.SYNTH_SESSION_ID }),
    });
    // The engine (and, first time, the whole CDP endpoint) spins up async — wait
    // for the session's page target, re-reading the instance file for the port.
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      try {
        const pages = await sessionPagesSeeking(
          requireInstance(), (p) => p.sessionId === res.sessionId);
        if (pages.some((p) => p.sessionId === res.sessionId)) {
          return text(JSON.stringify({ sessionId: res.sessionId }));
        }
      } catch { /* endpoint not up yet */ }
      await new Promise((r) => setTimeout(r, 300));
    }
    // A row whose page never came up is an orphan: unusable by the agent, and left
    // for the user to clear. Roll it back so the call either yields a working
    // session or leaves nothing behind.
    let rolledBack = true;
    try {
      await controlCall(scope.inst, {
        verb: "browser.close", worktreePath: scope.path, sessionId: res.sessionId,
        ...(process.env.SYNTH_SESSION_ID &&
            { ownerSessionId: process.env.SYNTH_SESSION_ID }),
      });
    } catch { rolledBack = false; }
    throw new Error(
      "the browser session's CDP target never appeared within 15s, so it has no usable " +
      "page — " + (rolledBack
        ? "the session was rolled back and nothing is left in the sidebar. Retry"
        : `the rollback failed too, so session ${res.sessionId} may still be in the ` +
          "sidebar; close it with browser_close. Retry") +
      ", and if it happens again run browser_health — a heavily loaded engine is the " +
      "usual cause.");
  });

tool("browser_close",
  "Close a browser session you created, removing its row from the sidebar. Do this as " +
  "soon as you're done with a browser the user has no reason to keep — one you opened " +
  "only to check your own work, where you don't need their eyes on it or a comment back. " +
  "Leave it open when you opened it FOR the user (to look at, or to comment in), and tell " +
  "them it's there. Only browsers this Claude session owns can be closed: the user's own " +
  "⌘K browsers, and any browser they detached or moved to another session, are theirs.",
  { sessionId: z.string().describe("the sessionId to close (from browser_create/browser_list)") },
  async ({ sessionId }) => {
    const scope = requireScope();
    // Hold the page before the row goes, so the tab can be accounted for afterwards:
    // a "closed" that leaves a live target behind is worse than an error.
    let page = null;
    try { page = (await targetEntry(requireInstance(), sessionId)).page; }
    catch { /* already unreachable — the app's answer is the only one available */ }
    await controlCall(scope.inst, {
      verb: "browser.close", worktreePath: scope.path, sessionId,
      ...(process.env.SYNTH_SESSION_ID &&
          { ownerSessionId: process.env.SYNTH_SESSION_ID }),
    });
    if (!page) return text(`closed ${sessionId}`);
    const deadline = Date.now() + 3000;
    while (!page.isClosed() && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 150));
    }
    if (page.isClosed()) return text(`closed ${sessionId}`);
    try {
      await page.close({ runBeforeUnload: false });
      return text(`closed ${sessionId} (its page outlived the row and was force-closed)`);
    } catch (e) {
      throw new Error(
        `the ${sessionId} row was removed but its page target is still alive and would ` +
        `not close (${e.message}) — an orphan tab is holding a renderer. It shows up in ` +
        "browser_health; tell the user, it needs the engine restarting.");
    }
  });

/** A navigation that ran out of time is not a navigation that failed: the request
 *  went out, the server acted on it, and the page is usually already there. For a
 *  one-shot URL (a handoff code, a magic link) that difference is the whole game —
 *  reported as an error, an agent retries and burns a second single-use link. */
function stillLoading(page, dest, before, ms) {
  const at = page.url();
  const moved = at !== before;
  return text(
    `${dest} hasn't finished loading within ${ms / 1000}s — NOT a failure. The request ` +
    `was sent and the server has acted on it, so do not retry it if the URL was ` +
    `single-use. The page is ${moved ? `now at ${at}` : `still showing ${at}`} and the ` +
    "load is still in flight (a cold dev-server compile takes this long routinely). " +
    "Poll it with browser_snapshot or browser_evaluate, or re-issue with a bigger " +
    "timeout — but only if the URL is safe to request twice.");
}

const isTimeout = (e) => /Timeout .* exceeded/.test(e.message);

tool("browser_navigate",
  "Navigate a browser session to a URL. " +
  "Waits for DOM-ready by default, not every subresource; a timeout here reports the " +
  "navigation as still in flight rather than as a failure.",
  {
    url: z.string().describe("destination (scheme optional; localhost gets http)"),
    sessionId: sessionIdParam,
    waitUntil: z.enum(["commit", "domcontentloaded", "load"]).optional().describe(
      "how far to wait: commit (response started), domcontentloaded (default), load (all subresources)"),
    timeout: z.number().optional().describe("milliseconds to wait (default 30000)"),
  },
  async ({ url, sessionId, waitUntil = "domcontentloaded", timeout = 30000 }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const dest = normalizeURL(url);
    const before = page.url();
    try {
      await page.goto(dest, { waitUntil, timeout });
    } catch (e) {
      if (!isTimeout(e)) throw e;
      return stillLoading(page, dest, before, timeout);
    }
    return text(`now at ${page.url()} — "${await page.title()}"`);
  });

// History navs in CEF fire no domcontentloaded (the spike's lesson) — wait for
// commit, then settle. Success is judged by the URL, not the return value:
// Playwright yields null for a history nav that produced no network response.
async function historyNav(sessionId, go) {
  const page = await targetPage(requireInstance(), sessionId);
  const before = page.url();
  await go(page, { waitUntil: "commit", timeout: 10000 });
  await settle(page);
  return { page, moved: page.url() !== before };
}

tool("browser_back", "Go back in the session's history.",
  { sessionId: sessionIdParam },
  async ({ sessionId }) => {
    const { page, moved } = await historyNav(sessionId, (p, o) => p.goBack(o));
    return text(moved ? `now at ${page.url()}` : "nothing to go back to");
  });

tool("browser_forward", "Go forward in the session's history.",
  { sessionId: sessionIdParam },
  async ({ sessionId }) => {
    const { page, moved } = await historyNav(sessionId, (p, o) => p.goForward(o));
    return text(moved ? `now at ${page.url()}` : "nothing to go forward to");
  });

tool("browser_reload", "Reload the session's page.",
  {
    sessionId: sessionIdParam,
    waitUntil: z.enum(["commit", "domcontentloaded", "load"]).optional().describe(
      "how far to wait (default domcontentloaded)"),
    timeout: z.number().optional().describe("milliseconds to wait (default 30000)"),
  },
  async ({ sessionId, waitUntil = "domcontentloaded", timeout = 30000 }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const before = page.url();
    try {
      await page.reload({ waitUntil, timeout });
    } catch (e) {
      if (!isTimeout(e)) throw e;
      return stillLoading(page, before, before, timeout);
    }
    return text(`reloaded ${page.url()}`);
  });

tool("browser_device_mode",
  "Read or set the session's device mode — the page inside a hardware device frame at a " +
  "real device viewport (Chrome device-toolbar emulation: true innerWidth/innerHeight, " +
  "devicePixelRatio, mobile layout), visible to the user in the pane. A session runs with " +
  "no device — the page at the pane's own desktop viewport — and that is the right way to " +
  "check ordinary work: only enter device mode when the task itself is about phone or " +
  "tablet layout, and leave it with on:false once that check is done. The fleet is phones " +
  "and tablets; a desktop viewport is this mode off, not the widest device in the list. " +
  "Screenshots and clicks see the emulated viewport too. With no arguments it reports the " +
  "current state plus the fleet (smallest → biggest) and changes nothing. Naming a device " +
  "or orientation switches the mode on; it persists across navigations until turned off.",
  {
    sessionId: sessionIdParam,
    on: z.boolean().optional().describe(
      "false returns the page to the desktop viewport (default true when any other " +
      "setting is passed)"),
    device: z.string().optional().describe(
      "fleet device id the task calls for, e.g. iphone-se or iphone-16 (full list in the " +
      "no-arg reply)"),
    landscape: z.boolean().optional().describe("true = landscape, false = portrait"),
  },
  async ({ sessionId, on, device, landscape }) => {
    const scope = requireScope();
    // targetEntry proves the session is this worktree's and has a live target.
    const { sessionId: sid } = await targetEntry(requireInstance(), sessionId);
    const { ok, ...state } = await controlCall(scope.inst, {
      verb: "browser.deviceMode", worktreePath: scope.path, sessionId: sid,
      ...(on !== undefined && { on }),
      ...(device !== undefined && { device }),
      ...(landscape !== undefined && { landscape }),
    });
    return text(JSON.stringify(state, null, 2));
  });

// ---------------------------------------------------------------------------
// Free viewport (ADR-0011 stage five). The six-device fleet above is the pane's
// device chrome — hardware, for a human choosing a phone. It is also, without this,
// the only viewport control there is, so a 1440px desktop or a 900px tablet
// breakpoint cannot be checked at all.
//
// The override rides an open CDP session: Chromium reverts emulation when the
// session that set it detaches (the same reason the pane's own DeviceEmulator holds
// its client open for as long as device mode is on). So the session is kept, keyed
// by Synth session, and the width/height are kept beside it — a dropped CDP
// connection (a reconnect, a port change) is re-applied on the next call rather
// than silently reverting for good.

const viewports = new Map(); // synth sessionId -> { client, width, height, deviceScaleFactor, mobile }

async function clearViewport(sid) {
  const vp = viewports.get(sid);
  if (!vp) return;
  viewports.delete(sid);
  try { await vp.client.send("Emulation.clearDeviceMetricsOverride"); } catch { /* gone */ }
  await vp.client.detach().catch(() => {});
}

tool("browser_viewport",
  "Read or set the size the page lays out at, in CSS pixels — the agent's own " +
  "viewport control, free of the device fleet. This is how you check a desktop or " +
  "tablet breakpoint (1440×900, 1024×768) that no phone in browser_device_mode " +
  "covers. The page renders at exactly the size you name and is scaled down to fit " +
  "the pane, so the user sees the whole layout; screenshots, snapshots and clicks " +
  "all see the new viewport. With no width or height it reports the current state " +
  "and changes nothing. The override lasts as long as this MCP server does — it " +
  "goes when your session ends, and browser_device_mode replaces it while a device " +
  "is on.",
  {
    sessionId: sessionIdParam,
    width: z.number().int().positive().optional().describe("viewport width in CSS pixels"),
    height: z.number().int().positive().optional().describe("viewport height in CSS pixels"),
    deviceScaleFactor: z.number().positive().optional().describe(
      "devicePixelRatio to report (default 1; 2 for a retina check)"),
    mobile: z.boolean().optional().describe(
      "render as a mobile browser would (touch, mobile user-agent layout); default false"),
    reset: z.boolean().optional().describe(
      "drop the override and give the page the pane's own viewport back"),
  },
  async ({ sessionId, width, height, deviceScaleFactor = 1, mobile = false, reset }) => {
    const inst = requireInstance();
    const { page, sessionId: sid } = await targetEntry(inst, sessionId);

    if (reset) {
      await clearViewport(sid);
      const now = await page.evaluate("({ width: innerWidth, height: innerHeight })");
      return text(JSON.stringify({ override: null, ...now }, null, 2));
    }

    const held = viewports.get(sid);
    if (width == null && height == null) {
      const now = await page.evaluate(
        "({ width: innerWidth, height: innerHeight, deviceScaleFactor: devicePixelRatio })");
      return text(JSON.stringify({
        override: held ? { width: held.width, height: held.height } : null, ...now,
      }, null, 2));
    }

    // Device mode draws a phone around the page and emulates its viewport from the
    // app side. A free viewport inside that frame is a page laid out at 1440 inside a
    // drawn iPhone — refuse rather than render a lie at the user.
    const scope = requireScope();
    const dm = await controlCall(scope.inst, {
      verb: "browser.deviceMode", worktreePath: scope.path, sessionId: sid });
    if (dm.on) {
      throw new Error(
        `session ${sid} is in device mode (${dm.device}), which owns the viewport and ` +
        "draws that hardware around the page. Leave it with browser_device_mode " +
        "on:false first, then set the viewport you want.");
    }

    // The pane's own size is what the page gets with no override — so measure it
    // WITHOUT one, or a second call would fit the new viewport into the last one and
    // the page would shrink a little further every time.
    await clearViewport(sid);
    const pane = await page.evaluate("({ w: innerWidth, h: innerHeight })");
    const w = width ?? pane.w;
    const h = height ?? pane.h;
    // Scale DOWN to fit, never up (the device stage's rule): a viewport smaller than
    // the pane stays life-size rather than being blown up to fill it.
    const scale = Math.min(1, pane.w / w, pane.h / h);

    const client = await page.context().newCDPSession(page);
    await client.send("Emulation.setDeviceMetricsOverride",
                      { width: w, height: h, deviceScaleFactor, mobile, scale });
    const vp = { client, width: w, height: h, deviceScaleFactor, mobile };
    viewports.set(sid, vp);
    // A page that closes under us would otherwise strand the CDP session.
    page.once("close", () => { if (viewports.get(sid) === vp) viewports.delete(sid); });

    return text(JSON.stringify({
      width: w, height: h, deviceScaleFactor, mobile,
      renderedAt: `${Math.round(scale * 100)}% of the pane's ${pane.w}×${pane.h}`,
    }, null, 2));
  });

tool("browser_click",
  "Click in the session's page: a snapshot ref, a CSS selector, or viewport coordinates.",
  {
    ref: refParam,
    selector: selectorParam,
    x: z.number().optional().describe("viewport x (used with y when neither ref nor selector is given)"),
    y: z.number().optional().describe("viewport y"),
    button: z.enum(["left", "right", "middle"]).optional().describe("mouse button (default left)"),
    clickCount: z.number().int().positive().optional().describe("2 for a double-click"),
    sessionId: sessionIdParam,
  },
  async ({ ref, selector, x, y, button = "left", clickCount = 1, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const target = await resolveTarget(page, { ref, selector });
    if (target) await target.click({ timeout: 5000, button, clickCount });
    else if (x != null && y != null) await page.mouse.click(x, y, { button, clickCount });
    else throw new Error("pass ref, selector, or both x and y");
    await settle(page);
    return text(`clicked ${targetLabel({ ref, selector }) ?? `(${x}, ${y})`}` +
                ` — now at ${page.url()}`);
  });

tool("browser_type",
  "Type text into the session's page — into a ref or selector (replacing its value) " +
  "or the currently focused element; optionally press Enter after.",
  {
    text: z.string().describe("text to type"),
    ref: refParam,
    selector: selectorParam,
    submit: z.boolean().optional().describe("press Enter afterwards"),
    sessionId: sessionIdParam,
  },
  async ({ text: value, ref, selector, submit, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const target = await resolveTarget(page, { ref, selector });
    if (target) await target.fill(value, { timeout: 5000 });
    else await page.keyboard.type(value);
    if (submit) await page.keyboard.press("Enter");
    await settle(page);
    return text(`typed into ${targetLabel({ ref, selector }) ?? "the focused element"}` +
                `${submit ? " and submitted" : ""}`);
  });

tool("browser_hover",
  "Hover the pointer over an element — the only way to reach a menu, tooltip or " +
  "control that appears on hover. The hover persists until the pointer moves again, " +
  "so snapshot or screenshot straight after.",
  { ref: refParam, selector: selectorParam, sessionId: sessionIdParam },
  async ({ ref, selector, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const target = await resolveTarget(page, { ref, selector });
    if (!target) throw new Error("pass ref or selector");
    await target.hover({ timeout: 5000 });
    await settle(page, 1000);
    return text(`hovering ${targetLabel({ ref, selector })}`);
  });

tool("browser_press_key",
  "Press a key in the session's page — Escape to dismiss, Tab to move focus, " +
  "ArrowDown to walk a listbox, Enter to confirm. Naming an element focuses it " +
  "first; otherwise the key goes wherever focus already is.",
  {
    key: z.string().describe(
      "a Playwright key name: a single character, or Enter/Escape/Tab/Backspace/Delete/" +
      "ArrowUp/ArrowDown/ArrowLeft/ArrowRight/Home/End/PageUp/PageDown/F1-F12, " +
      "optionally with modifiers, e.g. Control+A or Shift+Tab"),
    ref: refParam,
    selector: selectorParam,
    repeat: z.number().int().positive().optional().describe("press it this many times (default 1)"),
    sessionId: sessionIdParam,
  },
  async ({ key, ref, selector, repeat = 1, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const target = await resolveTarget(page, { ref, selector });
    for (let i = 0; i < repeat; i++) {
      if (target) await target.press(key, { timeout: 5000 });
      else await page.keyboard.press(key);
    }
    await settle(page);
    return text(`pressed ${key}${repeat > 1 ? ` ×${repeat}` : ""}` +
                `${target ? ` on ${targetLabel({ ref, selector })}` : ""} — now at ${page.url()}`);
  });

tool("browser_select_option",
  "Choose in a native <select>. Clicking one opens an OS menu the page cannot see, " +
  "so this is the only way to change its value — pass the option's value, label or " +
  "index. A multi-select takes several.",
  {
    ref: refParam,
    selector: selectorParam,
    values: z.array(z.string()).optional().describe("option values to select"),
    labels: z.array(z.string()).optional().describe("option labels (visible text) to select"),
    indexes: z.array(z.number().int().nonnegative()).optional().describe("option indexes to select"),
    sessionId: sessionIdParam,
  },
  async ({ ref, selector, values, labels, indexes, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const target = await resolveTarget(page, { ref, selector });
    if (!target) throw new Error("pass ref or selector naming the <select>");
    const wanted = [
      ...(values ?? []).map((value) => ({ value })),
      ...(labels ?? []).map((label) => ({ label })),
      ...(indexes ?? []).map((index) => ({ index })),
    ];
    if (wanted.length === 0) throw new Error("pass values, labels or indexes");
    const chosen = await target.selectOption(wanted, { timeout: 5000 });
    await settle(page);
    return text(`selected ${JSON.stringify(chosen)} in ${targetLabel({ ref, selector })}`);
  });

tool("browser_scroll",
  "Scroll the page, or bring one element into view — how a lazy list loads its next " +
  "page and how anything below the fold becomes clickable.",
  {
    ref: refParam,
    selector: selectorParam,
    to: z.enum(["top", "bottom"]).optional().describe(
      "jump to the top or the bottom of the document (bottom is what triggers " +
      "infinite scroll)"),
    dy: z.number().optional().describe("scroll down by this many pixels (negative = up)"),
    dx: z.number().optional().describe("scroll right by this many pixels (negative = left)"),
    sessionId: sessionIdParam,
  },
  async ({ ref, selector, to, dy, dx, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const target = await resolveTarget(page, { ref, selector });
    let what;
    if (target) {
      await target.scrollIntoViewIfNeeded({ timeout: 5000 });
      what = `scrolled ${targetLabel({ ref, selector })} into view`;
    } else if (to) {
      await page.evaluate(`window.scrollTo(0, ${to === "top" ? 0 : "document.body.scrollHeight"})`);
      what = `scrolled to the ${to}`;
    } else if (dy != null || dx != null) {
      await page.mouse.wheel(dx ?? 0, dy ?? 0);
      what = `scrolled by (${dx ?? 0}, ${dy ?? 0})`;
    } else {
      throw new Error("pass ref/selector, to, or dx/dy");
    }
    // Lazy lists fetch on scroll; give the fetch a beat before the agent reads the page.
    await page.waitForTimeout(300);
    const at = await page.evaluate("({ x: window.scrollX, y: window.scrollY, " +
                                   "height: document.body.scrollHeight })");
    return text(`${what} — now at y=${Math.round(at.y)} of ${Math.round(at.height)}`);
  });

tool("browser_wait_for",
  "Wait for the page to reach a condition instead of guessing at a delay: text to " +
  "appear or go, an element to become visible or leave, or a JS expression to turn " +
  "truthy. Use this for anything that arrives a beat later — a spinner finishing, a " +
  "toast, a route transition — rather than acting and reading a click timeout.",
  {
    text: z.string().optional().describe("wait until this text is visible on the page"),
    textGone: z.string().optional().describe("wait until this text is no longer on the page"),
    ref: refParam,
    selector: selectorParam,
    state: z.enum(["visible", "hidden", "attached", "detached"]).optional().describe(
      "what the ref/selector element should reach (default visible)"),
    expression: z.string().optional().describe(
      "JS expression polled until it is truthy, e.g. window.__ready === true"),
    timeout: z.number().optional().describe("milliseconds to wait (default 10000)"),
    sessionId: sessionIdParam,
  },
  async ({ text: wantText, textGone, ref, selector, state = "visible", expression,
           timeout = 10000, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const started = Date.now();
    let what;
    try {
      if (wantText != null) {
        await page.getByText(wantText).first().waitFor({ state: "visible", timeout });
        what = `"${wantText}" appeared`;
      } else if (textGone != null) {
        await page.getByText(textGone).first().waitFor({ state: "hidden", timeout });
        what = `"${textGone}" went`;
      } else if (ref || selector) {
        // A ref names an element captured at snapshot time, so "detached" is the only
        // state it can newly reach — waiting for a ref to become visible is waiting on
        // a node that already exists. Selectors carry the general case.
        const target = await resolveTarget(page, { ref, selector });
        await target.waitFor({ state, timeout });
        what = `${targetLabel({ ref, selector })} is ${state}`;
      } else if (expression != null) {
        await page.waitForFunction(expression, undefined, { timeout });
        what = `${expression} became truthy`;
      } else {
        throw new Error("pass text, textGone, ref/selector, or expression");
      }
    } catch (e) {
      if (!isTimeout(e)) throw e;
      throw new Error(
        `still not true after ${timeout / 1000}s on ${page.url()} — the page did not ` +
        "reach the condition. browser_snapshot shows what it did reach; " +
        "browser_console often says why.");
    }
    return text(`${what} after ${Date.now() - started}ms`);
  });

// ---------------------------------------------------------------------------
// Capture. Both of these write to disk and return a path, and inline only when
// asked (ADR-0011 stage five): an inlined screenshot is the single largest context
// cost in agent browsing, and an opt-in disk path is one agents mostly don't take.

/** Where a capture lands: the caller's path (relative to the worktree), else a
 *  temp file. The directory is created either way. */
function captureFile(outPath, fallbackName) {
  const out = outPath ? path.resolve(projectDir, outPath)
                      : path.join(os.tmpdir(), fallbackName);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  return out;
}

// Above this, an image is not worth putting in a model's context whatever it was
// asked for — inlining it is how a single call costs six figures of tokens.
const INLINE_MAX_BYTES = 4_000_000;

tool("browser_screenshot",
  "Screenshot the session's page to a PNG file and return its path — the viewport " +
  "by default, or the whole scrollable page (fullPage), or one element (ref or " +
  "selector). It does NOT come back as an image unless you ask: pass inline:true " +
  "when you actually need to look at it, and otherwise pass the path on to the user " +
  "or to another tool. An inlined capture is the most expensive thing an agent can " +
  "put in its own context, and a page you can already read with browser_snapshot " +
  "rarely needs looking at.",
  {
    sessionId: sessionIdParam,
    path: z.string().optional().describe(
      "where to write the PNG (relative to the worktree). Default: a temp file"),
    inline: z.boolean().optional().describe(
      "also return the image itself, for when you need to see it"),
    fullPage: z.boolean().optional().describe(
      "capture the entire scrollable page, not just the viewport"),
    ref: refParam,
    selector: selectorParam,
  },
  async ({ sessionId, path: outPath, inline, fullPage, ref, selector }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const target = await resolveTarget(page, { ref, selector });
    const out = captureFile(outPath, `synth-screenshot-${Date.now()}.png`);
    const opts = { type: "png", timeout: 15000, path: out };
    if (target) await target.screenshot(opts);
    else await page.screenshot({ ...opts, fullPage: !!fullPage });
    const bytes = fs.statSync(out).size;
    const what = target ? targetLabel({ ref, selector }) : (fullPage ? "full page" : "viewport");
    const summary = `${out}\n${what} of ${page.url()} — ${bytes} bytes`;
    if (!inline) return text(summary);
    if (bytes > INLINE_MAX_BYTES) {
      return text(`${summary}\n\nToo big to inline (${bytes} bytes) — it is on disk at ` +
                  "the path above. Capture one element, or the viewport instead of the " +
                  "full page, if you need to see it here.");
    }
    return {
      content: [
        { type: "text", text: summary },
        { type: "image", data: fs.readFileSync(out).toString("base64"), mimeType: "image/png" },
      ],
    };
  });

/** Whether a response body belongs in the dump or beside it as bytes.
 *
 *  The bytes decide, not the declared type. Content-Type is only a veto here — a body served
 *  as an image or a font is never worth reading — because a response revalidated out of cache
 *  arrives with no Content-Type at all, and answering "17 bytes of binary, written beside this
 *  file" about a JSON reply is the tool being unhelpful about the exact case it exists for. */
function isTextual(contentType, buf) {
  if (buf.includes(0)) return false;
  if (/^(image\/|audio\/|video\/|font\/|application\/(octet-stream|pdf|zip|gzip|wasm|x-protobuf))/
      .test(contentType ?? "")) {
    return false;
  }
  // Round-trips through UTF-8 = someone can read it. Bounded, so a large body costs a fixed
  // sample rather than a full copy.
  const sample = buf.subarray(0, 64 * 1024);
  return Buffer.compare(Buffer.from(sample.toString("utf8"), "utf8"), sample) === 0;
}

tool("browser_network",
  "The session's network traffic. With no request id it lists what the page has " +
  "asked for — method, URL, status, type, timing, size — which is enough to see a " +
  "404, a CORS failure or a call that never went out. Name one entry's id and its " +
  "headers and body are written to a FILE whose path comes back; bodies never come " +
  "inline, because one JSON response can cost tens of thousands of tokens and " +
  "because authorization headers should not land in your context by default. " +
  "Requests are recorded from the moment these tools first touched the page, so " +
  "reload it (browser_reload) if you need the page's own first load.",
  {
    sessionId: sessionIdParam,
    request: z.string().optional().describe(
      "an entry id from the list (e.g. r14) — writes that request's headers and body " +
      "to disk and returns the path"),
    filter: z.string().optional().describe("only entries whose URL contains this"),
    type: z.string().optional().describe(
      "only this resource type: document, stylesheet, script, image, xhr, fetch, font, …"),
    failedOnly: z.boolean().optional().describe(
      "only requests that failed outright or came back 4xx/5xx"),
    limit: z.number().int().positive().optional().describe(
      "how many of the most recent entries to list (default 50)"),
    path: z.string().optional().describe(
      "where to write the dump (relative to the worktree). Default: a temp file"),
  },
  async ({ sessionId, request: wantId, filter, type, failedOnly, limit = 50, path: outPath }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const net = pageNet.get(page);
    if (!net || net.entries.length === 0) {
      return text(`nothing recorded on ${page.url()} yet — these tools only see ` +
                  "requests made since they first attached to the page. Reload it " +
                  "(browser_reload) and call this again.");
    }

    if (wantId) {
      const entry = net.entries.find((e) => e.id === wantId);
      if (!entry) {
        throw new Error(`no request ${wantId} on this page — the list has ` +
                        `${net.entries[0].id}…${net.entries[net.entries.length - 1].id} ` +
                        `(the log keeps the last ${NETWORK_CAP})`);
      }
      return text(await dumpRequest(entry, outPath));
    }

    let rows = net.entries;
    if (filter) rows = rows.filter((e) => e.url.includes(filter));
    if (type) rows = rows.filter((e) => e.type === type);
    if (failedOnly) rows = rows.filter((e) => e.failed || (e.status ?? 0) >= 400);
    const shown = rows.slice(-limit);
    if (shown.length === 0) return text("no requests match");
    const lines = shown.map((e) =>
      [e.id, e.method, e.failed ? `FAILED(${e.failed})` : (e.status ?? "pending"),
       e.type, e.ms == null ? "" : `${e.ms}ms`,
       e.bytes == null ? "" : `${e.bytes}B`, e.url]
        .filter(Boolean).join("  "));
    const dropped = rows.length - shown.length;
    return text(
      `${shown.length} of ${net.entries.length} recorded requests on ${page.url()}` +
      `${dropped > 0 ? ` (${dropped} older ones not shown — raise limit)` : ""}\n` +
      "Name an id in `request` to write its headers and body to a file.\n\n" +
      lines.join("\n"));
  });

async function dumpRequest(entry, outPath) {
  const { req } = entry;
  const parts = [`${entry.method} ${entry.url}`, ""];
  parts.push("--- request headers ---");
  for (const h of await req.headersArray()) parts.push(`${h.name}: ${h.value}`);
  const post = req.postData();
  if (post) parts.push("", "--- request body ---", post);

  let sidecar = null;
  const res = await req.response().catch(() => null);
  if (!res) {
    parts.push("", entry.failed ? `--- no response: ${entry.failed} ---`
                                : "--- no response yet ---");
  } else {
    parts.push("", `--- response ${res.status()} ${res.statusText()} ---`);
    const headers = await res.headersArray();
    for (const h of headers) parts.push(`${h.name}: ${h.value}`);
    const contentType = headers.find((h) => h.name.toLowerCase() === "content-type")?.value;
    let body = entry.body ?? null;
    if (!body) {
      try { body = await res.body(); }
      catch (e) {
        parts.push("", `--- response body unavailable: ${e.message} ---`,
                   "(the engine keeps text-shaped bodies as they finish, but drops anything " +
                   "bigger once the page has moved on — re-issue the request and dump it " +
                   "before navigating)");
      }
    }
    if (body && body.length === 0) {
      // A 200 with nothing in it — a cache hit, a 204-shaped reply. Saying so beats writing a
      // zero-byte file beside the dump and calling it the body.
      parts.push("", "--- response body: empty ---");
    } else if (body) {
      if (isTextual(contentType, body)) {
        parts.push("", `--- response body (${body.length} bytes) ---`, body.toString("utf8"));
      } else {
        sidecar = { body, contentType };
        parts.push("", `--- response body: ${body.length} bytes of ` +
                       `${contentType ?? "binary"}, written beside this file ---`);
      }
    }
  }

  const out = captureFile(outPath, `synth-request-${entry.id}-${Date.now()}.txt`);
  if (sidecar) {
    const binPath = out + ".bin";
    fs.writeFileSync(binPath, sidecar.body);
    parts.push(binPath);
  }
  fs.writeFileSync(out, parts.join("\n"));
  return `${entry.method} ${entry.url}\n${entry.failed ?? entry.status ?? "pending"} — ` +
         `headers and body written to:\n${out}` +
         (sidecar ? `\n${out}.bin` : "");
}

// ---------------------------------------------------------------------------
// Video recording — Page.startScreencast streams a JPEG per repaint (variable
// rate); stop replays them onto a constant-fps timeline and pipes that through
// ffmpeg (Playwright's own screencast-to-video strategy). Verified against CEF:
// frames keep flowing across cross-page navigations.

const recordings = new Map(); // synth sessionId -> { dir, frames, cdp, truncated, stoppedTs }
const REC_MAX_FRAMES = 4500;  // ~3 min of continuous repaints; bounds disk and encode time

/** ffmpeg to encode with: a full build from the usual places (mp4-capable), else
 *  Playwright's VP8-only build from its cache, downloading it (~2 MB) on first use. */
function findFfmpeg() {
  for (const bin of ["ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]) {
    try { execFileSync(bin, ["-version"], { stdio: "ignore" }); return { bin, mp4: true }; }
    catch { /* not there — keep looking */ }
  }
  const cached = playwrightFfmpeg();
  if (cached) return { bin: cached, mp4: false };
  const pkg = createRequire(import.meta.url).resolve("playwright-core/package.json");
  try {
    execFileSync(process.execPath, [path.join(path.dirname(pkg), "cli.js"), "install", "ffmpeg"],
      { stdio: "ignore", timeout: 120000 });
  } catch { /* offline or blocked — fall through to the error */ }
  const installed = playwrightFfmpeg();
  if (installed) return { bin: installed, mp4: false };
  throw new Error(
    "no ffmpeg available to encode the video — install one (brew install ffmpeg) and retry");
}

function playwrightFfmpeg() {
  const cache = path.join(os.homedir(), "Library/Caches/ms-playwright");
  let dirs;
  try { dirs = fs.readdirSync(cache); } catch { return null; }
  for (const d of dirs.filter((n) => n.startsWith("ffmpeg-")).sort().reverse()) {
    const bin = path.join(cache, d, "ffmpeg-mac");
    if (fs.existsSync(bin)) return bin;
  }
  return null;
}

/** Encode a recording's frames to `out`; returns the video's duration in seconds.
 *  Walks a constant-fps timeline repeating the latest frame at or before each tick
 *  (image2pipe is the one input method Playwright's minimal ffmpeg supports). */
async function encodeVideo(rec, out, format, bin) {
  const FPS = 25;
  const frames = rec.frames;
  const last = frames[frames.length - 1].ts;
  // Hold the final state briefly so the video spans until the stop, not the last
  // repaint — clamped, so a timestamp-base surprise can't yield an hour of stills.
  const tEnd = last + Math.max(0, Math.min(2, (rec.stoppedTs ?? last) - last));
  const args = [
    "-y", "-f", "image2pipe", "-c:v", "mjpeg", "-r", String(FPS), "-i", "pipe:0",
    "-an", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p",
    ...(format === "mp4"
      ? ["-c:v", "libx264", "-movflags", "+faststart"]
      : ["-c:v", "vp8", "-qmin", "0", "-qmax", "50", "-crf", "8", "-b:v", "1M"]),
    out,
  ];
  const ff = spawn(bin, args, { stdio: ["pipe", "ignore", "pipe"] });
  let stderr = "";
  ff.stderr.on("data", (d) => { stderr += d; });
  ff.stdin.on("error", () => {}); // EPIPE when ffmpeg dies early — close reports it
  const done = new Promise((resolve, reject) => {
    ff.on("error", reject);
    ff.on("close", (code) => code === 0 ? resolve()
      : reject(new Error(`ffmpeg exited ${code}: ${stderr.slice(-400)}`)));
  });
  let i = 0, buf = null, bufFor = null;
  for (let t = frames[0].ts; t <= tEnd; t += 1 / FPS) {
    while (i + 1 < frames.length && frames[i + 1].ts <= t) i++;
    if (frames[i].file !== bufFor) { bufFor = frames[i].file; buf = fs.readFileSync(bufFor); }
    if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once("drain", r));
  }
  ff.stdin.end();
  await done;
  return tEnd - frames[0].ts;
}

tool("browser_record_start",
  "Start recording the session's page as video. Captures a frame on every repaint " +
  "until browser_record_stop, which encodes and returns the video file path. " +
  "One recording per session; keep driving the page with the other tools meanwhile.",
  { sessionId: sessionIdParam },
  async ({ sessionId }) => {
    const { page, sessionId: sid } = await targetEntry(requireInstance(), sessionId);
    if (recordings.has(sid)) {
      throw new Error(`session ${sid} is already recording — browser_record_stop first`);
    }
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "synth-rec-"));
    const cdp = await page.context().newCDPSession(page);
    const rec = { dir, frames: [], cdp, truncated: false, stoppedTs: null };
    cdp.on("Page.screencastFrame", (e) => {
      cdp.send("Page.screencastFrameAck", { sessionId: e.sessionId }).catch(() => {});
      if (rec.frames.length >= REC_MAX_FRAMES) {
        if (!rec.truncated) { rec.truncated = true; cdp.send("Page.stopScreencast").catch(() => {}); }
        return;
      }
      const file = path.join(dir, `f${String(rec.frames.length).padStart(6, "0")}.jpg`);
      fs.writeFileSync(file, Buffer.from(e.data, "base64"));
      rec.frames.push({ file, ts: e.metadata.timestamp });
    });
    try {
      await cdp.send("Page.startScreencast", {
        format: "jpeg", quality: 80, maxWidth: 1600, maxHeight: 1600, everyNthFrame: 1,
      });
    } catch (e) {
      fs.rmSync(dir, { recursive: true, force: true });
      await cdp.detach().catch(() => {});
      throw e;
    }
    // If the recorded page closes (browser_close, user navigation-away, target crash) before
    // browser_record_stop, nothing else would detach the CDP session or delete the frame dir —
    // the temp dir would then outlive the process. Clean up on that edge too.
    page.once("close", () => {
      if (recordings.get(sid) !== rec) return;
      recordings.delete(sid);
      rec.cdp.detach().catch(() => {});
      fs.rmSync(rec.dir, { recursive: true, force: true });
    });
    recordings.set(sid, rec);
    return text(`recording session ${sid} — drive the page, then browser_record_stop`);
  });

tool("browser_record_stop",
  "Stop recording and encode the video: mp4 (H.264) when a full ffmpeg is installed, " +
  "else webm (VP8) via Playwright's bundled ffmpeg. Returns the file path plus " +
  "duration/frame stats — the video is for the user or post-processing; you cannot " +
  "watch it (screenshot the page instead to check state).",
  {
    path: z.string().optional().describe(
      "where to write the video (relative to the worktree; a .mp4 or .webm extension " +
      "picks the format). Default: a temp file, mp4 when ffmpeg allows"),
    sessionId: sessionIdParam,
  },
  async ({ path: outPath, sessionId: sid }) => {
    const rec = recordings.get(sid);
    if (!rec) {
      const active = [...recordings.keys()];
      throw new Error(active.length > 0
        ? `no recording on session ${sid} — recording now: ${active.join(", ")}`
        : "no active recording — start one with browser_record_start");
    }
    recordings.delete(sid);
    rec.stoppedTs = Date.now() / 1000;
    await rec.cdp.send("Page.stopScreencast").catch(() => {});
    await rec.cdp.detach().catch(() => {});
    try {
      if (rec.frames.length === 0) {
        throw new Error("no frames captured — the page never repainted while recording");
      }
      const ff = findFfmpeg();
      if (outPath?.endsWith(".mp4") && !ff.mp4) {
        throw new Error(
          "an mp4 needs a full ffmpeg (brew install ffmpeg) — only Playwright's VP8-only " +
          "build is available here; pass a .webm path instead");
      }
      const format = outPath?.endsWith(".webm") || !ff.mp4 ? "webm" : "mp4";
      const out = outPath ? path.resolve(projectDir, outPath)
        : path.join(os.tmpdir(), `synth-recording-${Date.now()}.${format}`);
      fs.mkdirSync(path.dirname(out), { recursive: true });
      const seconds = await encodeVideo(rec, out, format, ff.bin);
      return text(JSON.stringify({
        path: out,
        seconds: Number(seconds.toFixed(2)),
        frames: rec.frames.length,
        bytes: fs.statSync(out).size,
        ...(rec.truncated &&
            { truncated: `capture stopped at the ${REC_MAX_FRAMES}-frame cap` }),
      }, null, 2));
    } finally {
      fs.rmSync(rec.dir, { recursive: true, force: true });
    }
  });

tool("browser_snapshot",
  "Accessibility-tree snapshot (aria) of the session's page — the fast, " +
  "text-sized way to read page structure. Every element carries a [ref=…] you can " +
  "hand straight to browser_click, browser_type, browser_hover, browser_select_option " +
  "and the rest, so you never have to guess a selector from source. Refs belong to " +
  "the snapshot that issued them: after a re-render or a navigation they expire and " +
  "say so — take a fresh snapshot rather than reusing old ones. " +
  "A whole listing page runs to hundreds of thousands of characters, so scope it: " +
  "selector for a region, maxDepth for shape without leaf detail.",
  {
    sessionId: sessionIdParam,
    selector: z.string().optional().describe(
      "CSS selector of the region to snapshot (default body); the first match is used"),
    maxDepth: z.number().int().positive().optional().describe(
      "keep only the top N levels of the tree — the fastest way to shrink a huge page"),
  },
  async ({ sessionId, selector = "body", maxDepth }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const target = page.locator(selector).first();
    if (await target.count() === 0) {
      throw new Error(`no element matches ${selector} on ${page.url()}`);
    }
    // mode "ai": refs on every element, and <iframe> contents inlined (their refs
    // carry the frame, so they resolve through it too).
    const snap = await target.ariaSnapshot({
      mode: "ai", timeout: 10000, ...(maxDepth && { depth: maxDepth }),
    });
    const scope = selector === "body" ? "" : ` (${selector})`;
    return text(`${page.url()}${scope} — "${await page.title()}"\n\n${snap}`);
  });

tool("browser_cookies",
  "Read or set the session's cookies. Setting is how you transplant an existing " +
  "authenticated session into the browser — an HttpOnly cookie obtained out of band " +
  "(curl, a handoff endpoint) that JavaScript cannot write. Returns the cookies " +
  "visible to the page afterwards.",
  {
    sessionId: sessionIdParam,
    set: z.array(z.object({
      name: z.string(),
      value: z.string(),
      url: z.string().optional().describe("cookie's URL (defaults to the page's)"),
      domain: z.string().optional(),
      path: z.string().optional(),
      secure: z.boolean().optional(),
      httpOnly: z.boolean().optional(),
      sameSite: z.enum(["Strict", "Lax", "None"]).optional(),
      expires: z.number().optional().describe("expiry as a UNIX timestamp in seconds"),
    })).optional().describe("cookies to set before reading back"),
    urls: z.array(z.string()).optional().describe(
      "read cookies for these URLs instead of the page's own frames"),
  },
  async ({ sessionId, set, urls }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const client = await page.context().newCDPSession(page);
    try {
      if (set?.length) {
        await client.send("Network.setCookies", {
          cookies: set.map((c) => ({ url: page.url(), ...c })),
        });
      }
      const { cookies } = await client.send("Network.getCookies",
                                            urls?.length ? { urls } : {});
      return text(JSON.stringify(cookies, null, 2));
    } finally {
      await client.detach().catch(() => {});
    }
  });

tool("browser_health",
  "State of Synth's browser engine when the tools misbehave: how many CDP targets it " +
  "hosts across ALL worktrees and agents (attach cost scales with that number, so it " +
  "explains slow or timing-out calls that have nothing to do with your own pages), and " +
  "which of this worktree's sessions still answer. Run this before concluding a page is " +
  "wedged, and instead of probing the engine by hand. reconnect:true drops the cached " +
  "CDP connection and dials again — the recovery step when the engine has gone bad.",
  {
    reconnect: z.boolean().optional().describe(
      "drop the cached CDP connection and attach fresh before reporting"),
  },
  async ({ reconnect }) => {
    const inst = requireInstance();
    if (reconnect && cdp) { retire(cdp.browser); cdp = null; }
    const targets = await cdpTargets(inst);
    const mine = await worktreeSessions();
    const report = {
      cdpPort: inst.cdpPort ?? null,
      engineTargets: targets?.length ?? "unreachable (/json/list did not answer)",
      attachBudget: `${attachBudget(targets?.length ?? 0) / 1000}s`,
    };
    let pages = [];
    try { pages = await sessionPages(inst); }
    catch (e) { report.attach = `failed: ${e.message}`; }
    if (pages.length > 0) {
      report.connection = cdp
        ? { attachMs: cdp.attachMs, ageSeconds: Math.round((Date.now() - cdp.at) / 1000),
            targetsAtAttach: cdp.targetsAtAttach }
        : null;
      report.pagesVisible = pages.length;
      const byId = new Map(pages.filter((p) => p.sessionId).map((p) => [p.sessionId, p.page]));
      report.sessions = await Promise.all(mine.map(async (s) => {
        const page = byId.get(s.sessionId);
        if (!page) return { sessionId: s.sessionId, title: s.title, live: false,
                            note: "no CDP target — the row has no usable page" };
        const started = Date.now();
        try {
          await evalWithTimeout(page, "1", 3000);
          return { sessionId: s.sessionId, url: page.url(), responsive: true,
                   respondedInMs: Date.now() - started };
        } catch {
          return { sessionId: s.sessionId, url: page.url(), responsive: false,
                   note: "did not answer a trivial evaluate within 3s — this page is stuck" };
        }
      }));
      const others = (targets?.length ?? 0) - pages.filter((p) => p.sessionId &&
        mine.some((s) => s.sessionId === p.sessionId)).length;
      if (others > 0) {
        report.otherTargets =
          `${others} target(s) belong to other worktrees, other agents, or the user. ` +
          "They are not yours to close, but they are what your attaches wait for.";
      }
    }
    return text(JSON.stringify(report, null, 2));
  });

tool("browser_console",
  "Recent console messages (including errors) from the session's page.",
  { sessionId: sessionIdParam },
  async ({ sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const live = pageLogs.get(page) ?? [];
    if (live.length > 0) return text(live.map((l) => `[${l.level}] ${l.text}`).join("\n"));
    // Nothing seen live — the messages predate this server's attach. A fresh
    // Runtime.enable on a raw CDP session makes the browser replay its buffer.
    const replayed = await replayConsole(page);
    if (replayed.length === 0) return text("no console messages captured");
    return text(replayed.map((l) => `[${l.level}] ${l.text}`).join("\n"));
  });

async function replayConsole(page) {
  const logs = [];
  const session = await page.context().newCDPSession(page);
  try {
    session.on("Runtime.consoleAPICalled", (e) => {
      const parts = (e.args ?? []).map((a) =>
        a.value !== undefined ? String(a.value) : (a.description ?? a.type));
      logs.push({ level: e.type, text: parts.join(" ") });
    });
    session.on("Runtime.exceptionThrown", (e) => {
      logs.push({ level: "error",
                  text: e.exceptionDetails?.exception?.description
                        ?? e.exceptionDetails?.text ?? "uncaught exception" });
    });
    await session.send("Runtime.enable");
    await new Promise((r) => setTimeout(r, 1200));   // replay arrives async
  } finally {
    await session.detach().catch(() => {});
  }
  return logs;
}

tool("browser_evaluate",
  "Evaluate a JavaScript expression in the session's page; returns the " +
  "JSON-serialized result.",
  {
    expression: z.string().describe("JS expression, e.g. document.title"),
    sessionId: sessionIdParam,
  },
  async ({ expression, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const result = await page.evaluate(expression);
    let rendered;
    try { rendered = JSON.stringify(result, null, 2) ?? "undefined"; }
    catch { rendered = String(result); }
    return text(rendered);
  });

// Release every persistent handle on parent death: any viewport override (whose CDP
// session is what holds it), any un-stopped recording (stop its screencast, detach its
// CDP session, drop its frame dir — otherwise it strands a temp dir of up to
// REC_MAX_FRAMES JPEGs) and the cached CDP browser (the open websocket that would
// otherwise keep us alive indefinitely).
async function shutdownCleanup() {
  for (const sid of [...viewports.keys()]) await clearViewport(sid);
  for (const rec of recordings.values()) {
    try { await rec.cdp.send("Page.stopScreencast"); } catch { /* already gone */ }
    try { await rec.cdp.detach(); } catch { /* already gone */ }
    try { fs.rmSync(rec.dir, { recursive: true, force: true }); } catch { /* already gone */ }
  }
  recordings.clear();
  if (cdp) { try { await cdp.browser.close(); } catch { /* already gone */ } cdp = null; }
}

await server.connect(new StdioServerTransport());
exitWithParent(shutdownCleanup);
