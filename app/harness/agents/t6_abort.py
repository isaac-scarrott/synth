import sys, time, json, urllib.request; sys.path.insert(0,".")
from lib import *
print("=== T6: a user abort is a clean interrupt, not an error (MessageAbortedError) ===")
kill_all(); repo = fresh_repo(); sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t6.log"); ctl = Ctl(sock, repo)
ctl("automation.notifRoute", route="deck")   # an error toast, if any, would be observable

# exactly ONE opencode row -> exactly one opencode server, so the port is unambiguous
# (opencode's session store is project-scoped: every server lists the same conversations).
b = ctl("automation.newAgent", agent="opencode")["sessionId"]
wait(lambda: (ctl.row(b) or {}).get("liveAgent"), 60)
# background it behind a browser row, so notifications are in play
bid = ctl("browser.create", url=f"file://{repo}/index.html")["sessionId"]
ctl("automation.jump", sessionId=bid); time.sleep(0.8)
check("0. opencode row is backgrounded", ctl("automation.sessions") and True)

ctl("automation.deliver", sessionId=b, text="Count slowly from 1 to 300, one number per line, with a sentence about each. Take your time.")
check("1. background row started a long turn", bool(wait(lambda: ((ctl.row(b) or {}).get("status")=="working") or None, 60, 0.3)))
conv = wait(lambda: (ctl.row(b) or {}).get("agentSessionId") or None, 30)
check("2. conversation id known", bool(conv), conv)

cmd = sh("ps -eo command= | grep 'opencode --port' | grep -v grep")
ports = [l.split("--port")[1].split()[0] for l in cmd.splitlines() if "--port" in l]
check("3. exactly one opencode server for this row", len(ports) == 1, ports)
port = ports[0]

time.sleep(2)
r = urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/session/{conv}/abort", method="POST"), timeout=5)
check("4. abort accepted", r.status == 200, r.status)

settled = wait(lambda: ((ctl.row(b) or {}).get("status") in ("idle","error")) or None, 40, 0.2)
status = (ctl.row(b) or {}).get("status")
check("5. the aborted row settles", bool(settled), status)
check("6. abort settles to IDLE, not error (MessageAbortedError filtered)", status == "idle", status)

time.sleep(3)
toasts = [n for n in ctl("automation.notifs")["notifs"] if n["sessionId"] == b]
check("7. no ERROR toast raised for a user abort", not [t for t in toasts if t["kind"] == "error"], toasts)
check("8. row still alive (abort doesn't close the session)", ctl.row(b) is not None)

p.terminate()
sys.exit(result())
