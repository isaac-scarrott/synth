import sys, time; sys.path.insert(0,".")
from lib import *
print("=== T7: regression — opencode lifecycle gate + Claude Code still hook-driven ===")

def opencode_gate(n):
    """One row from creation to a named, idle session. Every rung is timed and reported by name:
    collapsed into a single boolean, a failure here says only that the lifecycle broke somewhere,
    and the difference between "never went live" and "the turn outran the clock" is the difference
    between a product bug and a slow model."""
    kill_all(); repo = fresh_repo(); sd = seed_state(repo)
    p, sock = launch(sd, f"{H}/t7-oc{n}.log"); ctl = Ctl(sock, repo)
    sid = ctl("automation.newAgent", agent="opencode")["sessionId"]
    rungs = [
        ("kind",     lambda: (ctl.row(sid) or {}).get("kind") == "opencode"),
        ("live",     lambda: wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 45)),
        ("deliver",  lambda: ctl("automation.deliver", sessionId=sid,
                                 text="Reply with exactly SYNTHOK and nothing else.").get("ok", False)),
        ("working",  lambda: wait(lambda: ((ctl.row(sid) or {}).get("status") == "working") or None, 45, 0.3)),
        # A real turn against a real model: 60–95s is normal on a machine that is also running
        # gates, so the ceiling is well clear of it rather than a coin toss against it.
        ("idle",     lambda: wait(lambda: ((ctl.row(sid) or {}).get("status") == "idle") or None, 240, 0.5)),
        ("agentSessionId", lambda: wait(lambda: (ctl.row(sid) or {}).get("agentSessionId"), 20)),
        # opencode's title agent runs alongside the turn, so the name can land after idle
        ("auto-title", lambda: wait(lambda: ((ctl.row(sid) or {}).get("title") not in ("opencode", "")) or None, 40, 0.5)),
    ]
    t0, failed = time.time(), []
    for name, rung in rungs:
        if not rung(): failed.append(f"{name} @{time.time() - t0:.0f}s")
    r = ctl.row(sid) or {}
    p.terminate()
    return not failed, (f"stalled at {', '.join(failed)}" if failed else f"auto-title={r.get('title')!r}")

for i in (1,2):
    ok, detail = opencode_gate(i)
    check(f"{i}. opencode full lifecycle gate (run {i})", ok, detail)

# Claude Code: startup only (no prompt -> no token spend beyond boot)
kill_all(); repo = fresh_repo(); sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t7-cc.log"); ctl = Ctl(sock, repo)
# Claude must start in a worktree Synth has registered its servers for — that is the state
# every real worktree is in. They arrive as `--mcp-config` on the launch, not as a `.mcp.json`
# Claude would first ask to approve.
import pathlib as _pl
check("0. servers registered for this worktree before Claude starts",
      bool(wait(lambda: ctl("automation.mcpLaunchEnv").get("env", {}).get("SYNTH_MCP_CLAUDE"), 30)))
check("0b. and nothing written into the worktree to carry them",
      not (_pl.Path(repo) / ".mcp.json").exists())
sid = ctl("automation.newAgent", agent="claudeCode")["sessionId"]
check("3. Claude row kind", (ctl.row(sid) or {}).get("kind") == "claudeCode")
# Claude gates a folder it has never seen behind "Yes, I trust this folder", and fires no
# SessionStart until it is answered. Every freshly created worktree is such a folder: trust is
# keyed per directory and inherited only from ancestors, and Synth's worktrees live under
# Application Support rather than under the user's repo — so the prompt is the path's, not
# anything Synth writes.
#
# The per-server approval that used to follow it is gone with the `.mcp.json` that raised it:
# servers passed on the command line are not the project servers Claude asks about. This still
# answers prompts until the hook lands rather than assuming a count, so the next thing that adds
# or removes a gate doesn't read as "Claude stopped starting".
check("4. new worktree: Claude waits at its trust prompt (not live yet)",
      not wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 8))
live = None
for _ in range(4):
    time.sleep(1.5)
    ctl("automation.key", keyCode=36, chars="\r")
    live = wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 20)
    if live: break
check("5. answering Claude's startup gates takes it live via its SessionStart hook", bool(live))
check("6. Claude conversation id captured", bool(wait(lambda: (ctl.row(sid) or {}).get("agentSessionId"), 30)))
check("7. both agents' shims installed side by side",
      "claude" in sh("ls /tmp/synth-shims-*/") and "opencode" in sh("ls /tmp/synth-shims-*/"))
p.terminate()   # the app tears its own PTYs down; never pkill by name (it would match the user's own claude)
sys.exit(result())
