import sys, time, json, pathlib, socket, threading; sys.path.insert(0,".")
from lib import *
print("=== T8: synth-app MCP — registration toggle + approval-gated worktree create ===")

# app.worktreeCreate blocks on the user's answer, so it needs its own socket call
# with a real timeout (Ctl's 30s is tuned for instant verbs).
def raw_call(sock_path, req, timeout=90):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(timeout); s.connect(sock_path)
    s.sendall((json.dumps(req) + "\n").encode())
    b = b""
    while not b.endswith(b"\n"):
        c = s.recv(65536)
        if not c: break
        b += c
    s.close()
    return json.loads(b.decode().strip() or "{}")

kill_all(); repo = fresh_repo(); sd = seed_state(repo)

# --- Phase A: default toggles — browser on, app off; the verb refuses. ---
p, sock = launch(sd, f"{H}/t8a.log"); ctl = Ctl(sock, repo)
time.sleep(3)  # MCPInstaller syncs on the autosave cadence
m = json.loads((pathlib.Path(repo) / ".mcp.json").read_text())
check("1. synth-browser registered by default", "synth-browser" in m.get("mcpServers", {}), list(m.get("mcpServers", {})))
check("2. synth-app absent by default", "synth-app" not in m.get("mcpServers", {}), list(m.get("mcpServers", {})))
r = raw_call(sock, {"verb": "app.worktreeCreate", "worktreePath": str(repo), "branch": "feat/refused"})
check("3. verb refused while toggle off", not r.get("ok") and "turned off" in r.get("error", ""), r)
kill_all()

# --- Phase B: toggle on (argument domain — per-process, no defaults pollution). ---
p, sock = launch(sd, f"{H}/t8b.log", extra_args=["-synth-mcp-app", "<true/>"]); ctl = Ctl(sock, repo)
time.sleep(3)
m = json.loads((pathlib.Path(repo) / ".mcp.json").read_text())
e = m.get("mcpServers", {}).get("synth-app", {})
check("4. synth-app registered when enabled", bool(e), list(m.get("mcpServers", {})))
check("5. entry points at app-server.mjs", "app-server.mjs" in " ".join(map(str, e.get("args", []))), e)
o = json.loads((pathlib.Path(repo) / "opencode.json").read_text())
check("6. opencode.json carries synth-app too", "synth-app" in o.get("mcp", {}), list(o.get("mcp", {})))

# Approve flow: the call parks until the prompt is answered.
res = {}
def call_create():
    try:
        res.update(raw_call(sock, {"verb": "app.worktreeCreate", "worktreePath": str(repo),
                                   "branch": "feat/agent-made",
                                   "handoff": "# Handoff\nReply with exactly: ok"}, timeout=120))
    except Exception as ex:
        res["error"] = f"raw_call raised: {ex}"
t = threading.Thread(target=call_create); t.start()
pr = wait(lambda: (ctl("automation.agentPrompts").get("prompts") or [None])[0], 20)
check("7. prompt raised while the call blocks", bool(pr), pr)
if pr:
    check("8. prompt carries branch + handoff flag", pr["branch"] == "feat/agent-made" and pr["hasHandoff"], pr)
    ctl("automation.agentPromptResolve", promptId=pr["promptId"], approved=True)
t.join(timeout=120)
check("9. approved → decision created", res.get("ok") and res.get("decision") == "created", res)
wtpath = res.get("worktreePath", "")
check("10. worktree materialises on disk", bool(wait(lambda: os.path.isdir(wtpath) or None, 60)), wtpath)
check("11. git registers the branch's worktree",
      bool(wait(lambda: ("feat/agent-made" in sh(f"git -C {repo} worktree list")) or None, 30)),
      sh(f"git -C {repo} worktree list"))
rows = wait(lambda: ctl.sessions(worktree=wtpath) or None, 30) or []
check("12. handoff spawns a seeded Claude row (not the template)",
      len(rows) == 1 and rows[0]["kind"] == "claudeCode", [(x["kind"], x["title"]) for x in rows])

# Decline flow: nothing created, the agent is told.
res2 = {}
def call_decline():
    try:
        res2.update(raw_call(sock, {"verb": "app.worktreeCreate", "worktreePath": str(repo),
                                    "branch": "feat/nope"}, timeout=90))
    except Exception as ex:
        res2["error"] = f"raw_call raised: {ex}"
t2 = threading.Thread(target=call_decline); t2.start()
pr2 = wait(lambda: (ctl("automation.agentPrompts").get("prompts") or [None])[0], 20)
if pr2: ctl("automation.agentPromptResolve", promptId=pr2["promptId"], approved=False)
t2.join(timeout=90)
check("13. declined → decision declined, nothing created",
      res2.get("decision") == "declined" and "feat/nope" not in sh(f"git -C {repo} worktree list"), res2)

# Idempotence: a branch that's already a row answers immediately, no prompt.
main_branch = sh(f"git -C {repo} branch --show-current")
r = raw_call(sock, {"verb": "app.worktreeCreate", "worktreePath": str(repo), "branch": main_branch})
check("14. existing row → immediate 'exists' with its path",
      r.get("decision") == "exists" and bool(r.get("worktreePath")), r)
kill_all()

# --- Phase C: relaunch with the toggle off — stale synth-app entries are removed. ---
p, sock = launch(sd, f"{H}/t8c.log")
time.sleep(3)
m = json.loads((pathlib.Path(repo) / ".mcp.json").read_text())
o = json.loads((pathlib.Path(repo) / "opencode.json").read_text())
check("15. disabled → synth-app removed from .mcp.json", "synth-app" not in m.get("mcpServers", {}), list(m.get("mcpServers", {})))
check("16. disabled → synth-app removed from opencode.json", "synth-app" not in o.get("mcp", {}), list(o.get("mcp", {})))
check("17. synth-browser survives the reconcile", "synth-browser" in m.get("mcpServers", {}), list(m.get("mcpServers", {})))
kill_all()
sys.exit(result())
