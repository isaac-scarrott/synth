"""A restored Claude row whose conversation Claude deleted starts fresh and says so.

Claude Code deletes every transcript untouched for `cleanupPeriodDays` (30 by default) whenever
any `claude` starts. A branch left alone for a month came back to a row running
`claude --resume <id>`, which prints "No conversation found" and exits 1: an error row whose
Retry resumed the same missing id forever. The claims:

  - a row whose transcript is gone starts a fresh claude instead of an error,
  - its stale id is dropped, so no later spawn tries it again,
  - one card says Claude deleted it,
  - a row whose transcript is still on disk keeps its id and raises no card.
"""
import glob, os, sys, uuid; sys.path.insert(0, ".")
from lib import *

print("=== T42: a deleted Claude conversation starts fresh and says so ===")
config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
# A day old or more: never the conversation someone is in right now.
kept = [t for t in glob.glob(f"{config}/projects/*/*.jsonl") if time.time() - os.path.getmtime(t) > 86400]
if not kept:
    skip("no Claude transcript on this machine to stand in for a live conversation")
live_id = os.path.basename(kept[0])[:-len(".jsonl")]
gone_id = str(uuid.uuid4())

kill_all()
repo = fresh_repo()
gone_sid, live_sid = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
def row(sid, conv, title):
    return {"id": sid, "kind": "claudeCode", "title": title, "titleIsCustom": True,
            "agentSessionID": conv}
sd = seed_state(repo, sessions=[row(gone_sid, gone_id, "Left for forty days"),
                                row(live_sid, live_id, "Still on disk")])
p, sock = launch(sd, f"{H}/t42.log")
ctl = Ctl(sock, repo)

def card(title):
    return next((c for c in ctl("automation.notifs").get("notifs", []) if c["title"] == title), None)

ctl("automation.jump", sessionId=gone_sid)
c = wait(lambda: card("Left for forty days"), 15, 0.2)
check("1. the deleted conversation raises a card", bool(c))
check("2. it says Claude deleted it",
      c and c["message"] == "Claude Code deleted this conversation", c and c["message"])
check("3. and why, under it", c and c["sub"].startswith("Unused for "), c and c["sub"])
r = ctl.row(gone_sid) or {}
check("4. the stale id is dropped", r.get("agentSessionId") != gone_id, r.get("agentSessionId"))
def our_claudes():
    out = sh("ps -eo pid=,command= | grep -E '[c]laude .*--(session-id|resume)'") or ""
    return [l.split(None, 1)[1] for l in out.splitlines() if is_our_row(l.split()[0])]
fresh = wait(our_claudes, 30)
check("5. a fresh claude comes up in the row",
      bool(fresh) and not any(gone_id in c for c in fresh), [c[:80] for c in fresh or []])
r = ctl.row(gone_sid) or {}
check("6. not an error row", r.get("status") != "error", r.get("status"))

ctl("automation.jump", sessionId=live_sid)
time.sleep(3)
check("7. a conversation still on disk raises no card", card("Still on disk") is None, card("Still on disk"))
r = ctl.row(live_sid) or {}
check("8. and keeps its id", r.get("agentSessionId") == live_id, r.get("agentSessionId"))
resumed = wait(lambda: [c for c in our_claudes() if f"--resume {live_id}" in c], 15)
check("9. and resumes it", bool(resumed))

p.terminate()
kill_all()
sys.exit(result())
