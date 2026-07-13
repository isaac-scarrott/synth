// Shared plumbing for Synth's bundled MCP servers (synth-browser, synth-app):
// instance discovery, worktree scoping, and the app's control socket. Each server
// is its own stdio process; this module is how they agree on what "this worktree's
// Synth" means.

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

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

export function liveInstances() {
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

export const projectDir =
  process.env.SYNTH_WORKTREE || process.env.CLAUDE_PROJECT_DIR || process.cwd();

/** The managed worktree this server is scoped to: an exact worktreePaths match,
 *  else the DEEPEST managed ancestor (agents run in nested `.worktree/<slice>`
 *  checkouts inside a managed root — their sessions belong to the enclosing row).
 *  null when nothing manages the project dir. */
export function resolveScope() {
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

export function requireScope() {
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
export function findInstance() {
  const scope = resolveScope();
  if (scope) return scope.inst;
  return liveInstances().sort((a, b) =>
    String(b.createdAt).localeCompare(String(a.createdAt)))[0] ?? null;
}

export function requireInstance() {
  const inst = findInstance();
  if (!inst) {
    throw new Error(
      "Synth isn't running — no live Synth instance found, so it cannot act " +
      `for this worktree (${projectDir}). Launch Synth first.`);
  }
  return inst;
}

// ---------------------------------------------------------------------------
// Control socket — the app's own verbs (it owns the session and worktree model);
// one JSON line request, one JSON line response. `timeoutMs` exists for verbs
// that legitimately wait on the user (the app-server's approval prompts).

export function controlCall(inst, request, { timeoutMs = 10000 } = {}) {
  const socketPath = inst.controlSocket || `/tmp/synth-ctl-${inst.pid}.sock`;
  return new Promise((resolve, reject) => {
    const sock = net.connect(socketPath);
    let buf = "";
    const fail = (msg) => { sock.destroy(); reject(new Error(msg)); };
    sock.setTimeout(timeoutMs, () => fail("Synth control socket timed out"));
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
// Tool plumbing.

/** One heavy result must not blow a Claude session's context: a 30k-element page
 *  snapshots to ~1.5M chars (~400K tokens) uncapped. */
const MAX_TEXT = 40_000;
export const text = (s) => {
  const str = String(s);
  if (str.length <= MAX_TEXT) return { content: [{ type: "text", text: str }] };
  return { content: [{ type: "text", text:
    str.slice(0, MAX_TEXT) +
    `\n…[truncated ${str.length - MAX_TEXT} of ${str.length} chars — narrow the query: ` +
    "a tighter selector/expression, or evaluate over a page region]" }] };
};

const stripAnsi = (s) => String(s).replace(/\x1b\[[0-9;]*m/g, "");

/** Per-server `tool(name, description, inputSchema, handler)` that renders any
 *  thrown error as an isError text result instead of a protocol failure. */
export function makeTool(server) {
  return (name, description, inputSchema, handler) => {
    server.registerTool(name, { description, ...(inputSchema && { inputSchema }) },
      async (args) => {
        try { return await handler(args ?? {}); }
        catch (e) {
          return { content: [{ type: "text", text: `Error: ${stripAnsi(e.message)}` }], isError: true };
        }
      });
  };
}
