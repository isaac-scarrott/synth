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


# Nothing is written into the worktree any more — the servers ride each agent's launch — so
# "registered" is read from the env a launch here would be handed. `agent` picks whose schema:
# Claude and agy take `mcpServers`, opencode takes `mcp`.
def registered(ctl, agent="CLAUDE", container="mcpServers"):
    env = ctl("automation.mcpLaunchEnv").get("env", {})
    return json.loads(env.get(f"SYNTH_MCP_{agent}", "{}")).get(container, {})

kill_all(); repo = fresh_repo(); sd = seed_state(repo)

# --- Phase A0: the shipped defaults. Both servers are on out of the box since 0.15.1 flipped
# `mcpAppEnabled` (its one mutating verb was already approval-gated, so opt-in bought a
# confirmation that already existed). Asserted with no arguments at all, because the default is
# the thing being claimed. ---
p, sock = launch(sd, f"{H}/t8a0.log"); ctl = Ctl(sock, repo)
time.sleep(3)  # the launch config syncs on the autosave cadence
m = registered(ctl)
check("1. synth-browser registered by default", "synth-browser" in m, list(m))
check("2. synth-app registered by default too", "synth-app" in m, list(m))
kill_all()

# --- Phase A: toggled off — the server is unregistered and the verb refuses. Forced off by
# argument now that off is no longer the default; the off-state still has to work. ---
p, sock = launch(sd, f"{H}/t8a.log", extra_args=["-synth-mcp-app", "<false/>"]); ctl = Ctl(sock, repo)
time.sleep(3)
m = registered(ctl)
check("3. synth-app unregistered while the toggle is off", "synth-app" not in m, list(m))
r = raw_call(sock, {"verb": "app.worktreeCreate", "worktreePath": str(repo), "branch": "feat/refused"})
check("4. verb refused while toggle off", not r.get("ok") and "turned off" in r.get("error", ""), r)
kill_all()

# --- Phase B: toggle on (argument domain — per-process, no defaults pollution). ---
p, sock = launch(sd, f"{H}/t8b.log", extra_args=["-synth-mcp-app", "<true/>"]); ctl = Ctl(sock, repo)
time.sleep(3)
m = registered(ctl)
e = m.get("synth-app", {})
check("5. synth-app registered when enabled", bool(e), list(m))
check("6. entry points at app-server.mjs", "app-server.mjs" in " ".join(map(str, e.get("args", []))), e)
o = registered(ctl, "OPENCODE", "mcp")
check("7. opencode's own env carries synth-app too", "synth-app" in o, list(o))

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
check("8. prompt raised while the call blocks", bool(pr), pr)
if pr:
    check("9. prompt carries branch + handoff flag", pr["branch"] == "feat/agent-made" and pr["hasHandoff"], pr)
    ctl("automation.agentPromptResolve", promptId=pr["promptId"], approved=True)
t.join(timeout=120)
check("10. approved → decision created", res.get("ok") and res.get("decision") == "created", res)
wtpath = res.get("worktreePath", "")
check("11. worktree materialises on disk", bool(wait(lambda: os.path.isdir(wtpath) or None, 60)), wtpath)
check("12. git registers the branch's worktree",
      bool(wait(lambda: ("feat/agent-made" in sh(f"git -C {repo} worktree list")) or None, 30)),
      sh(f"git -C {repo} worktree list"))
rows = wait(lambda: ctl.sessions(worktree=wtpath) or None, 30) or []
check("13. handoff spawns a seeded Claude row (not the template)",
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
check("14. declined → decision declined, nothing created",
      res2.get("decision") == "declined" and "feat/nope" not in sh(f"git -C {repo} worktree list"), res2)

# Idempotence: a branch that's already a row answers immediately, no prompt.
main_branch = sh(f"git -C {repo} branch --show-current")
r = raw_call(sock, {"verb": "app.worktreeCreate", "worktreePath": str(repo), "branch": main_branch})
check("15. existing row → immediate 'exists' with its path",
      r.get("decision") == "exists" and bool(r.get("worktreePath")), r)
kill_all()

# --- Phase C: relaunch with the toggle off — synth-app stops being offered to any agent.
# Forced off by argument: since 0.15.1 "off" is no longer what a bare launch gives you. ---
p, sock = launch(sd, f"{H}/t8c.log", extra_args=["-synth-mcp-app", "<false/>"])
time.sleep(3)
ctl = Ctl(sock, repo)
m = registered(ctl)
o = registered(ctl, "OPENCODE", "mcp")
check("16. disabled → synth-app absent from Claude's launch env", "synth-app" not in m, list(m))
check("17. disabled → synth-app absent from opencode's", "synth-app" not in o, list(o))
check("18. synth-browser survives the reconcile", "synth-browser" in m, list(m))
kill_all()
sys.exit(result())
