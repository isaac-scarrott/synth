import json, os, subprocess, sys, time; sys.path.insert(0,".")
from lib import *
from askserver import start_all
print("=== T29: the page's questions reach the user, and find in page works ===")

# Everything here is measured against real servers (askserver.py). A certificate error only
# exists if a real handshake presents a certificate nothing trusts, and a basic-auth prompt
# only exists if a server really sends WWW-Authenticate — so the gate runs them rather than
# simulating them.

kill_all(); repo = fresh_repo(); sd = seed_state(repo)
plain, https, auth, servers = start_all(f"{H}/pages")
p, sock = launch(sd, f"{H}/t29.log"); ctl = Ctl(sock, repo)
time.sleep(2)

def asks(bid):
    return (ctl("automation.browserAsks", sessionId=bid) or {}).get("asks") or []

def wait_ask(bid, kind, secs=30):
    return wait(lambda: next((a for a in asks(bid) if a.get("kind") == kind), None), secs, 0.4)

def address(bid):
    return (ctl("automation.state", sessionId=bid) or {}).get("address") or ""

# --- 1. A self-signed certificate has a proceed path -----------------------------------
# Without OnCertificateError wired, this load simply failed: no prompt, no way through, and a
# local HTTPS dev server was unreachable from the pane whose job is checking your work.
bid = ctl("browser.create", url=f"https://127.0.0.1:{https}/secure.html")["sessionId"]
wait(lambda: (ctl("automation.state", sessionId=bid) or {}).get("ok") or None, 40)
a = wait_ask(bid, "certificate")
check("1. the self-signed certificate raises a question rather than a dead end", bool(a), asks(bid))
check("2. it names the host and why the certificate was rejected",
      a and "127.0.0.1" in a.get("origin", "") and "trust" in (a.get("detail") or ""), a)

r = ctl("automation.browserAnswer", sessionId=bid, allow=True)
check("3. Continue is accepted", r.get("ok"), r)
port = instance_json(p.pid).get("cdpPort")
loaded = wait(lambda: (cdp_eval(port, "secure.html", "document.title") == "SECURE") or None, 40, 0.5)
check("4. and the page then loads over HTTPS", bool(loaded))
check("5. the question is gone from the pane", not asks(bid), asks(bid))
ctl("browser.close", sessionId=bid)

# --- 2. Basic auth has a prompt --------------------------------------------------------
bid = ctl("browser.create", url=f"http://127.0.0.1:{auth}/protected.html")["sessionId"]
wait(lambda: (ctl("automation.state", sessionId=bid) or {}).get("ok") or None, 40)
a = wait_ask(bid, "auth")
check("6. a 401 raises a sign-in question", bool(a), asks(bid))
check("7. it carries the server's realm, so you know which credentials it wants",
      a and a.get("detail") == "Staging", a)
ctl("automation.browserAnswer", sessionId=bid, allow=True, user="dev", password="hunter2")
signed_in = wait(lambda: (cdp_eval(port, "protected.html", "document.title") == "PROTECTED") or None, 40, 0.5)
check("8. the credentials go to the server and the page loads", bool(signed_in))
ctl("browser.close", sessionId=bid)

# --- 3. alert / confirm / prompt are defined again -------------------------------------
page = f"http://127.0.0.1:{plain}/dialogs.html"
bid = ctl("browser.create", url=page)["sessionId"]
wait(lambda: ("dialogs.html" in address(bid)) or None, 40)

# Triggered by navigating to a fragment — the pane's own "go to" — so nothing is attached
# over CDP while a dialog is up. A CDP client with the Page domain enabled answers JavaScript
# dialogs itself, and the gate would then be measuring the harness.
fire = lambda kind: ctl("automation.browserGo", sessionId=bid, url=f"{page}#{kind}")

fire("alert")
a = wait_ask(bid, "alert")
check("9. alert() raises the page's own words, attributed to the page",
      a and a.get("detail") == "the page has something to say", a)
ctl("automation.browserAnswer", sessionId=bid, allow=True)
check("10. answering it lets the page carry on",
      wait(lambda: (cdp_eval(port, "dialogs.html", "window.__answer") == "alerted") or None, 20))

fire("confirm")
wait_ask(bid, "confirm")
ctl("automation.browserAnswer", sessionId=bid, allow=False)
check("11. confirm() returns false when the user cancels",
      wait(lambda: (cdp_eval(port, "dialogs.html", "window.__answer") == "false") or None, 20))

fire("prompt")
a = wait_ask(bid, "prompt")
check("12. prompt() offers the page's default text", a and a.get("defaultText") == "nobody", a)
ctl("automation.browserAnswer", sessionId=bid, allow=True, text="isaac")
check("13. and returns what was typed",
      wait(lambda: (cdp_eval(port, "dialogs.html", "window.__answer") == "isaac") or None, 20))

# --- 4. The camera can be granted ------------------------------------------------------
# Alloy's default for a media request is a silent deny — an app using the camera looked broken
# in Synth and fine in Chrome, which reads as our bug in their code.
fire("camera")
a = wait_ask(bid, "permission")
check("14. getUserMedia asks, in words rather than a bitmask",
      a and "camera" in (a.get("detail") or ""), a)
ctl("automation.browserAnswer", sessionId=bid, allow=False)
denied = wait(lambda: (str(cdp_eval(port, "dialogs.html", "window.__answer")).startswith("denied")) or None, 25)
check("15. Block reaches the page as a real getUserMedia rejection", bool(denied),
      cdp_eval(port, "dialogs.html", "window.__answer"))

# --- 5. Find in page -------------------------------------------------------------------
ctl("browser.close", sessionId=bid)
bid = ctl("browser.create", url=f"http://127.0.0.1:{plain}/find.html")["sessionId"]
wait(lambda: ("find.html" in address(bid)) or None, 40)

ctl("automation.browserFind", sessionId=bid, text="order")
wait(lambda: ((ctl("automation.browserFind", sessionId=bid) or {}).get("active") or 0) or None, 20)
r = ctl("automation.browserFind", sessionId=bid)
check("16. find counts the matches the engine found", (r.get("count") or 0) >= 4, r)
check("17. and marks one of them current", (r.get("active") or 0) >= 1, r)
first = r.get("active")
ctl("automation.browserFind", sessionId=bid, step=True)
moved = wait(lambda: (((ctl("automation.browserFind", sessionId=bid) or {}).get("active") != first) or None), 20)
check("18. Enter walks to the next match rather than restarting the search", bool(moved),
      ctl("automation.browserFind", sessionId=bid))
r = ctl("automation.browserFind", sessionId=bid, close=True)
check("19. Esc closes it", r.get("open") is False, r)

# --- 6. Esc answers the question ---------------------------------------------------------
# The card's own .cancelAction cannot be relied on: a browser pane usually hands its keys to
# the page's own view, so the key monitor takes Esc. It cancels and never proceeds — accepting
# stays a click.
ctl("browser.close", sessionId=bid)
bid = ctl("browser.create", url=page)["sessionId"]
wait(lambda: ("dialogs.html" in address(bid)) or None, 40)
ctl("automation.jump", sessionId=bid)          # Esc belongs to the OPEN session's pane
time.sleep(1)
ctl("automation.browserGo", sessionId=bid, url=f"{page}#confirm")
wait_ask(bid, "confirm")
ctl("automation.key", keyCode=53)              # Esc
gone = wait(lambda: (not asks(bid)) or None, 20)
check("20. Esc takes the question off the pane", bool(gone), asks(bid))
check("21. and the page reads it as a cancel",
      wait(lambda: (cdp_eval(port, "dialogs.html", "window.__answer") == "false") or None, 20),
      cdp_eval(port, "dialogs.html", "window.__answer"))

p.terminate()
for s in servers: s.shutdown()
sys.exit(result())
