"""A restored Antigravity row resumes its conversation (`agy --conversation <id>`).

t2's claim, for the third agent: a row that comes back after a restart is the same conversation,
not a fresh one wearing its name. The proof has to be continuity, so the resumed agent is asked
to recall a word from before the restart — and read back out of the conversation's own transcript
under the CLI's app data dir, which is the only place agy exposes what it said (it has no server
to query the way opencode does).

Takes two real turns, so it needs a signed-in `agy` and skips without one.
"""
import sys, uuid, time; sys.path.insert(0, ".")
from lib import *

print("=== T16: a restored Antigravity row resumes its conversation ===")
require_agy_auth()
kill_all()
repo = fresh_repo()
# Past `agy`'s first-run trust prompt, which is t15's subject, not this one's: unanswered it
# swallows every delivered turn below.
agy_trust(repo)

def turn(ctl, sid, text, secs=180):
    ctl("automation.deliver", sessionId=sid, text=text)
    wait(lambda: ((ctl.row(sid) or {}).get("status") == "working") or None, 60)
    return wait(lambda: ((ctl.row(sid) or {}).get("status") == "idle") or None, secs, 0.5)

def take_live(ctl, sid):
    """Live means the TUI reached CLI mode — agy spends its first seconds starting a language
    server, and text handed over before then is dropped on the floor."""
    return wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 90)

# --- run 1: a real conversation, and the id Synth captured for it ---------------------------
sd = seed_state(repo)
p1, sock1 = launch(sd, f"{H}/t16a.log", env_extra=no_browser_env())
ctl = Ctl(sock1, repo)
sid = ctl("automation.newAgent", agent="antigravity")["sessionId"]
check("1. the first run goes live", bool(take_live(ctl, sid)))
turn(ctl, sid, "Reply with exactly the word RESUMEME and nothing else.")
r = ctl.row(sid) or {}
conv, title = r.get("agentSessionId"), r.get("title")
check("2. it captured a conversation id", bool(conv), conv)
print(f"     conversation={conv}  title={title!r}")
p1.terminate(); time.sleep(1); kill_all()
if not conv:
    sys.exit(result())

# --- run 2: restore a snapshot carrying that id ----------------------------------------------
sd = seed_state(repo, sessions=[{
    "id": str(uuid.uuid4()), "kind": "antigravity", "title": title,
    "titleIsCustom": False, "agentSessionID": conv,
}])
p2, sock2 = launch(sd, f"{H}/t16b.log", env_extra=no_browser_env())
ctl2 = Ctl(sock2, repo)
rows = ctl2.sessions()
check("3. the row came back from the snapshot", len(rows) == 1 and rows[0]["kind"] == "antigravity",
      [(x["kind"], x["title"]) for x in rows])
rsid = rows[0]["sessionId"]
check("4. the conversation id survived persistence", rows[0]["agentSessionId"] == conv,
      rows[0]["agentSessionId"])

# opening it boots the PTY -> the launch line must carry the conversation back in
ctl2("automation.jump", sessionId=rsid)
cmd = wait(lambda: agy_process(), 40) or ""
check("5. the resumed PTY launched agy", bool(cmd), cmd.split(" ")[0])
check("6. it passed --conversation <id>", f"--conversation {conv}" in cmd,
      cmd[cmd.find("agy"):][:120])
check("7. the resumed row goes live", bool(take_live(ctl2, rsid)))

# TRUE continuity: the resumed TUI must be *inside* that conversation. A fresh one could not
# answer, and the transcript it appends to is the conversation's own file.
transcript = agy_transcript(conv)
before = transcript.read_text() if transcript.exists() else ""
turn(ctl2, rsid, "What single word did I ask you to reply with earlier in this conversation? "
                 "Answer with just that word.")
after = transcript.read_text() if transcript.exists() else ""
check("8. the delivered prompt landed in the SAME conversation", len(after) > len(before),
      f"{len(before)} -> {len(after)} chars")
# Only what this turn appended counts: the whole file has said RESUMEME since before the restart.
tail = after[len(before):] if after.startswith(before) else after
check("9. the resumed agent recalls the pre-restart turn (true continuity)",
      "RESUMEME" in tail.upper(), tail[-160:].replace("\n", " "))

p2.terminate()
sys.exit(result())
