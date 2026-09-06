"""OpenCode 2 lifecycle gate.

v2 restructured opencode's whole transport — two processes instead of one, HTTP Basic auth instead
of none, MCP servers registered over an API call instead of an env var (docs/features/2026-09-06.md
has the full why). None of that is opencode2-specific plumbing worth trusting on the strength of a
design doc, so this proves it end to end against a real running Synth:

  - a row goes live, delivers text (a plain terminal paste — v2 exposes no equivalent of v1's
    `/tui/append-prompt`), works, idles, and is named,
  - exactly one `serve` and one TUI process exist for it, and Synth's bundled MCP servers are
    actually connected in the live session (the payload `synth-hook` PUTs in, not merely sent),
  - quitting the TUI (the process a Ctrl-C would reach) reaps its backing `serve` too — the one
    failure mode v1 never had, since v1 is a single process — and the row parks its conversation on
    a Reopen card rather than dropping it, exactly as any other agent's clean exit does,
  - the reopened row is truly the same conversation (its id survives, and the relaunch carries
    `--session <id>`), not a fresh one wearing the old id.
"""
import base64, json as _j, os, signal, sys, urllib.request
sys.path.insert(0, ".")
from lib import *

print("=== T34: OpenCode 2 lifecycle, process shape, MCP registration, quit + resume ===")


def opencode2_binary():
    native = os.path.expanduser("~/.opencode/bin/opencode2")
    return native if os.path.isfile(native) and os.access(native, os.X_OK) else ""


if not opencode2_binary():
    skip("no `opencode2` CLI at ~/.opencode/bin (only Synth's shim resolves)")

kill_all()
repo = fresh_repo()
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t34.log")
ctl = Ctl(sock, repo)


def serve_pids():
    out = sh("ps -eo pid=,command= | grep 'opencode2 serve --port' | grep -v grep") or ""
    return {int(l.split()[0]) for l in out.splitlines() if l.strip()}


def tui_cmd():
    return sh("ps -eo command= | grep 'opencode2 --server' | grep -v grep") or None


def tui_pids():
    out = sh("ps -eo pid=,command= | grep 'opencode2 --server' | grep -v grep") or ""
    return {int(l.split()[0]) for l in out.splitlines() if l.strip()}


def env_var(pid, name):
    for tok in (sh(f"ps eww -p {pid}") or "").split():
        if tok.startswith(name + "="):
            return tok.split("=", 1)[1]
    return None


def api(method, path, port, pw, body=None):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=_j.dumps(body).encode() if body is not None else None, method=method)
    req.add_header("Authorization", "Basic " + base64.b64encode(f"opencode:{pw}".encode()).decode())
    if body is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=5) as r:
        return _j.loads(r.read().decode() or "null")


# ------------------------------------------------------------------------ 1. full lifecycle
sid = ctl("automation.newAgent", agent="opencode2")["sessionId"]
check("1. row kind", (ctl.row(sid) or {}).get("kind") == "opencode2")
check("2. exactly one serve process for this row",
      wait(lambda: (len(serve_pids()) == 1) or None, 20) is not None, sorted(serve_pids()))
check("3. exactly one TUI process for this row",
      wait(lambda: (len(tui_pids()) == 1) or None, 20) is not None, sorted(tui_pids()))
check("4. goes live", bool(wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 45)))
check("5. deliver accepted (terminal paste, not an injection API)",
      ctl("automation.deliver", sessionId=sid,
          text="Reply with exactly SYNTHOK2 and nothing else.").get("ok", False))
check("6. working", bool(wait(lambda: ((ctl.row(sid) or {}).get("status") == "working") or None, 45, 0.3)))
# A real turn against a real model: generous ceiling, same reasoning as t7's opencode gate.
check("7. idle", bool(wait(lambda: ((ctl.row(sid) or {}).get("status") == "idle") or None, 240, 0.5)))
conv = wait(lambda: (ctl.row(sid) or {}).get("agentSessionId"), 20)
check("8. agentSessionId captured", bool(conv), conv)
# The stock title is the descriptor's displayName ("OpenCode 2"), not the binary name — v2's
# title agent runs alongside the turn and can land after idle, same as v1's (t7_regression.py).
title = wait(lambda: (lambda t: t if t not in ("OpenCode 2", "") else None)((ctl.row(sid) or {}).get("title")),
             40, 0.5)
check("9. auto-title lands (session.renamed, not a placeholder)", bool(title), title)

# ------------------------------------------------------------------------ 2. MCP over the API
cmd = tui_cmd()
port = cmd.split("--server http://127.0.0.1:")[1].split()[0] if cmd and "--server http://127.0.0.1:" in cmd else None
pw = next((env_var(pid, "OPENCODE_PASSWORD") for pid in serve_pids() if env_var(pid, "OPENCODE_PASSWORD")), None)
mcp = api("GET", "/api/mcp", port, pw) if port and pw else None
names = {m.get("name") for m in (mcp or {}).get("data", [])}
check("10. bundled MCP servers PUT-registered into the live session",
      {"synth-browser", "synth-app", "synth-simulator"}.issubset(names), sorted(names))

# ------------------------------------------------------------------------ 3. quit: both processes reaped
serve_before = serve_pids()
for pid in tui_pids():
    os.kill(pid, signal.SIGTERM)
check("11. the row leaves the tree", wait(lambda: ctl.row(sid) is None, 30, 0.2) is not None)
check("12. its serve process is reaped alongside the TUI, not left orphaned",
      wait(lambda: (len(serve_pids() & serve_before) == 0) or None, 20) is not None, sorted(serve_pids()))
c = wait(lambda: next((x for x in ctl("automation.notifs").get("notifs", []) if x["kind"] == "undo"), None),
         15, 0.2)
check("13. it parks on an undo card instead of vanishing", bool(c))
check("14. the card names the agent that quit", c and c["message"] == "OpenCode 2 quit", c and c.get("message"))

# ------------------------------------------------------------------------ 4. resume: truly the same conversation
if c:
    ctl("automation.notifAction", sessionId=c["sessionId"])
back = wait(lambda: ctl.row(sid), 15, 0.2)
check("15. Reopen brings the row back", bool(back))
check("16. with the same conversation id", back and back.get("agentSessionId") == conv,
      back and back.get("agentSessionId"))
ctl("automation.jump", sessionId=sid)
cmd2 = wait(lambda: tui_cmd(), 40)
check("17. the reopened row relaunched opencode2", bool(cmd2), (cmd2 or "")[:90])
check("18. resuming the conversation, not starting a fresh one",
      cmd2 and f"--session {conv}" in cmd2, (cmd2 or "")[:120])

p.terminate()
sys.exit(result())
