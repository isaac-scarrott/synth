import sys, time, pathlib; sys.path.insert(0,".")
from lib import *
from mcpclient import MCPServer
print("=== T41: a browser nobody can see stops rendering ===")
# A page off screen — booted by an agent and never opened, or navigated away from — used to
# report itself visible and run its animations at full frame rate, so a handful of agent
# browsers kept the GPU process busy with frames no one would see.
kill_all(); repo = fresh_repo()
spin = ("<!doctype html><title>{t}</title><style>@keyframes s{{to{{transform:rotate(1turn)}}}}"
        "div{{width:40px;height:40px;background:red;animation:s 1s linear infinite}}</style><div></div>"
        "<button onclick=\"this.textContent='clicked'\">go</button>")
(pathlib.Path(repo) / "a.html").write_text(spin.format(t="A"))
(pathlib.Path(repo) / "b.html").write_text(spin.format(t="B"))
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t41.log"); ctl = Ctl(sock, repo)

FRAMES = ("new Promise(r => { let n = 0; const f = () => { n++; requestAnimationFrame(f) };"
          " requestAnimationFrame(f); setTimeout(() => r(document.visibilityState + ':' + n), 1000) })")
# A bare Runtime.evaluate, not cdp_eval: Playwright's attach turns on focus emulation, which
# makes every page it touches report itself visible — the very thing under test.
RAW_EVAL_JS = """
(async () => {
  const targets = await (await fetch(`http://127.0.0.1:${process.env.PORT}/json`)).json();
  const t = targets.find((t) => t.type === 'page' && t.url.includes(process.env.NEEDLE));
  if (!t) { console.log('NOPAGE'); return; }
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate',
    params: { expression: process.env.EXPR, awaitPromise: true, returnByValue: true } }));
  ws.onmessage = (m) => { const d = JSON.parse(m.data);
    if (d.id === 1) { console.log(String(d.result?.result?.value)); ws.close(); } };
})().catch((e) => console.log('ERR ' + e.message));
"""
def raw_eval(page, expr):
    env = dict(os.environ, PORT=str(port), NEEDLE=page, EXPR=expr)
    return subprocess.run(["node", "-e", RAW_EVAL_JS], capture_output=True, text=True, timeout=30,
                          env=env).stdout.strip()
def frames(page):
    out = wait(lambda: raw_eval(page, FRAMES), 20, 1) or ""
    state, _, n = out.partition(":")
    return state, int(n) if n.isdigit() else -1, out

a = ctl("browser.create", url=f"file://{repo}/a.html").get("sessionId")
b = ctl("browser.create", url=f"file://{repo}/b.html").get("sessionId")
check("1. two agent-style browsers created, neither opened", bool(a and b))
port = wait(lambda: instance_json(p.pid).get("cdpPort"), 40)
wait(lambda: cdp_eval(port, "a.html", "1") == "1" and cdp_eval(port, "b.html", "1") == "1" or None, 40)

state, n, raw = frames("a.html")
check("2. a browser never opened is hidden and draws no frames", state == "hidden" and n == 0, raw)

ctl("automation.jump", sessionId=a)
time.sleep(1)
state, n, raw = frames("a.html")
check("3. opening it makes it visible and it animates", state == "visible" and n > 10, raw)
state, n, raw = frames("b.html")
check("4. the other, still unopened, stays hidden", state == "hidden" and n == 0, raw)

ctl("automation.jump", sessionId=b)
time.sleep(1)
state, n, raw = frames("a.html")
check("5. navigating away hides the page left behind", state == "hidden" and n == 0, raw)
state, n, raw = frames("b.html")
check("6. and the one now open is visible", state == "visible" and n > 10, raw)

# An agent screenshots the browser it made without ever opening it, so a hidden page must
# still answer a capture rather than hang on a frame that never comes.
CDP_SHOT_JS = CDP_EVAL_JS.replace("String(await page.evaluate(process.env.EXPR))",
                                  "(await page.screenshot({ timeout: 15000 })).length")
env = dict(os.environ, PORT=str(port), NEEDLE="a.html", EXPR="")
out = subprocess.run(["node", "-e", CDP_SHOT_JS], capture_output=True, text=True, timeout=60,
                     env=env).stdout.strip()
check("7. a hidden page still answers a screenshot", out.isdigit() and int(out) > 1000, out)

# The browser MCP server holds one connection for a whole Claude session, attached to every
# page on the engine. Playwright's default attach emulates focus, which Chromium treats as a
# capture, so every agent used to keep every page drawing whether anyone could see it or not.
mcp = MCPServer(ctl("automation.mcpLaunchEnv").get("env", {})).__enter__()
out, err = mcp.call("browser_list")
check("8. the MCP server attaches to the engine", not err and a in out, out[:200])
state, n, raw = frames("a.html")
check("9. its attach leaves a page nobody is looking at hidden", state == "hidden" and n == 0, raw)

# But a page an agent is driving has to animate: Playwright's actionability checks wait on
# requestAnimationFrame, which a hidden page never runs.
out, err = mcp.call("browser_click", sessionId=a, selector="button")
check("10. an agent can still click in a hidden page", not err, out)
state, n, raw = frames("a.html")
check("11. and it draws while the agent is driving it", state == "visible" and n > 10, raw)
state, n, raw = frames("b.html")
check("12. the open page is untouched", state == "visible" and n > 10, raw)
time.sleep(65)
state, n, raw = frames("a.html")
check("13. a minute after the agent's last call it is hidden again", state == "hidden" and n == 0, raw)
mcp.close()

p.terminate()
sys.exit(result())
