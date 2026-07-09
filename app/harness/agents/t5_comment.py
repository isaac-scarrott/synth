import sys, time, pathlib, subprocess; sys.path.insert(0,".")
from lib import *
T0 = time.time()
print("=== T5: click-to-comment on the live page reaches the owning opencode session ===")
kill_all(); repo = fresh_repo(); sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t5.log"); ctl = Ctl(sock, repo)
time.sleep(2)
page1 = f"file://{repo}/index.html"

oc = ctl("automation.newAgent", agent="opencode")["sessionId"]
check("1. opencode row live (the comment target)", bool(wait(lambda: (ctl.row(oc) or {}).get("liveAgent"), 60)))
bid = ctl("browser.create", url=page1, ownerSessionId=oc)["sessionId"]
wait(lambda: ("index.html" in ((ctl("automation.state", sessionId=bid) or {}).get("address") or "")) or None, 40)
check("2. owned browser open on the page", True)

# an agent-created browser boots detached (it must not steal the pane); comment mode is a
# user gesture on the open browser, so open it first — exactly as a user would.
ctl("automation.jump", sessionId=bid)
time.sleep(1.5)
r = ctl("automation.commentMode", sessionId=bid)
check("3. comment mode toggled on", r.get("ok"), r)
st = wait(lambda: (ctl("automation.state", sessionId=bid) or {}).get("commentModeActive") or None, 20)
check("4. comment mode active", bool(st))
target = (ctl("automation.state", sessionId=bid) or {}).get("targetTitle")
check("5. the bar names the owning agent as target", bool(target), target)

port = instance_json(p.pid).get("cdpPort")
out = subprocess.run(["node", "comment_click.js", str(port), "index.html",
                      "Reply with exactly COMMENTOK and do nothing else."],
                     capture_output=True, text=True).stdout.strip()
check("6. the page fired the __synthComment binding (overlay's own path)", out == "SENT", out)

notice = wait(lambda: ((ctl("automation.state", sessionId=bid) or {}).get("notice") or None), 40)
check("7. CommentMode reports delivery", notice and "Comment sent to" in notice, notice)

# the comment must actually reach the agent: its row starts a turn
working = wait(lambda: ((ctl.row(oc) or {}).get("status") == "working") or None, 60, 0.3)
check("8. the owning opencode session started a turn from the comment", bool(working))
idle = wait(lambda: ((ctl.row(oc) or {}).get("status") == "idle") or None, 120, 0.5)
check("9. it finished the turn", bool(idle))

shots = pathlib.Path.home() / "Library/Application Support/Synth/comments"
fresh = [f for f in (shots.rglob("*.png") if shots.exists() else []) if f.stat().st_mtime > T0]
check("10. located context captured this run (element + viewport screenshots)", len(fresh) >= 2, f"{len(fresh)} new png")

p.terminate()
sys.exit(result())
