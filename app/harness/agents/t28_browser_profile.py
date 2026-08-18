import json, os, pathlib, subprocess, sys, time; sys.path.insert(0,".")
from lib import *
print("=== T28: the browser profile is per workspace, persists, and is cleared only on demand ===")

# A cookie is the honest instrument here. It is what a login is, it is written by the page
# rather than by the harness, and it lives in the profile directory under test — so "still
# signed in after a restart" is a claim about the same bytes the feature is about.
#
# Over HTTP, not file://: Chromium gives a file: document no cookie jar at all, so the whole
# suite would measure that instead of the profile. A local server is also what a Synth browser
# session actually points at.
COOKIE_PAGE = ("<!doctype html><title>PROFILE</title>"
               "<body><h1 id='hero'>profile</h1>"
               "<script>document.cookie = 'synthprofile=' + "
               "(new URLSearchParams(location.search).get('v') || 'unset') + "
               "';path=/;max-age=86400';</script></body>")

def serve(directory):
    """A dev server for the run, on a port the OS picked. Killed at exit by the harness."""
    import socket as _s
    sock = _s.socket(); sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
    proc = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"],
                            cwd=str(directory), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            _s.create_connection(("127.0.0.1", port), timeout=0.5).close(); break
        except OSError: time.sleep(0.1)
    return proc, port

# Arguments ride the environment rather than argv: `node -e` shifts argv by one against every
# other invocation, and a silently mis-indexed needle reads as a page that isn't there.
CDP_EVAL_JS = """
const path = require('path'), os = require('os');
const PW = path.join(os.homedir(), 'Library/Application Support/Synth/browser-mcp/node_modules/playwright-core');
const { chromium } = require(PW);
(async () => {
  const b = await chromium.connectOverCDP(`http://127.0.0.1:${process.env.PORT}`);
  const pages = b.contexts().flatMap((c) => c.pages());
  const page = pages.find((p) => p.url().includes(process.env.NEEDLE));
  if (!page) { console.log('NOPAGE'); process.exit(0); }
  console.log(String(await page.evaluate(process.env.EXPR)));
  await b.close();
})().catch((e) => { console.log('ERR ' + e.message); });
"""

def cdp_eval(port, needle, expression):
    """Evaluate in the page whose URL contains `needle`, over the app's own CDP endpoint."""
    env = dict(os.environ, PORT=str(port), NEEDLE=needle, EXPR=expression)
    r = subprocess.run(["node", "-e", CDP_EVAL_JS], capture_output=True, text=True,
                       timeout=120, env=env)
    return r.stdout.strip()

kill_all()
repo = fresh_repo()
(pathlib.Path(repo) / "cookie.html").write_text(COOKIE_PAGE)
(pathlib.Path(repo) / "read.html").write_text("<!doctype html><title>READ</title><h1>read</h1>")
sd = seed_state(repo)

server, http_port = serve(repo)
page_set = f"http://127.0.0.1:{http_port}/cookie.html?v=first"
page_read = f"http://127.0.0.1:{http_port}/read.html"

# A profile root left over from an earlier run would make "persisted" unfalsifiable.
profiles = support_dir() / "BrowserProfiles"
sh(f"rm -rf '{profiles}'")

p, sock = launch(sd, f"{H}/t28.log"); ctl = Ctl(sock, repo)
time.sleep(2)

# 1. Two browsers in one branch share ONE profile directory — the shape stage five chose,
#    and the one CEF has to accept (several CefRequestContexts over one cache_path).
b1 = ctl("browser.create", url=page_set)["sessionId"]
addr = wait(lambda: ((ctl("automation.state", sessionId=b1) or {}).get("address") or None), 40)
check("1. first browser open on the cookie page", addr and "cookie.html" in addr, addr)

prof = ctl("automation.browserProfile")
check("2. the profile is named for the workspace, not the session or the branch",
      prof.get("ok") and "/shared/" in prof.get("path", "") and
      prof.get("key", "").startswith("repo-"), prof)
check("3. this instance took the persistent root", prof.get("persists"), prof)

b2 = ctl("browser.create", url=page_read)["sessionId"]
addr2 = wait(lambda: ((ctl("automation.state", sessionId=b2) or {}).get("address") or None), 40)
check("4. a second browser in the same branch also mounts (one cache_path, two contexts)",
      addr2 and "read.html" in addr2, addr2)

port = instance_json(p.pid).get("cdpPort")
wait(lambda: (cdp_eval(port, "cookie.html", "document.cookie").find("synthprofile") >= 0) or None, 30)
check("5. the page wrote its cookie",
      "synthprofile=first" in cdp_eval(port, "cookie.html", "document.cookie"))

# The second session reads the first's cookie: same origin, same profile. Two profiles would
# show nothing here, which is exactly the incognito behaviour stage five reversed.
shared = cdp_eval(port, "read.html", "document.cookie")
check("6. the OTHER session in the workspace sees it — one profile, not one per session",
      "synthprofile=first" in shared, shared)

profile_path = prof.get("path")
check("7. the profile is on disk under the workspace's own directory",
      os.path.isdir(profile_path), profile_path)

# 2. Quit, relaunch, still signed in. A unit test cannot show this; only a restart can.
p.terminate()
p.wait(timeout=60)
time.sleep(3)
check("8. the profile survived the app quitting", os.path.isdir(profile_path))

p, sock = launch(sd, f"{H}/t28b.log"); ctl = Ctl(sock, repo)
time.sleep(2)
b3 = ctl("browser.create", url=page_read)["sessionId"]
wait(lambda: ((ctl("automation.state", sessionId=b3) or {}).get("address") or None), 40)
port = instance_json(p.pid).get("cdpPort")
after = wait(lambda: (cdp_eval(port, "read.html", "document.cookie") or None), 30) or ""
check("9. the cookie is still there after a full restart — the browser has a memory",
      "synthprofile=first" in after, after)

# 3. Clearing is a user action, and it is the only thing that deletes a profile. The row's
#    own call, so the gate exercises the product path rather than a path built for it.
r = ctl("automation.clearBrowsingData")
check("10. Settings' Clear browsing data accepted", r.get("ok"), r)

# The assertion that matters is the sign-out, not the directory: a browser opened afterwards
# must not know the cookie. (The directory comes straight back — the engines rebuild on it.)
b4 = ctl("browser.create", url=page_read)["sessionId"]
wait(lambda: ((ctl("automation.state", sessionId=b4) or {}).get("address") or None), 40)
port = instance_json(p.pid).get("cdpPort")
wait(lambda: (cdp_eval(port, "read.html", "1") == "1") or None, 30)
cleared = cdp_eval(port, "read.html", "document.cookie")
check("11. a browser opened after the clear is signed out",
      "synthprofile" not in cleared, repr(cleared))

# 4. A second Synth of this channel cannot take the same root (Chromium's process singleton is
#    keyed on it), so it falls back to a throwaway one and SAYS so, rather than getting no
#    browser at all — the one place this design pays for persistence.
p2, sock2 = launch(sd, f"{H}/t28c.log")
ctl2 = Ctl(sock2, repo)
time.sleep(2)
b5 = ctl2("browser.create", url=page_read)["sessionId"]
addr5 = wait(lambda: ((ctl2("automation.state", sessionId=b5) or {}).get("address") or None), 60)
check("12. a second instance still gets a working browser", addr5 and "read.html" in addr5, addr5)
prof2 = ctl2("automation.browserProfile")
check("13. and it says its profile is the throwaway one",
      prof2.get("ok") and prof2.get("persists") is False and "/instance-" in prof2.get("path", ""),
      prof2)

p2.terminate(); p2.wait(timeout=60)
time.sleep(3)
check("14. the throwaway root went with it",
      not os.path.isdir(str(pathlib.Path(prof2.get("path", "/nonexistent")).parent)),
      prof2.get("path"))

p.terminate()
server.terminate()
sys.exit(result())
