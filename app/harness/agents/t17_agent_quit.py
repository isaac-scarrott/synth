"""An agent that quits parks its conversation on a Reopen card — it does not take it with it.

The incident this gate exists for: an opencode row 69 messages deep, quit mid-turn by a Ctrl-C
(opencode binds `app_exit` to it, and it exits 0), and gone — row torn out of the tree, captured
`ses_…` id gone with it, and not a word on screen, because the closing toast is only raised for
rows you are NOT looking at. A whole conversation for one keystroke.

So the claims worth proving against a running app are:

  - an agent row whose process exits cleanly *with a conversation to resume* is parked, not
    dropped, and the card says which agent quit and offers Reopen,
  - the card never drains (this one can land while you're away from the keyboard, which is
    exactly when a countdown would spend the conversation for you),
  - Reopen brings the row back with its conversation id intact, and the PTY relaunches with
    `--session <id>` — the conversation, not a fresh one,
  - and a row with nothing to resume still closes outright, because the rule is "never destroy a
    conversation Synth can restore", not "never close a row".

SIGTERM stands in for the keystroke: it is the same clean-exit path (143 is a user interrupt, as
neutral as 0), and unlike a simulated keypress it lands on the process whether or not the TUI is
listening.
"""
import os, signal, sys; sys.path.insert(0, ".")
from lib import *

print("=== T17: an agent that quits parks its conversation on a Reopen card ===")
kill_all()
repo = fresh_repo()
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t17.log")
ctl = Ctl(sock, repo)


def cards():
    return ctl("automation.notifs").get("notifs", [])


def opencode_pids():
    out = sh("ps -eo pid=,command= | grep 'opencode --port' | grep -v grep") or ""
    return {int(l.split()[0]) for l in out.splitlines() if l.strip()}


# ---------------------------------------------------------- 1. a row with a conversation to lose
sid = ctl("automation.newAgent", agent="opencode")["sessionId"]
wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 60)
# opencode creates its conversation lazily, on the first prompt — before that there is genuinely
# nothing to resume, which is the negative case at the bottom.
ctl("automation.deliver", sessionId=sid, text="Reply with exactly the word PARKED and nothing else.")
wait(lambda: (ctl.row(sid) or {}).get("status") == "working", 30)
wait(lambda: (ctl.row(sid) or {}).get("status") == "idle", 90)
row = ctl.row(sid) or {}
conv, title = row.get("agentSessionId"), row.get("title")
check("1. the row holds a conversation", bool(conv), conv)

pids = opencode_pids()
check("2. its opencode process is up", len(pids) == 1, sorted(pids))
for pid in pids:
    os.kill(pid, signal.SIGTERM)

# ------------------------------------------------------------------- 2. parked, not dropped
gone = wait(lambda: ctl.row(sid) is None, 30, 0.2)
check("3. the row leaves the tree", gone is not None)
c = wait(lambda: next((x for x in cards() if x["kind"] == "undo"), None), 15, 0.2)
check("4. it parks on an undo card instead of vanishing", bool(c))
check("5. the card names the agent that quit", c and c["message"] == "OpenCode quit", c and c["message"])
check("6. it offers Reopen, not Undo", c and c["action"] == "Reopen", c and c["action"])
check("7. it never drains — no countdown to lose the conversation to",
      c and c["drains"] == "false", c and c["drains"])
check("8. the conversation's name is the evidence under the verb",
      c and c["sub"] == (title if title != "OpenCode" else ""), c and c["sub"])

# ------------------------------------------------------------- 3. Reopen resumes, not restarts
ctl("automation.notifAction", sessionId=c["sessionId"])
back = wait(lambda: ctl.row(sid), 15, 0.2)
check("9. Reopen brings the row back", bool(back))
check("10. with the same conversation id", back and back.get("agentSessionId") == conv,
      back and back.get("agentSessionId"))
check("11. and the card leaves the deck", not any(x["kind"] == "undo" for x in cards()))

ctl("automation.jump", sessionId=sid)
cmd = wait(lambda: (sh("ps -eo command= | grep 'opencode --port' | grep -v grep") or None), 60)
check("12. the reopened row relaunched opencode", bool(cmd), (cmd or "")[:90])
check("13. resuming the conversation, not starting a fresh one",
      cmd and f"--session {conv}" in cmd, (cmd or "")[:120])

# ------------------------------------------------ 4. nothing to resume → the row still closes
# Clear the board first: quit the reopened row and let its card stand (× on an undo commits it,
# exactly as the drain would), so the next case starts with an empty deck.
for pid in opencode_pids():
    os.kill(pid, signal.SIGTERM)
wait(lambda: ctl.row(sid) is None, 30, 0.2)
for x in cards():
    ctl("automation.notifDismiss", sessionId=x["sessionId"])

fresh = ctl("automation.newAgent", agent="opencode")["sessionId"]
wait(lambda: (ctl.row(fresh) or {}).get("liveAgent"), 60)
check("14. the fresh row has no conversation yet",
      not (ctl.row(fresh) or {}).get("agentSessionId"), (ctl.row(fresh) or {}).get("agentSessionId"))
for pid in opencode_pids():
    os.kill(pid, signal.SIGTERM)
closed = wait(lambda: ctl.row(fresh) is None, 30, 0.2)
check("15. a row with nothing to resume closes outright", closed is not None)
check("16. and parks no card — there is nothing to bring back",
      not any(x["kind"] == "undo" for x in cards()), cards())

p.terminate()
sys.exit(result())
