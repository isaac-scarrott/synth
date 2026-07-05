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

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
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

/** The Synth instance whose worktreePaths contain the project dir, else the
 *  newest live instance, else null. */
function findInstance() {
  const instances = liveInstances();
  const target = realpathOr(projectDir);
  const managing = instances.find((i) =>
    (i.worktreePaths || []).some((p) => realpathOr(p) === target));
  if (managing) return managing;
  return instances.sort((a, b) =>
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

let cdp = null; // { browser, port }

async function connectedBrowser(inst) {
  if (!inst.cdpPort) {
    throw new Error(
      "Synth is running but its browser engine isn't up yet (no CDP port). " +
      "Create a browser session first (browser_create).");
  }
  if (cdp && cdp.port === inst.cdpPort && cdp.browser.isConnected()) return cdp.browser;
  if (cdp) { try { await cdp.browser.close(); } catch { /* already gone */ } cdp = null; }
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

let focusedSessionId = null;

/** The page subsequent tools act on: the focused session's target, defaulting to
 *  the most recently created mapped target. */
async function focusedPage(inst) {
  const pages = await sessionPages(inst);
  const mapped = pages.filter((p) => p.sessionId);
  if (mapped.length === 0) {
    throw new Error("no Synth browser sessions are open — create one with browser_create");
  }
  const hit = focusedSessionId && mapped.find((p) => p.sessionId === focusedSessionId);
  const chosen = hit || mapped[mapped.length - 1];
  focusedSessionId = chosen.sessionId;
  return chosen.page;
}

// ---------------------------------------------------------------------------
// Helpers.

/** working.html's browserNorm: schemeless input gets https://, loopback gets http://. */
function normalizeURL(text) {
  const t = text.trim();
  if (t.includes("://")) return t;
  if (/^(localhost|127\.|\[::1\]|0\.0\.0\.0)/.test(t)) return `http://${t}`;
  return `https://${t}`;
}

/** Post-action settle: wait for a load if the action triggered one, silently move
 *  on if it didn't (or the page navigated via history — CEF fires no
 *  domcontentloaded for those, the spike's lesson). */
async function settle(page, ms = 3000) {
  await page.waitForLoadState("load", { timeout: ms }).catch(() => {});
}

const text = (s) => ({ content: [{ type: "text", text: s }] });

function tool(name, description, inputSchema, handler) {
  server.registerTool(name, { description, ...(inputSchema && { inputSchema }) },
    async (args) => {
      try { return await handler(args ?? {}); }
      catch (e) {
        return { content: [{ type: "text", text: `Error: ${e.message}` }], isError: true };
      }
    });
}

// ---------------------------------------------------------------------------
// Server + tools.

const server = new McpServer({ name: "synth-browser", version: "0.1.0" });

tool("browser_list",
  "List this worktree's Synth browser sessions (sessionId, title, url, branch).",
  null,
  async () => {
    const inst = requireInstance();
    const res = await controlCall(inst, { verb: "browser.list", worktreePath: projectDir });
    return text(JSON.stringify(res.sessions, null, 2));
  });

tool("browser_create",
  "Create a new Synth browser session in this worktree's branch (visible in the " +
  "sidebar, selected), optionally pre-navigated to a URL. Focuses the new session.",
  { url: z.string().optional().describe("URL to open (scheme optional)") },
  async ({ url }) => {
    const inst = requireInstance();
    const res = await controlCall(inst, {
      verb: "browser.create", worktreePath: projectDir,
      ...(url && { url: normalizeURL(url) }),
    });
    focusedSessionId = res.sessionId;
    // The engine (and, first time, the whole CDP endpoint) spins up async — wait
    // for the session's page target, re-reading the instance file for the port.
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      try {
        const pages = await sessionPages(requireInstance());
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
  "Select which browser session subsequent tools act on.",
  { sessionId: z.string().describe("a sessionId from browser_list") },
  async ({ sessionId }) => {
    const pages = await sessionPages(requireInstance());
    if (!pages.some((p) => p.sessionId === sessionId)) {
      throw new Error(`no live browser session ${sessionId} — see browser_list`);
    }
    focusedSessionId = sessionId;
    return text(`focused ${sessionId}`);
  });

tool("browser_navigate",
  "Navigate the focused browser session to a URL.",
  { url: z.string().describe("destination (scheme optional; localhost gets http)") },
  async ({ url }) => {
    const page = await focusedPage(requireInstance());
    await page.goto(normalizeURL(url), { waitUntil: "load", timeout: 20000 });
    return text(`now at ${page.url()} — "${await page.title()}"`);
  });

// History navs in CEF fire no domcontentloaded (the spike's lesson) — wait for
// commit, then settle. Success is judged by the URL, not the return value:
// Playwright yields null for a history nav that produced no network response.
async function historyNav(go) {
  const page = await focusedPage(requireInstance());
  const before = page.url();
  await go(page, { waitUntil: "commit", timeout: 10000 });
  await settle(page);
  return { page, moved: page.url() !== before };
}

tool("browser_back", "Go back in the focused session's history.", null, async () => {
  const { page, moved } = await historyNav((p, o) => p.goBack(o));
  return text(moved ? `now at ${page.url()}` : "nothing to go back to");
});

tool("browser_forward", "Go forward in the focused session's history.", null, async () => {
  const { page, moved } = await historyNav((p, o) => p.goForward(o));
  return text(moved ? `now at ${page.url()}` : "nothing to go forward to");
});

tool("browser_reload", "Reload the focused session's page.", null, async () => {
  const page = await focusedPage(requireInstance());
  await page.reload({ waitUntil: "load", timeout: 20000 });
  return text(`reloaded ${page.url()}`);
});

tool("browser_click",
  "Click in the focused session's page: a CSS selector, or viewport coordinates.",
  {
    selector: z.string().optional().describe("CSS selector to click"),
    x: z.number().optional().describe("viewport x (used with y when no selector)"),
    y: z.number().optional().describe("viewport y"),
  },
  async ({ selector, x, y }) => {
    const page = await focusedPage(requireInstance());
    if (selector) await page.click(selector, { timeout: 5000 });
    else if (x != null && y != null) await page.mouse.click(x, y);
    else throw new Error("pass selector, or both x and y");
    await settle(page);
    return text(`clicked ${selector ?? `(${x}, ${y})`} — now at ${page.url()}`);
  });

tool("browser_type",
  "Type text into the focused session's page — into a selector (replacing its value) " +
  "or the currently focused element; optionally press Enter after.",
  {
    text: z.string().describe("text to type"),
    selector: z.string().optional().describe("CSS selector of the input (typed at the focused element when omitted)"),
    submit: z.boolean().optional().describe("press Enter afterwards"),
  },
  async ({ text: value, selector, submit }) => {
    const page = await focusedPage(requireInstance());
    if (selector) await page.fill(selector, value, { timeout: 5000 });
    else await page.keyboard.type(value);
    if (submit) await page.keyboard.press("Enter");
    await settle(page);
    return text(`typed into ${selector ?? "focused element"}${submit ? " and submitted" : ""}`);
  });

tool("browser_screenshot",
  "Screenshot the focused session's viewport (PNG).", null,
  async () => {
    const page = await focusedPage(requireInstance());
    const buf = await page.screenshot({ type: "png", timeout: 10000 });
    return {
      content: [{ type: "image", data: buf.toString("base64"), mimeType: "image/png" }],
    };
  });

tool("browser_snapshot",
  "Accessibility-tree snapshot (aria) of the focused session's page — the fast, " +
  "text-sized way to read page structure.", null,
  async () => {
    const page = await focusedPage(requireInstance());
    const snap = await page.locator("body").ariaSnapshot({ timeout: 10000 });
    return text(`${page.url()} — "${await page.title()}"\n\n${snap}`);
  });

tool("browser_console",
  "Recent console messages (including errors) from the focused session's page.", null,
  async () => {
    const page = await focusedPage(requireInstance());
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
  "Evaluate a JavaScript expression in the focused session's page; returns the " +
  "JSON-serialized result.",
  { expression: z.string().describe("JS expression, e.g. document.title") },
  async ({ expression }) => {
    const page = await focusedPage(requireInstance());
    const result = await page.evaluate(expression);
    let rendered;
    try { rendered = JSON.stringify(result, null, 2) ?? "undefined"; }
    catch { rendered = String(result); }
    return text(rendered);
  });

await server.connect(new StdioServerTransport());
