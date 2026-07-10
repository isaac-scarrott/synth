"""ADR-0013's close semantics, driven against a real Synth build.

Remove drops a row, Close ends a session, Delete destroys a folder — and red marks *loss*,
not disk. So the three claims worth proving on the running app are:

  - an idle session closes with no dialog at all,
  - a busy one confirms, and the confirm row is red,
  - an idle one that owns a browser still confirms (the browser row dies with it) but is NOT red,
    because nothing is lost that cannot be reopened.

Everything here goes through `store.requestDelete`, the same path the `d` key uses.
"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "agents"))
from lib import *  # noqa: F403

print("=== Taxonomy: Close is red iff the session is busy (ADR-0013) ===")
kill_all()
repo = fresh_repo()
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t_close.log")
ctl = Ctl(sock, repo)


def palette():
    return ctl("automation.palette")


def close_palette():
    # esc — keyCode 53. Leaves the app on the root frame for the next case.
    ctl("automation.key", keyCode=53, mods=[])
    time.sleep(0.3)


# ---------------------------------------------------------------- 1. idle closes silently
a = ctl("automation.newAgent", agent="opencode")["sessionId"]
wait(lambda: (ctl.row(a) or {}).get("liveAgent"), 60)
wait(lambda: (ctl.row(a) or {}).get("status") == "idle", 30)
check("1. an idle agent row exists", (ctl.row(a) or {}).get("status") == "idle",
      (ctl.row(a) or {}).get("status", "?"))

ctl("automation.requestDelete", sessionId=a)
time.sleep(0.6)
pal = palette()
check("2. closing an IDLE session opens no dialog", pal.get("open") is False,
      f"crumb={pal.get('crumb')!r}")
check("3. the idle session is gone", ctl.row(a) is None)

# ---------------------------------------------------------------- 2. busy confirms, in red
b = ctl("automation.newAgent", agent="opencode")["sessionId"]
wait(lambda: (ctl.row(b) or {}).get("liveAgent"), 60)
ctl("automation.deliver", sessionId=b, text="Count slowly from 1 to 40, one number per line.")
busy = wait(lambda: (ctl.row(b) or {}).get("status") == "working", 60)
check("4. the agent row is busy (working)", bool(busy), (ctl.row(b) or {}).get("status", "?"))

ctl("automation.requestDelete", sessionId=b)
time.sleep(0.6)
pal = palette()
check("5. closing a BUSY session opens a confirm", pal.get("open") is True,
      f"crumb={pal.get('crumb')!r}")
check("6. the confirm says Close, not Delete", pal.get("crumb", "").startswith("Close "),
      pal.get("crumb", ""))
items, danger = pal.get("items", []), pal.get("danger", [])
confirm = next((i for i, l in enumerate(items) if l.startswith("Close ")), None)
check("7. a Close row is present in the confirm", confirm is not None, str(items))
check("8. the busy Close row is RED", confirm is not None and danger[confirm] is True,
      f"danger={danger}")
cancel = next((i for i, l in enumerate(items) if l == "Cancel"), None)
check("9. Cancel is never red", cancel is not None and danger[cancel] is False)
close_palette()
check("10. the busy session survived the cancelled confirm", ctl.row(b) is not None)

# ---------------------------------------------------------------- 3. idle + owns a browser
c = ctl("automation.newAgent", agent="opencode")["sessionId"]
wait(lambda: (ctl.row(c) or {}).get("liveAgent"), 60)
wait(lambda: (ctl.row(c) or {}).get("status") == "idle", 30)
br = ctl("browser.create", url=f"file://{repo}/index.html", ownerSessionId=c)
check("11. the agent owns a browser row", br.get("ok") is True and bool(br.get("sessionId")),
      str(br)[:90])
time.sleep(0.8)

ctl("automation.requestDelete", sessionId=c)
time.sleep(0.6)
pal = palette()
check("12. an IDLE session that owns a browser still confirms", pal.get("open") is True,
      f"crumb={pal.get('crumb')!r}")
items, danger = pal.get("items", []), pal.get("danger", [])
confirm = next((i for i, l in enumerate(items) if l.startswith("Close ")), None)
check("13. that confirm is NOT red (nothing is lost)",
      confirm is not None and danger[confirm] is False, f"danger={danger}")
close_palette()

# ---------------------------------------------------------------- 4. the words themselves
ctl("automation.jump", sessionId=b)
time.sleep(0.4)
ctl("automation.key", keyCode=40, mods=["cmd"])   # ⌘K
time.sleep(0.6)
root = palette()
labels = root.get("items", [])
check("14. ⌘K opens", root.get("open") is True)
check("15. the session verb is Close, never Delete",
      any(l == "Close" for l in labels) and not any(l == "Delete" for l in labels), str(labels)[:120])
check("16. no row says 'New worktree' (you create a branch)",
      not any("New worktree" in l for l in labels), str(labels)[:120])
check("17. no row says 'Move under' (a browser attaches)",
      not any("Move under" in l for l in labels), str(labels)[:120])
close_palette()

ctl("automation.screenshot", path=f"{H}/taxonomy.png")
print(f"\nscreenshot: {H}/taxonomy.png")

kill_all()
sys.exit(result())
