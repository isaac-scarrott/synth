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
# A driven instance is never frontmost — it can't be — so pin the route instead of taking focus.
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
# A done toast banks its life while Synth isn't frontmost — right for a user (it should still be
# there when you come back), and a driven instance never is. So say focus came back, exactly as
# the route is pinned rather than stolen; otherwise this check passes only when the harness
# happens to own the desktop.
ctl("automation.notifFocus", active=True)
gone = wait(lambda: (not [n for n in notifs()[0] if n["sessionId"] == b and n["kind"] == "done"]) or None, 20, 0.5)
check("6. done toast auto-dismisses once focus returns (transient)", bool(gone))
ctl("automation.notifFocus", active=False)

# --- needs-input toast: B stops and asks the user (the question channel) ---
# Unfocused, the documented rule is BOTH surfaces: Notification Center catches the eye now, the
# toast waits in the deck for focus to come back. Pin that route so the pair is asserted together.
# The post itself is recorded rather than delivered (a gate must never banner the desktop it runs
# on), which is the only reason the second half of the rule is observable at all.
ctl("automation.notifRoute", route="nc")
before = len(ctl("automation.notifs").get("nc", []))
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
row_title = (ctl.row(b) or {}).get("title", "")
posted = [n for n in ctl("automation.notifs").get("nc", [])[before:] if n["body"].startswith(row_title)]
check("10. and the same transition reached Notification Center, naming the row",
      bool(posted), posted[0] if posted else "nothing posted")

p.terminate()
sys.exit(result())
