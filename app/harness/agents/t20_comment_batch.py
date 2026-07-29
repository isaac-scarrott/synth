import sys, time, pathlib, subprocess; sys.path.insert(0, ".")
from lib import *
print("=== T20: a batch of comments is one delivery — the queue, the chord, and the spawn ===")
kill_all(); repo = fresh_repo(); sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t20.log"); ctl = Ctl(sock, repo)
time.sleep(2)
page1 = f"file://{repo}/index.html"
# Part C needs its own page: the CDP drivers find their page by URL substring, so two browsers
# showing index.html would make "which page" a coin toss — and the binding would fire on the
# wrong browser's controller.
(repo / "unowned.html").write_text(
    "<!doctype html><html><body><h1 id='u-hero'>Unowned harness page</h1>"
    "<p id='u-copy'>Nobody owns this browser yet.</p>"
    "<button id='cta'>Click me</button></body></html>\n")
page2 = f"file://{repo}/unowned.html"
shots = support_dir() / "comments"


def fresh_png(since):
    return [f for f in (shots.rglob("*.png") if shots.exists() else []) if f.stat().st_mtime > since]


def cdp_port():
    return wait(lambda: instance_json(p.pid).get("cdpPort") or None, 30)


def state(bid, key, default=None):
    return (ctl("automation.state", sessionId=bid) or {}).get(key, default)


def enter_comment_mode(bid):
    ctl("automation.jump", sessionId=bid)
    time.sleep(1.5)
    ctl("automation.commentMode", sessionId=bid)
    return bool(wait(lambda: state(bid, "commentModeActive") or None, 20))


# ---------------------------------------------------------------- A. the queue and the chord
# Two comments left through the overlay's own UI — pins, composer, ⏎ queues — then sent with
# the app's chord, not the island's button. This is the path a user actually takes.
oc = ctl("automation.newAgent", agent="opencode")["sessionId"]
check("1. opencode row live (the batch's target)", bool(wait(lambda: (ctl.row(oc) or {}).get("liveAgent"), 60)))
bid = ctl("browser.create", url=page1, ownerSessionId=oc)["sessionId"]
wait(lambda: ("index.html" in (state(bid, "address") or "")) or None, 40)
check("2. comment mode active on the owned browser", enter_comment_mode(bid))

T_A = time.time()
out = subprocess.run(["node", "comment_overlay_drive.js", str(cdp_port()), "index.html", "queue",
                      "First: this heading is too tight.",
                      "Second: reply with exactly BATCHOK and do nothing else."],
                     capture_output=True, text=True).stdout.strip()
check("3. two comments left through the overlay's own UI", out.startswith("QUEUED 2"), out)

# The whole point: ⏎ queued them and nothing was delivered.
check("4. queueing delivered nothing — the batch is still standing",
      (state(bid, "notice") or "") == "" and not fresh_png(T_A),
      f"notice={state(bid, 'notice')!r} pngs={len(fresh_png(T_A))}")
pend = wait(lambda: (state(bid, "pendingComments") or 0) == 2 or None, 15)
check("5. the toolbar count knows about both", bool(pend), state(bid, "pendingComments"))

# ⌘⌥⏎ — the global monitor branch, gated on a standing batch.
ctl("automation.key", keyCode=36, mods=["cmd", "opt"])
notice = wait(lambda: (state(bid, "notice") or None), 60)
check("6. ⌘⌥⏎ sent the batch as one delivery",
      bool(notice) and "2 comments sent to" in notice, notice)
check("7. the owning session started a turn from the batch",
      bool(wait(lambda: ((ctl.row(oc) or {}).get("status") == "working") or None, 60, 0.3)))
check("8. one viewport shot plus one clip per comment",
      len(fresh_png(T_A)) == 3, f"{len(fresh_png(T_A))} new png")
check("9. the count clears once the batch is gone",
      bool(wait(lambda: (state(bid, "pendingComments") == 0) or None, 20)),
      state(bid, "pendingComments"))
wait(lambda: ((ctl.row(oc) or {}).get("status") == "idle") or None, 120, 0.5)

# ---------------------------------------------------------------- B. a pin from another page
# A comment left on a page the browser has since left cannot be re-shot; it must still travel.
T_B = time.time()
check("10. comment mode re-entered", enter_comment_mode(bid) or bool(state(bid, "commentModeActive")))
out = subprocess.run(["node", "comment_click.js", str(cdp_port()), "index.html",
                      "On this page: spacing is off.",
                      "offpage:Left on the previous page: the header lost its logo.",
                      "Also here: this label is vague."],
                     capture_output=True, text=True).stdout.strip()
check("11. a three-comment batch fired, one of them from another page", out == "SENT", out)
notice = wait(lambda: ((state(bid, "notice") or "") and "3 comments sent to" in (state(bid, "notice") or "")) or None, 60)
check("12. all three delivered together", bool(notice), state(bid, "notice"))
check("13. the off-page pin is carried but not screenshotted (viewport + 2 clips)",
      len(fresh_png(T_B)) == 3, f"{len(fresh_png(T_B))} new png")
wait(lambda: ((ctl.row(oc) or {}).get("status") == "idle") or None, 120, 0.5)

# ---------------------------------------------------------------- C. nobody owns this browser
# Rung 3: the batch spawns its own agent, adopts the browser under it, and waits for the hook
# seam before delivering — never pasting into whatever shell happens to be there.
#
# Whether that spawned agent reports live is the machine's business, not the product's (a cold
# claude may never fire the seam here). So the assertion is the invariant that has to hold
# either way: the batch LANDS, or it is handed back and the user is told. Never silence, and
# never a queue emptied by a delivery that did not happen.
T_C = time.time()
before = {s["sessionId"] for s in ctl.sessions()}
ub = ctl("browser.create", url=page2)["sessionId"]
wait(lambda: ("unowned.html" in (state(ub, "address") or "")) or None, 40)
check("14. comment mode active on an unowned browser", enter_comment_mode(ub))
check("15. the target names the agent the batch will start",
      (state(ub, "targetTitle") or "") not in ("", "No agent enabled"), state(ub, "targetTitle"))

out = subprocess.run(["node", "comment_overlay_drive.js", str(cdp_port()), "unowned.html", "queue",
                      "Unowned: reply with exactly SPAWNOK and do nothing else."],
                     capture_output=True, text=True).stdout.strip()
check("16. one comment queued on the unowned browser", out.startswith("QUEUED 1"), out)
check("17. the toolbar counts it before anything is sent",
      bool(wait(lambda: (state(ub, "pendingComments") == 1) or None, 15)), state(ub, "pendingComments"))

# The invariant: one of the two outcomes, and the queue agrees with whichever it was.
def outcome():
    """Terminal outcomes only. "Opening …"/"Starting … to deliver …" are the ladder mid-climb —
    reading those as failure would count screenshots that are still legitimately in flight."""
    note = state(ub, "notice") or ""
    pend = state(ub, "pendingComments")
    if "sent to" in note and pend == 0:
        return ("delivered", note)
    if (note.startswith("Couldn't") or note.startswith("No agent enabled")) and pend == 1:
        return ("kept", note)
    return None

# The chord reads the OPEN session, and comment mode can be on for a session that is not it —
# so prove the browser is open before pressing, or a miss would look like a broken chord.
opened = wait(lambda: ((ctl("automation.nav") or {}).get("openSessionId") == ub) or None, 20)
if not opened:
    ctl("automation.jump", sessionId=ub)
    opened = wait(lambda: ((ctl("automation.nav") or {}).get("openSessionId") == ub) or None, 20)
check("17b. the unowned browser is the open session (what ⌘⌥⏎ reads)", bool(opened),
      (ctl("automation.nav") or {}).get("openSessionId"))
ctl("automation.key", keyCode=36, mods=["cmd", "opt"])
# Watch the outcome from the moment the key lands — the notice auto-clears, so polling for a
# spawned row first would let it expire unseen.
res = wait(outcome, 120, 0.4)
spawned = wait(lambda: next((x["sessionId"] for x in ctl.sessions()
                             if x["sessionId"] not in before and x.get("kind") != "browser"), None), 40)
check("18. the batch spawned an agent to receive it", bool(spawned))
check("19. and adopted the browser under it",
      bool(wait(lambda: ((ctl.row(ub) or {}).get("ownerSessionId") == spawned) or None, 30)),
      (ctl.row(ub) or {}).get("ownerSessionId"))

check("20. the batch either landed or was handed back — never lost", bool(res),
      f"notice={state(ub, 'notice')!r} pending={state(ub, 'pendingComments')}")
if res:
    kind, note = res
    print(f"      … outcome on this machine: {kind} — {note!r}")
    if kind == "delivered":
        check("21. located context captured for the spawned delivery",
              len(fresh_png(T_C)) >= 2, f"{len(fresh_png(T_C))} new png")
    else:
        # Nothing was delivered, so nothing may be left behind pretending it was.
        check("21. a batch that never landed leaves no orphan screenshots",
              len(fresh_png(T_C)) == 0, f"{len(fresh_png(T_C))} new png")

p.terminate()
sys.exit(result())
