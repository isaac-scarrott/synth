import sys, time, json, subprocess; sys.path.insert(0, ".")
from lib import *
print("=== T27: leaving comment mode parks the batch — it is never a way to lose feedback ===")
kill_all(); repo = fresh_repo(); sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t27.log"); ctl = Ctl(sock, repo)
time.sleep(2)
page = f"file://{repo}/index.html"

# No agent is needed: nothing is ever sent here. What is under test is what happens to a batch
# when the mode goes off, which is the same whether or not anything is waiting to receive it.
def state(bid, key, default=None):
    return (ctl("automation.state", sessionId=bid) or {}).get(key, default)


def probe(mode=""):
    out = subprocess.run(["node", "comment_overlay_probe.js", str(port), "index.html", mode],
                         capture_output=True, text=True).stdout.strip()
    try:
        return json.loads(out)
    except Exception:
        return {"error": out}


bid = ctl("browser.create", url=page)["sessionId"]
wait(lambda: ("index.html" in (state(bid, "address") or "")) or None, 40)
port = wait(lambda: instance_json(p.pid).get("cdpPort") or None, 30)   # only once an engine exists
ctl("automation.jump", sessionId=bid)
time.sleep(1.5)
ctl("automation.commentMode", sessionId=bid)                     # the bar button's exact call
check("1. comment mode active on the browser",
      bool(wait(lambda: state(bid, "commentModeActive") or None, 20)))

out = subprocess.run(["node", "comment_overlay_drive.js", str(port), "index.html", "queue",
                      "The heading is too tight.", "This button says nothing."],
                     capture_output=True, text=True).stdout.strip()
check("2. two comments left through the overlay's own UI", out.startswith("QUEUED 2"), out)
check("3. the toolbar counts both", bool(wait(lambda: (state(bid, "pendingComments") == 2) or None, 15)),
      state(bid, "pendingComments"))

# ---------------------------------------------------------------- the toggle is not a discard
ctl("automation.commentMode", sessionId=bid)
check("4. the mode goes off", bool(wait(lambda: (state(bid, "commentModeActive") is False) or None, 20)))
check("5. and the batch stays counted — the toggle is not a discard",
      state(bid, "pendingComments") == 2, state(bid, "pendingComments"))
check("6. the host says the batch is parked", state(bid, "commentsParked") is True,
      state(bid, "commentsParked"))
d = probe("click")
check("7. the pins are still on the page, and the island says what it is holding",
      d.get("host") == 1 and d.get("pins") == 2 and d.get("parked") is True and
      "not sent" in (d.get("islandText") or ""), json.dumps(d))
check("8. and the page is the user's again — its own clicks land",
      d.get("pageClicks") == 1, json.dumps(d))

# ---------------------------------------------------------------- and back in again
ctl("automation.commentMode", sessionId=bid)
check("9. entering again resumes rather than starting over",
      bool(wait(lambda: state(bid, "commentModeActive") or None, 20)) and
      state(bid, "pendingComments") == 2 and state(bid, "commentsParked") is False,
      f"pending={state(bid, 'pendingComments')} parked={state(bid, 'commentsParked')}")
d = probe()
check("10. with the same two pins, and the picker back on",
      d.get("host") == 1 and d.get("pins") == 2 and d.get("parked") is False, json.dumps(d))

# --------------------------------------------- the reload an agent's own edit would have caused
ctl("automation.commentMode", sessionId=bid)
check("11. parked again", bool(wait(lambda: state(bid, "commentsParked") or None, 20)))
d = probe("reload")
check("12. a parked batch survives the page being reloaded under it",
      d.get("host") == 1 and d.get("pins") == 2 and d.get("parked") is True, json.dumps(d))
check("13. and the toolbar still counts it after the reload",
      bool(wait(lambda: (state(bid, "pendingComments") == 2) or None, 20)),
      state(bid, "pendingComments"))

p.terminate()
sys.exit(result())
