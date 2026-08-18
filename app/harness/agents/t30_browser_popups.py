import sys, time; sys.path.insert(0,".")
from lib import *
from askserver import start_all
print("=== T30: window.open is a transient window, and right-click has a menu ===")

# The two surfaces stage five moved out of the sidebar and into the OS. A popup used to become
# a permanent browser session — litter behind every OAuth flow, and a dead row whenever the
# popup closed itself — and the right-click menu did not exist at all.

kill_all(); repo = fresh_repo(); sd = seed_state(repo)
plain, https, auth, servers = start_all(f"{H}/pages")
p, sock = launch(sd, f"{H}/t30.log"); ctl = Ctl(sock, repo)
time.sleep(2)

opener = f"http://127.0.0.1:{plain}/opener.html"
bid = ctl("browser.create", url=opener)["sessionId"]
wait(lambda: (("opener.html" in ((ctl("automation.state", sessionId=bid) or {}).get("address") or "")) or None), 40)
port = instance_json(p.pid).get("cdpPort")
rows_before = len(ctl("browser.list").get("sessions", []))
targets_before = len(cdp_pages(port))

# --- 1. The popup opens, and it is not a session ---------------------------------------
check("1. the click was dispatched as trusted input",
      cdp_click(port, "opener.html", "#go") == "CLICKED")
popped = wait(lambda: next((t for t in cdp_pages(port) if "popped.html" in t.get("url", "")), None), 30)
check("2. window.open really opened a page", bool(popped), [t.get("url") for t in cdp_pages(port)])
check("3. and it left no row in the sidebar — it is a window, not a session",
      len(ctl("browser.list").get("sessions", [])) == rows_before,
      ctl("browser.list").get("sessions"))
check("4. the engine is hosting one more page than before",
      len(cdp_pages(port)) == targets_before + 1, len(cdp_pages(port)))

# The popup is a window Synth opens rather than one the engine hands over, because letting CEF
# create it hangs the opener's renderer on this embedding (see the note in CEFShim.mm). The
# named cost of that: the page cannot close a window it did not itself open, so
# window.close() from the flow is ignored and the window is the user's to close. Not asserted
# here — a gate that pins a limitation in place is a trap — but recorded so the next person
# reading this suite knows it was measured rather than missed.

# --- 2. Right-click has a menu ----------------------------------------------------------
# A driven build never puts a native menu on screen, so what is asserted is the model it built
# — which is the part with judgement in it.
menu_page = f"http://127.0.0.1:{plain}/menu.html"
ctl("automation.browserGo", sessionId=bid, url=menu_page)
wait(lambda: (("menu.html" in ((ctl("automation.state", sessionId=bid) or {}).get("address") or "")) or None), 40)

def menu(selector):
    cdp_click(port, "menu.html", selector, button="right")
    return wait(lambda: (ctl("automation.browserContextMenu", sessionId=bid) or {}).get("items") or None, 20) or []

titles = lambda items: [i["title"] for i in items if not i["separator"]]

page_menu = menu("#hero")
check("5. right-clicking the page offers history, reload and the inspector",
      {"Back", "Forward", "Reload", "Inspect Element"} <= set(titles(page_menu)), titles(page_menu))

link_menu = menu("#link")
check("6. right-clicking a link offers the two things this pane can do with one",
      {"Open Link in Default Browser", "Copy Link Address"} <= set(titles(link_menu)),
      titles(link_menu))
check("7. and not the ones it cannot — there is no tab strip and downloads are blocked",
      not any(t.startswith("Open Link in New") or t.startswith("Save ") for t in titles(link_menu)),
      titles(link_menu))

field_menu = menu("#field")
check("8. right-clicking a text field offers the editing verbs",
      {"Cut", "Copy", "Paste", "Select All"} <= set(titles(field_menu)), titles(field_menu))

# --- 3. Nothing outlives the app --------------------------------------------------------
# A surviving CEF process owns the profile singleton and silently absorbs the next launch
# (spike LEARNINGS), and a popup window's browser is not in the session table — so this is the
# one thing about it that has to be checked rather than assumed.
p.terminate(); p.wait(timeout=60)
time.sleep(4)
survivors = sh(f"pgrep -f '{APP}/Contents/Frameworks'")
check("9. quitting takes the popup's engine processes with it", not survivors, survivors)

for s in servers: s.shutdown()
sys.exit(result())
