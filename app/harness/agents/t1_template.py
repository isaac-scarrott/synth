import sys, time, uuid; sys.path.insert(0, ".")
from lib import *

print("=== T1: new-worktree template spawns an opencode session ===")
kill_all()
repo = fresh_repo()
# global template: opencode first (opens), then a terminal that waits dormant
tpl = [
    {"id": str(uuid.uuid4()), "kind": "opencode", "name": "opencode"},
    {"id": str(uuid.uuid4()), "kind": "terminal", "name": "dev server"},
]
sd = seed_state(repo, template=tpl)
proc, sock = launch(sd, f"{H}/t1.log")
ctl = Ctl(sock, repo)

r = ctl("automation.createWorktree", branch="feature/spawn-test")
check("1. createWorktree accepted", r.get("ok"), r)
wt = r.get("worktreePath")
print(f"     planned worktree: {wt}")

rows = wait(lambda: ctl.sessions(worktree=wt) or None, 40)
check("2. template spawned sessions in the new worktree", bool(rows),
      [(x["kind"], x["title"]) for x in (rows or [])])

if rows:
    kinds = [x["kind"] for x in rows]
    check("3. first template entry is the opencode row", kinds[:1] == ["opencode"], kinds)
    check("4. second entry (terminal) spawned too", "terminal" in kinds, kinds)
    oc = next((x for x in rows if x["kind"] == "opencode"), None)
    # the opened one boots its PTY -> shim -> supervisor
    live = wait(lambda: (ctl.row(oc["sessionId"], worktree=wt) or {}).get("liveAgent"), 40)
    check("5. spawned opencode row goes live (shim + supervisor)", bool(live))
    # a stock-named template entry keeps auto-naming (titleIsCustom false) -> title stays 'opencode'
    check("6. stock template name leaves auto-naming on", (ctl.row(oc["sessionId"], worktree=wt) or {})["title"] == "opencode",
          (ctl.row(oc["sessionId"], worktree=wt) or {}).get("title"))
    procs = sh("ps -eo command= | grep 'opencode --port' | grep -v grep")
    check("7. an opencode server actually launched for it", "--port" in procs, procs.splitlines()[:1])
    port = procs.split("--port")[1].split()[0] if "--port" in procs else None
    listening = sh(f"lsof -iTCP:{port} -sTCP:LISTEN -n -P" ) if port else ""
    check("8. that server is listening on Synth's assigned port", "opencode" in listening.lower(), f"port={port}")

proc.terminate()
sys.exit(result())
