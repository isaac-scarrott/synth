import sys, uuid, time; sys.path.insert(0, ".")
from lib import *

print("=== T2: a restored opencode row resumes its conversation (`opencode --session <id>`) ===")
kill_all()
repo = fresh_repo()

# --- run 1: create a real conversation, capture its opencode session id + title ---
sd = seed_state(repo)
p1, sock1 = launch(sd, f"{H}/t2a.log")
ctl = Ctl(sock1, repo)
sid = ctl("automation.newAgent", agent="opencode")["sessionId"]
wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 40)
ctl("automation.deliver", sessionId=sid, text="Reply with exactly the word RESUMEME and nothing else.")
wait(lambda: (ctl.row(sid) or {}).get("status") == "working", 30)
wait(lambda: (ctl.row(sid) or {}).get("status") == "idle", 90)
r = ctl.row(sid)
conv, title = r["agentSessionId"], r["title"]
check("1. first run created a conversation", bool(conv), conv)
print(f"     conversation={conv}  title={title!r}")
p1.terminate(); time.sleep(1); kill_all()

# --- run 2: restore a snapshot carrying that conversation id ---
sd = seed_state(repo, sessions=[{
    "id": str(uuid.uuid4()), "kind": "opencode", "title": title,
    "titleIsCustom": False, "agentSessionID": conv,
}])
p2, sock2 = launch(sd, f"{H}/t2b.log")
ctl2 = Ctl(sock2, repo)
rows = ctl2.sessions()
check("2. row restored from the snapshot", len(rows) == 1 and rows[0]["kind"] == "opencode",
      [(x["kind"], x["title"]) for x in rows])
rsid = rows[0]["sessionId"]
check("3. conversation id survived persistence", rows[0]["agentSessionId"] == conv, rows[0]["agentSessionId"])

# open it -> PTY boots -> launchCommand should be `exec opencode --session '<conv>'`
ctl2("automation.jump", sessionId=rsid)
cmd = wait(lambda: (sh("ps -eo command= | grep 'opencode --port' | grep -v grep") or None), 40)
check("4. the resumed PTY launched opencode", bool(cmd), (cmd or "")[:90])
check("5. it passed --session <conversation id>", cmd and f"--session {conv}" in cmd,
      (cmd or "").split("opencode")[-1].strip()[:80])
live = wait(lambda: (ctl2.row(rsid) or {}).get("liveAgent"), 40)
check("6. resumed row goes live", bool(live))

# TRUE continuity: the resumed TUI must be *inside* that conversation. Ask it to recall the
# word from before the restart — a fresh conversation could not answer. (opencode's session
# store is project-scoped, so merely *listing* the conversation proves nothing.)
port = cmd.split("--port")[1].split()[0] if cmd and "--port" in cmd else None
import json as _j, urllib.request
def msgs():
    try:
        return _j.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/session/{conv}/message", timeout=4).read())
    except Exception:
        return []
before = len(msgs())
ctl2("automation.deliver", sessionId=rsid, text="What single word did I ask you to reply with earlier in this conversation? Answer with just that word.")
wait(lambda: ((ctl2.row(rsid) or {}).get("status") == "working") or None, 60)
wait(lambda: ((ctl2.row(rsid) or {}).get("status") == "idle") or None, 120)
after = msgs()
check("7. the delivered prompt landed in the SAME conversation", len(after) > before, f"{before} -> {len(after)} messages")
texts = " ".join(pt.get("text","") for m in after for pt in (m.get("parts") or []) if pt.get("type")=="text")
check("8. the resumed agent recalls the pre-restart turn (true continuity)", "RESUMEME" in texts.upper(),
      texts[-90:].replace(chr(10)," "))

p2.terminate()
sys.exit(result())
