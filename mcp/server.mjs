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
// share the parent's MCP connections, and calls carry no caller identity). So the
// "focused session" is a single process-wide pointer — concurrent agents would
// fight over it. Every action tool therefore takes an optional sessionId that
// targets a session directly; focus is only a single-agent convenience.

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
import { controlCall, makeTool, projectDir, requireInstance, requireScope,
         text } from "./shared.mjs";

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

/** The { page, sessionId } subsequent tools act on: the focused session's target,
 *  defaulting to the most recently created mapped target only when nothing was
 *  ever focused. A vanished focus is an ERROR, not a silent retarget — acting on
 *  whatever page happens to be newest is how an agent wrecks the wrong session. */
async function focusedEntry(inst) {
  const pages = await sessionPagesSeeking(inst,
    focusedSessionId ? (p) => p.sessionId === focusedSessionId : (p) => p.sessionId);
  const mapped = pages.filter((p) => p.sessionId);
  if (mapped.length === 0) {
    throw new Error("no Synth browser sessions are open — create one with browser_create");
  }
  if (focusedSessionId) {
    const hit = mapped.find((p) => p.sessionId === focusedSessionId);
    if (hit) return hit;
    const gone = focusedSessionId;
    focusedSessionId = null;
    throw new Error(
      `the focused browser session (${gone}) is gone — deleted or closed. ` +
      "Call browser_list, then browser_focus (or browser_create) to pick a target.");
  }
  const chosen = mapped[mapped.length - 1];
  focusedSessionId = chosen.sessionId;
  return chosen;
}

/** The { page, sessionId } a tool acts on: the explicitly named session, else the
 *  focused one. Explicit targeting does NOT move the focus — that's what keeps
 *  concurrent agents out of each other's sessions. */
async function targetEntry(inst, sessionId) {
  if (!sessionId) return focusedEntry(inst);
  const pages = await sessionPagesSeeking(inst, (p) => p.sessionId === sessionId);
  const hit = pages.find((p) => p.sessionId === sessionId);
  if (!hit) throw new Error(`no live browser session ${sessionId} — see browser_list`);
  return hit;
}

async function targetPage(inst, sessionId) {
  return (await targetEntry(inst, sessionId)).page;
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

// ---------------------------------------------------------------------------
// Server + tools.

const server = new McpServer({ name: "synth-browser", version: "0.1.0" });
const tool = makeTool(server);

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
  "on every subsequent tool call if other agents may be driving browsers too. " +
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
    await controlCall(scope.inst, {
      verb: "browser.close", worktreePath: scope.path, sessionId,
      ...(process.env.SYNTH_SESSION_ID &&
          { ownerSessionId: process.env.SYNTH_SESSION_ID }),
    });
    if (focusedSessionId === sessionId) focusedSessionId = null;
    return text(`closed ${sessionId}`);
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
  async ({ path: outPath, sessionId }) => {
    let sid = sessionId ?? focusedSessionId;
    if (!sid && recordings.size === 1) sid = recordings.keys().next().value;
    const rec = sid ? recordings.get(sid) : null;
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
