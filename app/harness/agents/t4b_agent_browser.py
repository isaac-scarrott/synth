import sys, time, pathlib; sys.path.insert(0,".")
from lib import *
print("=== T4b: a live opencode agent drives Synth's embedded browser over MCP ===")
kill_all(); repo = fresh_repo()
(pathlib.Path(repo) / "second.html").write_text("<!doctype html><title>SECOND PAGE</title><h1>second</h1>")
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t4b.log"); ctl = Ctl(sock, repo)
time.sleep(3)   # let MCPInstaller write opencode.json

page1 = f"file://{repo}/index.html"
page2 = f"file://{repo}/second.html"

# 1. an opencode row, then a browser OWNED by it (stage-four containment for an agent kind)
oc = ctl("automation.newAgent", agent="opencode")["sessionId"]
check("1. opencode row live", bool(wait(lambda: (ctl.row(oc) or {}).get("liveAgent"), 60)))

r = ctl("browser.create", url=page1, ownerSessionId=oc)
check("2. browser.create accepted, owned by the opencode row", r.get("ok"), r)
bid = r.get("sessionId")

st = wait(lambda: (ctl("automation.state", sessionId=bid) if bid else {}).get("ok") or None, 40)
check("3. browser engine mounted", bool(st))
addr = wait(lambda: ((ctl("automation.state", sessionId=bid) or {}).get("address") or None), 40)
check("4. browser is on page 1", addr and "index.html" in addr, addr)

inst = instance_json(p.pid)
check("5. CDP port now bound (browser session mounted)", inst.get("cdpPort", 0) > 0, f"cdpPort={inst.get('cdpPort')}")

blist = ctl("browser.list")
owned = [s for s in blist.get("sessions", []) if s.get("owner") == oc]
check("6. browser.list reports it owned by the agent row", bool(owned), owned)

# 2. ask the AGENT to drive it. It must find the MCP tools and navigate the real browser.
ctl("automation.deliver", sessionId=oc, text=(
    f"Use your synth-browser MCP tools. First call browser_list to find the open Synth browser "
    f"session. Then call browser_navigate to send that browser to {page2} . "
    f"Do not ask me any questions; just call the tools, then reply DONE."))
check("7. prompt delivered to the agent", True)

def addr_now():
    s = ctl("automation.state", sessionId=bid) or {}
    return s.get("address") or ""
moved = wait(lambda: ("second.html" in addr_now()) or None, 180, 0.5)
check("8. the AGENT navigated the embedded browser via MCP", bool(moved), addr_now())

title = wait(lambda: ((ctl.row(bid) or {}).get("title")) or None, 20)
check("9. the browser row renamed itself from the new page", title and "SECOND" in title.upper(), title)

p.terminate()
sys.exit(result())
