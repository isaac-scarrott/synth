// Synth's browser MCP server (ADR-0011 stage two, stdio).
//
// Claude Code drives the embedded CEF browser of the Synth instance that manages
// $CLAUDE_PROJECT_DIR. Discovery: each running Synth writes
// ~/Library/Application Support/Synth/instances/<pid>.json (pid, cdpPort, createdAt,
// worktreePaths, controlSocket). Session list/create go through the app's control
// socket (the app owns the session model); everything else is CDP via Playwright's
// connectOverCDP. The CDP endpoint is per app instance; each Synth browser session
// is a page target, mapped back to its session by window.__synthSessionId (stamped
// by the app's CEF shim on every main-frame load end).
//
// One server process serves a whole Claude session INCLUDING its sub-agents (they
// share the parent's MCP connections, and calls carry no caller identity). So the
// "focused session" is a single process-wide pointer — concurrent agents would
// fight over it. Every action tool therefore takes an optional sessionId that
// targets a session directly; focus is only a single-agent convenience.

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { chromium } from "playwright-core";
import { z } from "zod";

const INSTANCES_DIR = path.join(
  os.homedir(), "Library/Application Support/Synth/instances");

// ---------------------------------------------------------------------------
// Instance discovery — re-read on every tool call so a Synth launched (or quit)
// after this server started is picked up without a restart.

function realpathOr(p) {
  try { return fs.realpathSync(p); } catch { return p; }
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (e) { return e.code === "EPERM"; }
}

function liveInstances() {
  let entries;
  try { entries = fs.readdirSync(INSTANCES_DIR); } catch { return []; }
  const out = [];
  for (const name of entries) {
    if (!name.endsWith(".json")) continue;
    try {
      const inst = JSON.parse(fs.readFileSync(path.join(INSTANCES_DIR, name), "utf8"));
      if (Number.isInteger(inst.pid) && pidAlive(inst.pid)) out.push(inst);
    } catch { /* torn write or garbage — skip */ }
  }
  return out;
}

const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();

/** The managed worktree this server is scoped to: an exact worktreePaths match,
 *  else the DEEPEST managed ancestor (agents run in nested `.worktree/<slice>`
 *  checkouts inside a managed root — their browsers belong to the enclosing row).
 *  null when nothing manages the project dir. */
function resolveScope() {
  const target = realpathOr(projectDir);
  let best = null; // { inst, path, exact }
  for (const inst of liveInstances()) {
    for (const p of inst.worktreePaths || []) {
      const rp = realpathOr(p);
      if (rp === target) return { inst, path: p, exact: true };
      if ((target + "/").startsWith(rp + "/") &&
          (!best || rp.length > realpathOr(best.path).length)) {
        best = { inst, path: p, exact: false };
      }
    }
  }
  return best;
}

function requireScope() {
  const scope = resolveScope();
  if (!scope) {
    requireInstance(); // no Synth at all → that error is the clearer one
    throw new Error(
      `no Synth branch manages this worktree (${projectDir}) or any parent of it — ` +
      "adopt it in Synth via ⌘K → \"New worktree\" (it reuses an existing checkout), then retry.");
  }
  return scope;
}

/** The Synth instance scoped to the project dir, else the newest live instance,
 *  else null. */
function findInstance() {
  const scope = resolveScope();
  if (scope) return scope.inst;
  return liveInstances().sort((a, b) =>
    String(b.createdAt).localeCompare(String(a.createdAt)))[0] ?? null;
}

function requireInstance() {
  const inst = findInstance();
  if (!inst) {
    throw new Error(
      "Synth isn't running — no live Synth instance found, so there is no " +
      `browser for this worktree (${projectDir}). Launch Synth first.`);
  }
  return inst;
}

// ---------------------------------------------------------------------------
// Control socket — browser.list / browser.create are the app's verbs (it owns
// the session model); one JSON line request, one JSON line response.

function controlCall(inst, request) {
  const socketPath = inst.controlSocket || `/tmp/synth-ctl-${inst.pid}.sock`;
  return new Promise((resolve, reject) => {
    const sock = net.connect(socketPath);
    let buf = "";
    const fail = (msg) => { sock.destroy(); reject(new Error(msg)); };
    sock.setTimeout(10000, () => fail("Synth control socket timed out"));
    sock.on("error", (e) =>
      reject(new Error(`Synth control socket unreachable (${e.code || e.message}) — ` +
                       "is the Synth app still running?")));
    sock.on("data", (d) => {
      buf += d;
      const nl = buf.indexOf("\n");
      if (nl < 0) return;
      sock.end();
      try {
        const res = JSON.parse(buf.slice(0, nl));
        if (res.ok) resolve(res);
        else reject(new Error(res.error || "Synth rejected the request"));
      } catch { reject(new Error("unparseable response from Synth control socket")); }
    });
    sock.on("connect", () => sock.write(JSON.stringify(request) + "\n"));
  });
}

// ---------------------------------------------------------------------------
// CDP connection — lazy, reconnect on drop or port change.

let cdp = null;        // { browser, port }
let connecting = null; // { port, promise } — racing callers share one dial

/** Close a superseded connection only after any in-flight op on it is done
 *  (longest tool timeout is 20s) — closing immediately is how one agent's
 *  reconnect kills another agent's screenshot mid-flight. */
function retire(browser) {
  setTimeout(() => browser.close().catch(() => {}), 30_000).unref?.();
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
    const browser = await chromium.connectOverCDP(
      `http://127.0.0.1:${inst.cdpPort}`, { timeout: 10000 });
    browser.on("disconnected", () => { if (cdp && cdp.browser === browser) cdp = null; });
    cdp = { browser, port: inst.cdpPort };
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
// Page ↔ session mapping + per-page console capture.

const pageLogs = new WeakMap();    // Page -> [{ level, text, at }]
const instrumented = new WeakSet();
const CONSOLE_CAP = 200;

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
}

async function evalWithTimeout(page, expression, ms) {
  return Promise.race([
    page.evaluate(expression),
    new Promise((_, rej) => setTimeout(() => rej(new Error("evaluate timed out")), ms)),
  ]);
}

/** All Synth session pages on the endpoint: [{ page, sessionId }]. */
async function sessionPages(inst) {
  const browser = await connectedBrowser(inst);
  const out = [];
  for (const context of browser.contexts()) {
    for (const page of context.pages()) {
      const url = page.url();
      if (url.startsWith("devtools://") || url.startsWith("chrome://")) continue;
      instrument(page);
      let sessionId = null;
      try {
        sessionId = await evalWithTimeout(page, "window.__synthSessionId || null", 2000);
      } catch { /* mid-navigation or crashed — leave unmapped */ }
      out.push({ page, sessionId });
    }
  }
  return out;
}

/** sessionPages, retried once on a fresh connection when `want` finds no match —
 *  CEF's CDP endpoint emits no attach events for targets created after a client
 *  connected, so a page opened since then is invisible until we reconnect. */
async function sessionPagesSeeking(inst, want) {
  let pages = await sessionPages(inst);
  if (!pages.some(want)) {
    if (cdp) { retire(cdp.browser); cdp = null; }
    pages = await sessionPages(inst);
  }
  return pages;
}

let focusedSessionId = null;

/** The page subsequent tools act on: the focused session's target, defaulting to
 *  the most recently created mapped target only when nothing was ever focused.
 *  A vanished focus is an ERROR, not a silent retarget — acting on whatever page
 *  happens to be newest is how an agent wrecks the wrong session. */
async function focusedPage(inst) {
  const pages = await sessionPagesSeeking(inst,
    focusedSessionId ? (p) => p.sessionId === focusedSessionId : (p) => p.sessionId);
  const mapped = pages.filter((p) => p.sessionId);
  if (mapped.length === 0) {
    throw new Error("no Synth browser sessions are open — create one with browser_create");
  }
  if (focusedSessionId) {
    const hit = mapped.find((p) => p.sessionId === focusedSessionId);
    if (hit) return hit.page;
    const gone = focusedSessionId;
    focusedSessionId = null;
    throw new Error(
      `the focused browser session (${gone}) is gone — deleted or closed. ` +
      "Call browser_list, then browser_focus (or browser_create) to pick a target.");
  }
  const chosen = mapped[mapped.length - 1];
  focusedSessionId = chosen.sessionId;
  return chosen.page;
}

/** The page a tool acts on: the explicitly named session, else the focused one.
 *  Explicit targeting does NOT move the focus — that's what keeps concurrent
 *  agents out of each other's sessions. */
async function targetPage(inst, sessionId) {
  if (!sessionId) return focusedPage(inst);
  const pages = await sessionPagesSeeking(inst, (p) => p.sessionId === sessionId);
  const hit = pages.find((p) => p.sessionId === sessionId);
  if (!hit) throw new Error(`no live browser session ${sessionId} — see browser_list`);
  return hit.page;
}

const sessionIdParam = z.string().optional().describe(
  "session to act on (from browser_create/browser_list); overrides the focused " +
  "session without moving the focus. ALWAYS pass this when running as one of " +
  "several agents (sub-agents share this server, and the focus is a single " +
  "process-wide pointer — last create/focus wins)");

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

/** One heavy page must not blow a Claude session's context: a 30k-element page
 *  snapshots to ~1.5M chars (~400K tokens) uncapped. */
const MAX_TEXT = 40_000;
const text = (s) => {
  const str = String(s);
  if (str.length <= MAX_TEXT) return { content: [{ type: "text", text: str }] };
  return { content: [{ type: "text", text:
    str.slice(0, MAX_TEXT) +
    `\n…[truncated ${str.length - MAX_TEXT} of ${str.length} chars — narrow the query: ` +
    "a tighter selector/expression, or evaluate over a page region]" }] };
};

const stripAnsi = (s) => String(s).replace(/\x1b\[[0-9;]*m/g, "");

function tool(name, description, inputSchema, handler) {
  server.registerTool(name, { description, ...(inputSchema && { inputSchema }) },
    async (args) => {
      try { return await handler(args ?? {}); }
      catch (e) {
        return { content: [{ type: "text", text: `Error: ${stripAnsi(e.message)}` }], isError: true };
      }
    });
}

// ---------------------------------------------------------------------------
// Server + tools.

const server = new McpServer({ name: "synth-browser", version: "0.1.0" });

tool("browser_list",
  "List this worktree's Synth browser sessions (sessionId, title, url, branch; " +
  "owned sessions carry an owner field — the Synth session UUID of the owning claude).",
  null,
  async () => {
    const scope = requireScope();
    const res = await controlCall(scope.inst, { verb: "browser.list", worktreePath: scope.path });
    const note = scope.exact ? "" : `\n(scoped to enclosing managed worktree ${scope.path})`;
    return text(JSON.stringify(res.sessions, null, 2) + note);
  });

tool("browser_create",
  "Create a new Synth browser session in this worktree's branch (visible in the " +
  "sidebar, selected), optionally pre-navigated to a URL. Focuses the new session. " +
  "The browser belongs to this Claude session — user comments made in it are routed " +
  "back to this session. Returns the sessionId: keep it, and pass it as sessionId " +
  "on every subsequent tool call if other agents may be driving browsers too.",
  { url: z.string().optional().describe("URL to open (scheme optional)") },
  async ({ url }) => {
    const scope = requireScope();
    const res = await controlCall(scope.inst, {
      verb: "browser.create", worktreePath: scope.path,
      ...(url && { url: normalizeURL(url) }),
      ...(process.env.SYNTH_SESSION_ID &&
          { ownerSessionId: process.env.SYNTH_SESSION_ID }),
    });
    focusedSessionId = res.sessionId;
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
    return text(JSON.stringify({
      sessionId: res.sessionId,
      warning: "session created but its CDP target never appeared within 15s",
    }));
  });

tool("browser_focus",
  "Select which browser session subsequent tools act on by default. The focus is " +
  "one pointer for the whole Claude session (sub-agents included) — with several " +
  "agents active, skip this and pass sessionId per call instead.",
  { sessionId: z.string().describe("a sessionId from browser_list") },
  async ({ sessionId }) => {
    const pages = await sessionPagesSeeking(
      requireInstance(), (p) => p.sessionId === sessionId);
    if (!pages.some((p) => p.sessionId === sessionId)) {
      throw new Error(`no live browser session ${sessionId} — see browser_list`);
    }
    focusedSessionId = sessionId;
    return text(`focused ${sessionId}`);
  });

tool("browser_navigate",
  "Navigate a browser session to a URL (the focused session unless sessionId names one).",
  {
    url: z.string().describe("destination (scheme optional; localhost gets http)"),
    sessionId: sessionIdParam,
  },
  async ({ url, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    await page.goto(normalizeURL(url), { waitUntil: "load", timeout: 20000 });
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
  { sessionId: sessionIdParam },
  async ({ sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    await page.reload({ waitUntil: "load", timeout: 20000 });
    return text(`reloaded ${page.url()}`);
  });

tool("browser_click",
  "Click in the session's page: a CSS selector, or viewport coordinates.",
  {
    selector: z.string().optional().describe("CSS selector to click"),
    x: z.number().optional().describe("viewport x (used with y when no selector)"),
    y: z.number().optional().describe("viewport y"),
    sessionId: sessionIdParam,
  },
  async ({ selector, x, y, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    if (selector) await page.click(selector, { timeout: 5000 });
    else if (x != null && y != null) await page.mouse.click(x, y);
    else throw new Error("pass selector, or both x and y");
    await settle(page);
    return text(`clicked ${selector ?? `(${x}, ${y})`} — now at ${page.url()}`);
  });

tool("browser_type",
  "Type text into the session's page — into a selector (replacing its value) " +
  "or the currently focused element; optionally press Enter after.",
  {
    text: z.string().describe("text to type"),
    selector: z.string().optional().describe("CSS selector of the input (typed at the focused element when omitted)"),
    submit: z.boolean().optional().describe("press Enter afterwards"),
    sessionId: sessionIdParam,
  },
  async ({ text: value, selector, submit, sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    if (selector) await page.fill(selector, value, { timeout: 5000 });
    else await page.keyboard.type(value);
    if (submit) await page.keyboard.press("Enter");
    await settle(page);
    return text(`typed into ${selector ?? "focused element"}${submit ? " and submitted" : ""}`);
  });

tool("browser_screenshot",
  "Screenshot the session's viewport (PNG).",
  { sessionId: sessionIdParam },
  async ({ sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const buf = await page.screenshot({ type: "png", timeout: 10000 });
    return {
      content: [{ type: "image", data: buf.toString("base64"), mimeType: "image/png" }],
    };
  });

tool("browser_snapshot",
  "Accessibility-tree snapshot (aria) of the session's page — the fast, " +
  "text-sized way to read page structure.",
  { sessionId: sessionIdParam },
  async ({ sessionId }) => {
    const page = await targetPage(requireInstance(), sessionId);
    const snap = await page.locator("body").ariaSnapshot({ timeout: 10000 });
    return text(`${page.url()} — "${await page.title()}"\n\n${snap}`);
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

await server.connect(new StdioServerTransport());
