"""Usage alerts gate: a window crossing 80% or 95% raises one card, once per window.

Driven runs never read the real account, so readings are fed through `automation.usageReading` —
the same path a board refresh takes. Everything is asserted through `automation.notifs`.

What the suite protects: the alert says a line was crossed *once*. A regression that repeats it
every poll, or forgets it across a relaunch, or never speaks again after the window resets, turns
the one card worth reading into noise — or into silence. And the 95% card is the one that must
not quietly drain away or be replaced by a lesser one.
"""
import sys, time
sys.path.insert(0, ".")
import lib
from lib import *

print("=== T38: usage alerts — thresholds, once per window, memory, the switch ===")
kill_all()
repo = fresh_repo()
sd = seed_state(repo)
p, sock = launch(sd, f"{lib.H}/t38.log")
ctl = Ctl(sock, repo)
WEEK = 4 * 86400


def usage_cards():
    return [c for c in ctl("automation.notifs").get("notifs", []) if c["action"] == "View"]


def read(*metrics, agent="claudeCode", title="Claude Code"):
    ok = ctl("automation.usageReading", agent=agent, title=title, metrics=list(metrics)).get("ok")
    assert ok, "usageReading refused"
    time.sleep(0.3)


def clear():
    for c in ctl("automation.notifs").get("notifs", []):
        ctl("automation.notifDismiss", sessionId=c["sessionId"])


def session(pct, resets=3 * 3600):
    return {"id": "claude.session", "label": "Current session", "percent": pct, "resetsIn": resets}


def week(pct):
    return {"id": "claude.weekly_all", "label": "Current week · all models", "percent": pct, "resetsIn": WEEK}


def fable(pct):
    return {"id": "claude.weekly_scoped.Fable", "label": "Current week · Fable", "percent": pct, "resetsIn": WEEK}


def messages():
    return sorted(c["message"] for c in usage_cards())


check("0. deck route pinned", ctl("automation.notifRoute", route="deck").get("ok"))

read(session(75), week(20))
check("1. below every line, nothing is said", usage_cards() == [], str(usage_cards()))

read(session(81), week(20))
cards = usage_cards()
c = cards[0] if cards else None
check("2. crossing 80% raises one card", len(cards) == 1, str(cards))
check("3. it names the window and the true number", c and c["message"] == "Current session at 81%",
      c and c["message"])
check("4. it names the agent on the who-line", c and c["title"] == "Claude Code", c and c["title"])
check("5. neutral and ambient — the app's word, not a session's state",
      c and c["kind"] == "neutral" and c["tier"] == "ambient", c and (c["kind"], c["tier"]))
check("6. it drains", c and c["drains"] == "true")
check("7. it says when the window resets", c and c["sub"].startswith("resets in"), c and c["sub"])

clear()
read(session(85), week(20))
check("8. climbing inside the same band says nothing again", usage_cards() == [], str(usage_cards()))

read(session(96), week(20))
cards = usage_cards()
c = cards[0] if cards else None
check("9. crossing 95% speaks again", len(cards) == 1 and c["message"] == "Current session at 96%",
      str(cards))
check("10. and that card stays until dismissed", c and c["tier"] == "attention" and c["drains"] == "false",
      c and (c["tier"], c["drains"]))

read(session(97), week(88))
check("11. an 80% card joins a standing 95% one rather than replacing it",
      messages() == ["Current session at 96%", "Current week · all models at 88%"], str(messages()))
read(session(97), week(88), fable(85))
check("12. a later 80% crossing replaces its like",
      messages() == ["Current session at 96%", "Current week · Fable at 85%"], str(messages()))

clear()
read(session(98), week(96), fable(97))
cards = usage_cards()
check("13. several windows crossing in one reading make one card, led by the fullest",
      len(cards) == 1 and cards[0]["message"] == "Current week · Fable at 97%", str(cards))
check("14. and it says how many more", bool(cards) and cards[0]["sub"].endswith("+1 more"),
      cards and cards[0]["sub"])

clear()
read(session(3, resets=5 * 3600), week(96))
check("15. a window that reset says nothing on the way down", usage_cards() == [], str(usage_cards()))
read(session(83, resets=5 * 3600), week(96))
check("16. and speaks again when the new window crosses 80%", messages() == ["Current session at 83%"],
      str(messages()))

clear()
read(session(85, resets=1), week(96))
time.sleep(1.5)
read(session(85, resets=5 * 3600), week(96))
check("17. a deadline passing forgets the window even if the reset was never seen as a fall",
      len(usage_cards()) == 1, str(usage_cards()))

clear()
read({"id": "opencode.tokens", "label": "Tokens", "resetsIn": WEEK},
     {"id": "agy.gemini", "label": "Gemini · 5-hour", "percent": 90, "resetsIn": 3600},
     agent="antigravity", title="Antigravity")
cards = usage_cards()
check("18. any agent whose reader reports a ceiling is covered", len(cards) == 1
      and cards[0]["title"] == "Antigravity" and cards[0]["message"] == "Gemini · 5-hour at 90%", str(cards))

c = usage_cards()[0]
ctl("automation.notifAction", sessionId=c["sessionId"])
check("19. View opens the Usage board", wait(lambda: ctl("automation.notifs").get("usageOpen"), 5, 0.2))
check("20. and the card goes with it", usage_cards() == [])
read(session(99, resets=6 * 3600 + 5), week(96))
check("21. the board on screen is already saying it — no card", usage_cards() == [], str(usage_cards()))

p.terminate()
p.wait()

# The memory outlives the process: an update relaunch must not repeat every alert still standing.
p, sock = launch(sd, f"{lib.H}/t38b.log")
ctl = Ctl(sock, repo)
ctl("automation.notifRoute", route="deck")
read(session(99, resets=6 * 3600 + 5), week(96))
check("22. a relaunch remembers what was already said", usage_cards() == [], str(usage_cards()))
p.terminate()
p.wait()

# Settings → Usage alerts off: nothing is raised, whatever crosses.
p, sock = launch(sd, f"{lib.H}/t38c.log", extra_args=["-synth-usage-alerts", "<false/>"])
ctl = Ctl(sock, repo)
ctl("automation.notifRoute", route="deck")
read({"id": "agy.gemini", "label": "Gemini · 5-hour", "percent": 97, "resetsIn": 3600},
     agent="antigravity", title="Antigravity")
check("23. with alerts switched off, a 95% crossing raises nothing", usage_cards() == [], str(usage_cards()))

p.terminate()
kill_all()
sys.exit(result())
