"""Toast deck gate: the three tiers, the card grammar, and dismissal.

Everything here is asserted through `automation.notifs`, which reports each standing card as
NotificationDeck renders it — kind, tier, verb line, evidence sub-line, what its button offers,
whether it is running a countdown. No agent binaries and no pixels: the cards under test are
raised by soft deletes, worktree failures and the archive clean-up, all of which are drivable.

The point of the suite is that a card's *presentation* now carries meaning. A regression that
puts a housekeeping digest back in needs-input blue, or drops the who-line rule and floats a dot
over an empty title again, or makes the × mean the same thing as a click, is a regression in the
only thing these cards exist to do.

Two phases, because the clean-up needs a repo with a real `origin` before a row is archived for
you: phase A drives soft deletes and worktree failures against a plain fixture; phase B reuses
t9's sandbox and asserts only the shape of the one card a clean-up raises.
"""
import os, pathlib, sys, time, uuid
sys.path.insert(0, ".")
import lib
from lib import *
import archive_fixture as fx

print("=== T10: notification deck — tiers, card grammar, dismissal ===")
kill_all()
repo = fresh_repo()
sd = seed_state(repo, sessions=[
    {"id": str(uuid.uuid4()), "kind": "terminal", "title": "dev server", "titleIsCustom": True},
    {"id": str(uuid.uuid4()), "kind": "terminal", "title": "api-tests", "titleIsCustom": True},
])
p, sock = launch(sd, f"{lib.H}/t10.log")
ctl = Ctl(sock, repo)


def cards():
    return ctl("automation.notifs").get("notifs", [])


def card(match):
    return next((c for c in cards() if match(c)), None)


def clear():
    """Drop everything standing, so each case asserts on its own card."""
    for c in cards():
        ctl("automation.notifDismiss", sessionId=c["sessionId"])


check("0. deck route pinned", ctl("automation.notifRoute", route="deck").get("ok"))

rows = ctl("automation.nav")["rows"]
bg = next(r for r in rows if r["sessionId"] != ctl("automation.nav")["openSessionId"])

# --- Tier 2: the undo window -------------------------------------------------------------------
ctl("automation.requestDelete", sessionId=bg["sessionId"])
u = wait(lambda: card(lambda c: c["kind"] == "undo"), 10, 0.2)
check("1. closing a session parks an undo card", bool(u))
check("2. the undo card offers Undo, not a grey hint", u and u["action"] == "Undo", u and u["action"])
check("3. it runs a countdown", u and u["drains"] == "true")
check("4. it names what you did", u and u["message"] == f"Closed {bg['title']}", u and u["message"])
check("5. it is not the destructive one", u and u["destructive"] == "false")
check("6. no identity to name, so no who-line", u and u["title"] == "", u and u["title"])

# The × is not the action. Dismissing an undo means "let it stand" — the same thing the
# countdown draining out already does — so the row must NOT come back.
ctl("automation.notifDismiss", sessionId=u["sessionId"])
gone = wait(lambda: (not card(lambda c: c["kind"] == "undo")) or None, 5, 0.2)
check("7. dismissing an undo card commits the removal", bool(gone))
alive = [r["sessionId"] for r in ctl("automation.nav")["rows"]]
check("8. the closed row stayed closed", bg["sessionId"] not in alive)

# --- Tier 2, destructive: the one whose expiry hits the disk -----------------------------------
clear()
ctl("automation.createWorktree", branch="doomed")
time.sleep(2.5)   # the checkout lands on the repo's background git chain
clear()
ctl("automation.deleteWorktreeNow", branch="doomed")
d = wait(lambda: card(lambda c: c["destructive"] == "true"), 10, 0.2)
check("9. deleting a worktree parks a DESTRUCTIVE undo card", bool(d))
check("10. it says what its countdown is for",
      d and d["sub"] == "the folder goes when the bar does", d and d["sub"])
check("11. its Undo reads as the last chance", d and d["action"] == "Undo")
ctl("automation.notifDrain")   # let the window elapse, as the bar would

# --- Tier 2: archiving touches nothing on disk, so it is not the destructive one ----------------
clear()
ctl("automation.createWorktree", branch="tidy")
time.sleep(2.5)
clear()
ctl("automation.archiveBranch", branch="tidy")
a = wait(lambda: card(lambda c: c["kind"] == "undo" and c["message"].startswith("Archived")), 10, 0.2)
check("12. archiving parks its own undo card", bool(a))
check("13. archiving is not destructive — nothing on disk moved", a and a["destructive"] == "false")
ctl("automation.notifDrain")

# --- Tier 1: a failure that says what git said, and offers the call again -----------------------
clear()
# Branching off a ref that doesn't exist fails in git, on the background chain, after the row
# has already appeared — which is exactly the situation this card exists for.
ctl("automation.createWorktree", branch="doomed-base", base="no-such-ref")
err = wait(lambda: card(lambda c: c["kind"] == "error"), 25, 0.3)
check("14. a failed background worktree op raises an error card", bool(err),
      err and err["message"])
check("15. it is attention tier — sticky, no countdown",
      err and err["tier"] == "attention" and err["drains"] == "false",
      err and (err["tier"], err["drains"]))
# Not git's FIRST line: `worktree add` narrates progress on stdout and puts the reason on stderr.
check("16. git's reason comes onto the card, not its progress chatter",
      bool(err and err["sub"]) and not err["sub"].startswith("Preparing"), err and err["sub"])
check("17. it offers the call that failed", err and err["action"] == "Retry", err and err["action"])
check("18. it names the branch and workspace", bool(err and " · " in err["title"]),
      err and err["title"])

# A sticky card can be dropped without acting on it — the whole point of the ×.
if err:
    ctl("automation.notifDismiss", sessionId=err["sessionId"])
check("19. × drops a sticky card", not card(lambda c: c["kind"] == "error"))

p.terminate()

# --- Phase B: the shape of a housekeeping card --------------------------------------------------
# t9 proves the clean-up decides correctly; this asserts only how it speaks.
kill_all()
os.environ.update({
    "SYNTH_ARCHIVE_GRACE_SECONDS": "0",
    "SYNTH_ARCHIVE_TICK_SECONDS": "3600",
})
H = pathlib.Path(lib.H)
sandbox, made = fx.build(H / "sandbox", support_dir())
sd2 = H / "state2"
sh(f"rm -rf '{sd2}'")
sd2.mkdir(parents=True)
(sd2 / "state.json").write_text(__import__("json").dumps(fx.state(sandbox, made)))
p2, sock2 = launch(sd2, f"{lib.H}/t10b.log", extra_args=[
    "-synth-archive-sweep", "<true/>",
    "-synth-archive-grace-days", "<integer>7</integer>",
])
ctl2 = Ctl(sock2, sandbox)
ctl2("automation.notifRoute", route="deck")


def cards2():
    return ctl2("automation.notifs").get("notifs", [])


# Archive a row by hand, then let its undo window elapse — headless the drain is held, so say
# it out loud. With the wait at zero its folder is due on the next tick.
ctl2("automation.archiveBranch", branch="merged-clean")
ctl2("automation.notifDrain")
wait(lambda: any(r["branch"] == "merged-clean"
                 for r in ctl2("automation.archiveStatus").get("archived", [])), 20)
for c in cards2():
    ctl2("automation.notifDismiss", sessionId=c["sessionId"])

ctl2("automation.archiveSweep")
digest = wait(lambda: next((c for c in cards2() if c["kind"] == "neutral"), None), 30, 0.3)
check("20. a clean-up digest is NEUTRAL — the app's own housekeeping, not a green completion",
      bool(digest), digest and digest["message"])
check("20b. and it is the only card the tick raised — archiving merged rows is silent",
      digest and digest["message"] == "Cleaned up merged-clean"
      and sum(1 for c in cards2() if c["kind"] == "neutral") == 1,
      str([c["message"] for c in cards2()]))
check("21. it is ambient — a result, not a summons", digest and digest["tier"] == "ambient",
      digest and digest["tier"])
check("22. it runs a countdown", digest and digest["drains"] == "true")
check("23. no session to name, so no who-line", digest and digest["title"] == "",
      digest and digest["title"])

# The countdown is the dismissal, not a decoration of it. Unfocused it banks (right for a user —
# the card should still be there when you come back), so say focus returned and watch it go.
# Pin the brake first: a driven instance can briefly steal the desktop, and this must not depend
# on whether it happened to.
ctl2("automation.notifFocus", active=False)
time.sleep(8)
check("24. it holds while Synth isn't frontmost",
      any(c["kind"] == "neutral" for c in cards2()))
ctl2("automation.notifFocus", active=True)
drained = wait(lambda: (not any(c["kind"] == "neutral" for c in cards2())) or None, 20, 0.4)
check("25. and dismisses itself once focus returns", bool(drained))

p2.terminate()
kill_all()
sys.exit(result())
