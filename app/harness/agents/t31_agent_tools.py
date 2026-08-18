import json, os, pathlib, re, sys, time; sys.path.insert(0,".")
from lib import *
from mcpclient import MCPServer
print("=== T31: the browser tool surface an agent is handed (ADR-0011 stage five) ===")

# Spoken to the server directly rather than through an agent (see mcpclient.py): what is under
# test is the contract — which parameters are required, what a ref does after a re-render, what
# a screenshot returns — and a model's choice of arguments is not evidence about any of that.

PAGE = """<!doctype html><title>TOOLS</title><body>
<h1 id="hero">tools</h1>
<button id="cta">Click me</button>
<div id="menu" style="display:none">Hidden menu</div>
<button id="hover" onmouseover="document.getElementById('menu').style.display='block'">Hover me</button>
<select id="pick"><option value="a">Apple</option><option value="b">Banana</option></select>
<input id="field">
<div id="typed"></div>
<div id="late"></div>
<div style="height:2400px"></div>
<div id="bottom">the bottom</div>
<script>
  document.getElementById('cta').onclick = () => { document.getElementById('typed').textContent = 'clicked'; };
  document.getElementById('field').addEventListener('keydown', (e) => {
    if (e.key === 'Escape') document.getElementById('typed').textContent = 'escaped';
  });
  setTimeout(() => { document.getElementById('late').textContent = 'arrived late'; }, 1500);
  fetch('/data.json').then((r) => r.json()).then((j) => { window.__fetched = j.ok; });
</script></body>"""


def serve(directory):
    import socket as _s, subprocess
    s = _s.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    proc = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"],
                            cwd=str(directory), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try: _s.create_connection(("127.0.0.1", port), timeout=0.5).close(); break
        except OSError: time.sleep(0.1)
    return proc, port


kill_all(); repo = fresh_repo()
(pathlib.Path(repo) / "tools.html").write_text(PAGE)
(pathlib.Path(repo) / "data.json").write_text('{"ok": "fetched"}')
sd = seed_state(repo)
server, http_port = serve(repo)
p, sock = launch(sd, f"{H}/t31.log"); ctl = Ctl(sock, repo)
time.sleep(2)
page = f"http://127.0.0.1:{http_port}/tools.html"

env = ctl("automation.mcpLaunchEnv").get("env", {})
mcp = MCPServer(env).__enter__()

# --- 1. The removals -------------------------------------------------------------------
check("1. browser_focus is gone", "browser_focus" not in mcp.tools, sorted(mcp.tools))
acts = ["browser_navigate", "browser_click", "browser_type", "browser_hover", "browser_press_key",
        "browser_select_option", "browser_scroll", "browser_wait_for", "browser_snapshot",
        "browser_screenshot", "browser_evaluate", "browser_console", "browser_network",
        "browser_viewport", "browser_device_mode", "browser_cookies", "browser_reload",
        "browser_back", "browser_forward", "browser_record_start", "browser_record_stop"]
missing = [t for t in acts if t not in mcp.tools]
check("2. every page tool is present", not missing, missing)
unrequired = [t for t in acts if "sessionId" not in mcp.required(t)]
check("3. and every one of them REQUIRES sessionId — there is no ambient session to inherit",
      not unrequired, unrequired)

out, err = mcp.call("browser_create", url=page)
sid = json.loads(out).get("sessionId")
check("4. browser_create opens a session", bool(sid) and not err, out)

# --- 2. Refs -----------------------------------------------------------------------------
snap, err = mcp.call("browser_snapshot", sessionId=sid)
refs = dict(re.findall(r'^\s*-\s*(\S+)[^\n]*\[ref=(e\d+)\]', snap, re.M))
check("5. the snapshot stamps a ref on every element", len(refs) >= 3 and not err, snap[:200])
cta = re.search(r'button "Click me" \[ref=(e\d+)\]', snap)
check("6. and the ref is attached to the element you read", bool(cta), snap[:400])

out, err = mcp.call("browser_click", sessionId=sid, ref=cta.group(1))
check("7. clicking a ref clicks that element", not err, out)
check("8. the page saw it",
      mcp.call("browser_evaluate", sessionId=sid,
               expression="document.getElementById('typed').textContent")[0].strip('"') == "clicked")

# A ref belongs to the snapshot that issued it. After a reload the element is a different
# object, and a ref that quietly resolved to it would be the failure mode worth avoiding.
mcp.call("browser_reload", sessionId=sid)
stale, err = mcp.call("browser_click", sessionId=sid, ref=cta.group(1))
check("9. a ref that expired says so, and says to re-snapshot",
      err and "re-render" in stale and "browser_snapshot" in stale, stale)
check("10. and says nothing was acted on", "Nothing was acted on" in stale, stale)

# Selectors keep working, because the agent wrote the page it is testing.
out, err = mcp.call("browser_click", sessionId=sid, selector="#cta")
check("11. a CSS selector still clicks", not err, out)

# --- 3. The five verbs -------------------------------------------------------------------
out, err = mcp.call("browser_hover", sessionId=sid, selector="#hover")
check("12. hover reaches a menu that only exists on hover",
      not err and mcp.call("browser_evaluate", sessionId=sid,
                           expression="getComputedStyle(document.getElementById('menu')).display")[0].strip('"') == "block",
      out)

mcp.call("browser_click", sessionId=sid, selector="#field")
out, err = mcp.call("browser_press_key", sessionId=sid, key="Escape", selector="#field")
check("13. a key press reaches the element",
      not err and mcp.call("browser_evaluate", sessionId=sid,
                           expression="document.getElementById('typed').textContent")[0].strip('"') == "escaped",
      out)

out, err = mcp.call("browser_select_option", sessionId=sid, selector="#pick", labels=["Banana"])
check("14. a native <select> can be changed — the one control a click cannot reach",
      not err and mcp.call("browser_evaluate", sessionId=sid,
                           expression="document.getElementById('pick').value")[0].strip('"') == "b",
      out)

out, err = mcp.call("browser_scroll", sessionId=sid, to="bottom")
check("15. scrolling to the bottom moves the page — what a lazy list waits for",
      not err and "y=" in out and not out.endswith("y=0"), out)

out, err = mcp.call("browser_wait_for", sessionId=sid, text="arrived late", timeout=8000)
check("16. wait_for waits for something that arrives a beat later", not err, out)
out, err = mcp.call("browser_wait_for", sessionId=sid, text="never appears", timeout=1500)
check("17. and reports a real timeout as one", err and "did not reach the condition" in out, out)

# --- 4. Capture goes to disk -------------------------------------------------------------
out, err = mcp.call("browser_screenshot", sessionId=sid)
shot = out.splitlines()[0] if out else ""
check("18. a screenshot returns a path, not an image", not err and shot.endswith(".png")
      and os.path.exists(shot), out)
check("19. and no image block unless one is asked for",
      mcp.images("browser_screenshot", sessionId=sid) == 0)
check("20. inline:true returns the image as well",
      mcp.images("browser_screenshot", sessionId=sid, inline=True) == 1)
out, err = mcp.call("browser_screenshot", sessionId=sid, selector="#cta")
element = out.splitlines()[0]
check("21. an element can be captured on its own",
      not err and os.path.getsize(element) < os.path.getsize(shot), out)

# --- 5. Network ---------------------------------------------------------------------------
mcp.call("browser_reload", sessionId=sid)
mcp.call("browser_wait_for", sessionId=sid, expression="window.__fetched === 'fetched'", timeout=8000)
listing, err = mcp.call("browser_network", sessionId=sid, filter="data.json")
check("22. the network log has the page's own fetch in it",
      not err and "data.json" in listing and " 200 " in listing.replace("  ", " "), listing[:300])
# The FIRST matching entry: a reload re-requests the same URL and the later ones come back
# from cache with no body, which is a true answer about a different request than this asks about.
rows = [l for l in listing.splitlines() if l.startswith("r")]
entry = re.search(r'^(r\d+)\s', rows[0])
dump, err = mcp.call("browser_network", sessionId=sid, request=entry.group(1))
path = [l for l in dump.splitlines() if l.startswith("/")][0]
check("23. naming one writes its headers and body to a file", not err and os.path.exists(path), dump)
body = open(path).read()
check("24. which holds the request headers and the response body, and the body is NOT inline",
      "--- request headers ---" in body and '{"ok": "fetched"}' in body
      and '{"ok": "fetched"}' not in dump, dump[:200])

# --- 6. Free viewport ---------------------------------------------------------------------
out, err = mcp.call("browser_viewport", sessionId=sid, width=1440, height=900)
check("25. the agent can lay the page out at a desktop breakpoint no phone covers",
      not err and json.loads(out).get("width") == 1440, out)
inner = mcp.call("browser_evaluate", sessionId=sid, expression="window.innerWidth")[0]
check("26. and the page really is that wide", inner.strip() == "1440", inner)
out, err = mcp.call("browser_viewport", sessionId=sid, reset=True)
check("27. reset gives the pane's own viewport back",
      not err and json.loads(out).get("override") is None
      and mcp.call("browser_evaluate", sessionId=sid, expression="window.innerWidth")[0].strip() != "1440",
      out)

mcp.call("browser_close", sessionId=sid)
mcp.close()
p.terminate()
server.terminate()
sys.exit(result())
