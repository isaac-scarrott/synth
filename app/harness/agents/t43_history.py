"""Back and forward walk the places you've been.

The claims:

  - ⌃⌘← goes back through the sessions you opened, ⌃⌘→ forward again,
  - forward stops at the newest place, back at the oldest,
  - Settings is a place: back leaves it for the session before, forward returns to it,
  - going somewhere new from the middle drops the forward half,
  - a closed session is stepped over.

⌃O / ⌃I on the sidebar are not driven here: a driven window cannot hand first responder to the
sidebar, so no bare sidebar key reaches it (automation.navMove exists for the same reason).
"""
import sys, uuid; sys.path.insert(0, ".")
from lib import *

print("=== T43: back and forward history ===")
kill_all()
repo = fresh_repo()
a, b, c = (str(uuid.uuid4()).upper() for _ in range(3))
sd = seed_state(repo, sessions=[
    {"id": sid, "kind": "terminal", "title": title, "titleIsCustom": True}
    for sid, title in [(a, "alpha"), (b, "beta"), (c, "gamma")]])
p, sock = launch(sd, f"{H}/t43.log")
ctl = Ctl(sock, repo)

def place():
    return ctl("automation.nav").get("place", "")

def settles_at(want):
    return wait(lambda: place() == want, 5, 0.1) is not None

def key(code, mods, chars=""):
    ctl("automation.key", keyCode=code, mods=mods, chars=chars)

back = lambda: key(123, ["ctrl", "cmd"], "")
fwd = lambda: key(124, ["ctrl", "cmd"], "")

for sid in (a, b, c):
    ctl("automation.jump", sessionId=sid)
    settles_at(sid)
    time.sleep(0.2)

back()
check("1. ⌃⌘← goes back one session", settles_at(b), place())
back()
check("2. and another", settles_at(a), place())
back()
time.sleep(0.5)
check("3. back stops at the oldest place", place() == a, place())
fwd()
check("4. ⌃⌘→ goes forward again", settles_at(b), place())
fwd()
check("5. to the newest", settles_at(c), place())
fwd()
time.sleep(0.5)
check("6. forward stops at the newest place", place() == c, place())

key(43, ["cmd"], ",")
check("7. Settings opens", settles_at("settings"), place())
back()
check("8. back leaves Settings for the session before it", settles_at(c), place())
fwd()
check("9. forward returns to Settings", settles_at("settings"), place())

back(); settles_at(c)
back(); settles_at(b)
ctl("automation.jump", sessionId=a)
settles_at(a)
time.sleep(0.2)
fwd()
time.sleep(0.5)
check("10. somewhere new drops the forward half", place() == a, place())

ctl("automation.jump", sessionId=b); settles_at(b); time.sleep(0.2)
ctl("automation.jump", sessionId=c); settles_at(c); time.sleep(0.2)
ctl("automation.requestDelete", sessionId=b)
wait(lambda: ctl.row(b) is None, 5, 0.1)
back()
check("11. back steps over a closed session", settles_at(a), place())

p.terminate()
kill_all()
sys.exit(result())
