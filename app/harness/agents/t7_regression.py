import sys, time; sys.path.insert(0,".")
from lib import *
print("=== T7: regression — opencode lifecycle gate + Claude Code still hook-driven ===")

def opencode_gate(n):
    kill_all(); repo = fresh_repo(); sd = seed_state(repo)
    p, sock = launch(sd, f"{H}/t7-oc{n}.log"); ctl = Ctl(sock, repo)
    sid = ctl("automation.newAgent", agent="opencode")["sessionId"]
    ok = True
    ok &= (ctl.row(sid) or {}).get("kind") == "opencode"
    ok &= bool(wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 45))
    ok &= ctl("automation.deliver", sessionId=sid, text="Reply with exactly SYNTHOK and nothing else.").get("ok", False)
    ok &= bool(wait(lambda: ((ctl.row(sid) or {}).get("status")=="working") or None, 45, 0.3))
    ok &= bool(wait(lambda: ((ctl.row(sid) or {}).get("status")=="idle") or None, 120, 0.5))
    ok &= bool(wait(lambda: (ctl.row(sid) or {}).get("agentSessionId"), 20))
    # opencode's title agent runs alongside the turn, so the name can land after idle
    ok &= bool(wait(lambda: ((ctl.row(sid) or {}).get("title") not in ("opencode","")) or None, 40, 0.5))
    r = ctl.row(sid) or {}
    p.terminate()
    return ok, r.get("title")

for i in (1,2):
    ok, title = opencode_gate(i)
    check(f"{i}. opencode full lifecycle gate (run {i})", ok, f"auto-title={title!r}")

# Claude Code: startup only (no prompt -> no token spend beyond boot)
kill_all(); repo = fresh_repo(); sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t7-cc.log"); ctl = Ctl(sock, repo)
# Claude must start in a worktree that already carries Synth's .mcp.json — that is the state
# every real worktree is in, and Claude blocks on approving project MCP servers before it fires
# SessionStart. The injected settings approve OUR server by name; without that this hangs.
import pathlib as _pl
check("0. worktree carries Synth's .mcp.json before Claude starts",
      bool(wait(lambda: (_pl.Path(repo) / ".mcp.json").exists(), 30)))
sid = ctl("automation.newAgent", agent="claudeCode")["sessionId"]
check("3. Claude row kind", (ctl.row(sid) or {}).get("kind") == "claudeCode")
# Claude gates a folder it has never seen behind "Yes, I trust this folder", and fires no
# SessionStart until it is answered. Every freshly created worktree is such a folder, and
# Synth's own .mcp.json is what makes the dialog appear. Accept it exactly as a user would —
# one Return — and the hook lands immediately.
check("4. new worktree: Claude waits at its trust prompt (not live yet)",
      not wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 8))
time.sleep(1)
ctl("automation.key", keyCode=36, chars="\r")
check("5. after trusting, Claude goes live via its SessionStart hook",
      bool(wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 60)))
check("6. Claude conversation id captured", bool(wait(lambda: (ctl.row(sid) or {}).get("agentSessionId"), 30)))
check("7. both agents' shims installed side by side",
      "claude" in sh("ls /tmp/synth-shims-*/") and "opencode" in sh("ls /tmp/synth-shims-*/"))
p.terminate()   # the app tears its own PTYs down; never pkill by name (it would match the user's own claude)
sys.exit(result())
