import sys, time; sys.path.insert(0, ".")
from lib import *

print("=== T3: a BACKGROUND opencode session raises done + needs-input notifications ===")
kill_all()
repo = fresh_repo()
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t3.log")
ctl = Ctl(sock, repo)

def notifs():
    r = ctl("automation.notifs")
    return r.get("notifs", []), r.get("active")

# Focus decides the surface: frontmost -> the in-app deck, unfocused -> Notification Center.
# Bring the harness app frontmost so the deck is the surface under test.
# Focus normally decides the surface; a driven instance never holds focus on a live desktop
# (Arc/Teams take it straight back), so pin the route instead of stealing the user's focus.
check("0. deck route pinned", ctl("automation.notifRoute", route="deck").get("ok"))

a = ctl("automation.newAgent", agent="opencode")["sessionId"]
b = ctl("automation.newAgent", agent="opencode")["sessionId"]
wait(lambda: (ctl.row(a) or {}).get("liveAgent"), 45)
wait(lambda: (ctl.row(b) or {}).get("liveAgent"), 45)
ctl("automation.jump", sessionId=a)   # push B to the background
time.sleep(0.5)
check("1. two live opencode rows, A open / B background",
      (ctl.row(a) or {}).get("liveAgent") and (ctl.row(b) or {}).get("liveAgent"))

# --- done toast: B finishes a turn while backgrounded ---
ctl("automation.deliver", sessionId=b, text="Reply with exactly DONE and nothing else.")
wait(lambda: (ctl.row(b) or {}).get("status") == "working", 45)
seen_done = wait(lambda: ([n for n in notifs()[0] if n["sessionId"] == b and n["kind"] == "done"] or None), 120, 0.2)
check("2. background 'done' toast raised for the opencode row", bool(seen_done))
check("3. the toast names the row", bool(seen_done) and bool(seen_done[0]["title"]), seen_done[0]["title"] if seen_done else "")
check("4. the FOREGROUND row raised no toast", not [n for n in notifs()[0] if n["sessionId"] == a])
check("5. the background row is marked unread", (ctl.row(b) or {}).get("unread") is True)
gone = wait(lambda: (not [n for n in notifs()[0] if n["sessionId"] == b and n["kind"] == "done"]) or None, 15, 0.5)
check("6. done toast auto-dismisses (transient)", bool(gone))

# --- needs-input toast: B stops and asks the user (the question channel) ---
ctl("automation.deliver", sessionId=b, text=(
    "Before doing anything else you MUST call your interactive `question` tool to ask me "
    "one multiple-choice question: 'Which colour?' with options Red, Green, Blue. "
    "Call the question tool now. Do not answer it yourself."))
ni = wait(lambda: ((ctl.row(b) or {}).get("status") == "needsInput") or None, 120, 0.3)
check("7. question.asked drives the row to needs-input", bool(ni), (ctl.row(b) or {}).get("status"))
seen_in = wait(lambda: ([n for n in notifs()[0] if n["sessionId"] == b and n["kind"] == "input"] or None), 20, 0.2)
check("8. background 'needs input' toast raised", bool(seen_in))
still = wait(lambda: ([n for n in notifs()[0] if n["sessionId"] == b and n["kind"] == "input"] or None), 8, 0.5)
check("9. needs-input toast persists (asks for something, so not transient)", bool(still))

p.terminate()
sys.exit(result())
