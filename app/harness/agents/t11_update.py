"""Update card gate: what an available update says, how often it says it, and what Restart costs.

An update Synth never mentions is the bug this card exists to fix, so the assertions are about
speech: that staging a build raises a card at all, that the card is the app talking about its own
housekeeping (neutral, no who-line, sticky, no countdown) rather than a session's state, that the
copy tells you the build installs itself if you do nothing, and that dismissing it is "not now"
rather than "never" — the reminder comes back on its own.

Sparkle is not in the loop. `automation.updateStage` runs the same store path the real
`willInstallUpdateOnQuit` runs, with an installer that records the ask instead of relaunching —
otherwise proving Restart works would mean killing the instance under test. The daily clock is
compressed by `SYNTH_UPDATE_REMIND_SECONDS`, the same trick the archive suites use, so the
reminder is a thing this suite can actually watch arrive.
"""
import os, sys, uuid
sys.path.insert(0, ".")
import lib
from lib import *

print("=== T11: the update card — what it says, how often, and what Restart costs ===")
os.environ["SYNTH_UPDATE_REMIND_SECONDS"] = "5"   # a "day", compressed — the sub-line counts in these too
kill_all()
repo = fresh_repo()
sd = seed_state(repo, sessions=[
    {"id": str(uuid.uuid4()), "kind": "terminal", "title": "dev server", "titleIsCustom": True},
])
p, sock = launch(sd, f"{lib.H}/t11.log")
ctl = Ctl(sock, repo)


def cards():
    return ctl("automation.notifs").get("notifs", [])


def update_card():
    return next((c for c in cards() if c["message"].startswith("Synth ")
                 and c["message"].endswith("is ready")), None)


def clear():
    for c in cards():
        ctl("automation.notifDismiss", sessionId=c["sessionId"])


check("0. deck route pinned", ctl("automation.notifRoute", route="deck").get("ok"))
clear()

# --- A staged build speaks, in the deck, once ---------------------------------------------------
ctl("automation.updateStage", version="9.9.9")
c = wait(lambda: update_card(), 10, 0.2)
check("1. staging a build raises a card", bool(c))
check("2. it names the version waiting", c and c["message"] == "Synth 9.9.9 is ready",
      c and c["message"])
# The card is the app talking about itself: green stays "your agent finished", blue stays
# "something is blocked on you".
check("3. it is neutral, not a session's state colour", c and c["kind"] == "neutral", c and c["kind"])
check("4. no identity to name, so no who-line", c and c["title"] == "", c and c["title"])
# Attention tier: the decision is open until you make it, so nothing drains it away unread.
check("5. it is sticky, with no countdown",
      c and c["tier"] == "attention" and c["drains"] == "false",
      c and (c["tier"], c["drains"]))
check("6. it offers the shortcut, not a demand", c and c["action"] == "Restart", c and c["action"])
# The whole argument for the × being a complete answer: doing nothing still installs the build.
check("7. it says what happens if you ignore it",
      c and c["sub"] == "Installs when you quit", c and c["sub"])
check("8. exactly one update card, not one per check",
      len([x for x in cards() if x["message"].startswith("Synth 9.9.9")]) == 1)

# --- × means "not now", and tomorrow it says so again -------------------------------------------
first_id = c["sessionId"]
ctl("automation.notifDismiss", sessionId=first_id)
check("9. × drops the card", not update_card())
check("10. dismissing does not throw the build away",
      ctl("automation.updateStatus").get("pending") is True)
back = wait(lambda: update_card(), 20, 0.3)
check("11. the reminder comes back on its own", bool(back))
check("12. it comes back as a new card, at the front of the deck",
      back and back["sessionId"] != first_id)
# --- The reminder ages, because that is the only thing that changed -----------------------------
# Watched, not staged: this is the card the first one became a "day" later.
check("13. and it wears the only fact that changed",
      back and back["sub"] == "Downloaded yesterday", back and back["sub"])
clear()
ctl("automation.updateStage", version="9.9.9", daysAgo=3)
aged = wait(lambda: update_card(), 10, 0.2)
check("14. which keeps counting", aged and aged["sub"] == "Downloaded 3 days ago", aged and aged["sub"])

# --- Unfocused, it still waits in the deck rather than taking a system banner --------------------
# Every other attention card escalates to Notification Center when Synth isn't frontmost. This one
# never does, so pinning the route that way must change nothing about where it lands.
clear()
ctl("automation.notifRoute", route="nc")
ctl("automation.updateStage", version="9.9.9")
check("15. the route that sends other cards to Notification Center leaves this one in the deck",
      bool(wait(lambda: update_card(), 10, 0.2)))
ctl("automation.notifRoute", route="deck")

# --- Restart asks first, but only when there is something to lose -------------------------------
# An agent session starts mid-turn, which is exactly what a restart would kill.
ctl("automation.newClaude")
clear()
ctl("automation.updateStage", version="9.9.9")
c = wait(lambda: update_card(), 10, 0.2)
ctl("automation.notifAction", sessionId=c["sessionId"])
pal = wait(lambda: ctl("automation.palette").get("open") and ctl("automation.palette"), 10, 0.2)
check("16. Restart with a live turn in flight asks first",
      pal and pal["crumb"] == "Restart Synth?", pal and pal.get("crumb"))
check("17. the restart is the red one — it ends things",
      pal and pal["danger"] == [True, False], pal and pal.get("danger"))
check("18. Cancel is preselected, so a stray ↵ costs nothing",
      pal and pal["items"][pal["activeIndex"]] == "Cancel",
      pal and (pal.get("items"), pal.get("activeIndex")))
check("19. asking has not installed anything",
      ctl("automation.updateStatus").get("installRequested") is False)
# The reason has to end with the way out, or the dialog reads as "restart or miss the update".
check("20. it names what is at stake, and the way out",
      pal and pal["note"] == "1 session is busy — restarting ends what they are doing. "
                             "Leave it and the update installs itself the next time you quit.",
      pal and pal.get("note"))

# Answering "not now" must not also lose the reminder — the click that opened the dialog spent
# the card, so it has to be standing again behind it.
ctl("automation.paletteEnter")   # Cancel
check("21. cancelling leaves the reminder standing", bool(wait(lambda: update_card(), 5, 0.2)))

# --- With nothing to lose, Restart just restarts -------------------------------------------------
for s in ctl.sessions():
    if s["kind"] != "terminal":
        ctl("automation.requestDelete", sessionId=s["sessionId"])
ctl("automation.notifDrain")
clear()
ctl("automation.updateStage", version="9.9.9")
c = wait(lambda: update_card(), 10, 0.2)
ctl("automation.notifAction", sessionId=c["sessionId"])
check("22. with nothing busy, Restart goes straight to the install",
      wait(lambda: ctl("automation.updateStatus").get("installRequested") is True, 10, 0.2) is not None)
check("23. and the card goes with it", not update_card())
# Nothing is left claiming a build is waiting — the About row falls back to "Up to date", and a
# force-quit flag left standing by a stub installer would have disarmed the next real ⌘Q.
check("24. the fact goes too, so nothing is still offering it",
      ctl("automation.updateStatus").get("pending") is False)

p.terminate()
sys.exit(result())
