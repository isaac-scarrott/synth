import sys, time, json, pathlib; sys.path.insert(0,".")
from lib import *
print("=== T4a: per-worktree MCP registration for BOTH agents ===")
kill_all(); repo = fresh_repo(); sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t4a.log"); ctl = Ctl(sock, repo)
time.sleep(3)  # MCPInstaller syncs on the autosave cadence

mcpjson = pathlib.Path(repo) / ".mcp.json"
ocjson  = pathlib.Path(repo) / "opencode.json"
check("1. .mcp.json written (Claude Code)", mcpjson.exists())
check("2. opencode.json written (opencode)", ocjson.exists())
if mcpjson.exists():
    m = json.loads(mcpjson.read_text())
    check("3. .mcp.json uses mcpServers.synth-browser", "synth-browser" in m.get("mcpServers", {}), list(m))
if ocjson.exists():
    o = json.loads(ocjson.read_text())
    e = o.get("mcp", {}).get("synth-browser", {})
    check("4. opencode.json uses mcp.synth-browser", bool(e), list(o))
    check("5. type=local + command array", e.get("type") == "local" and isinstance(e.get("command"), list), e.get("command"))
    check("6. SYNTH_WORKTREE injected (no CLAUDE_PROJECT_DIR for opencode)",
          e.get("environment", {}).get("SYNTH_WORKTREE") == str(repo), e.get("environment"))
    check("7. points at the installed server.mjs", "server.mjs" in " ".join(e.get("command", [])))

inst = instance_json(p.pid)
# the CDP port is bound lazily, by the first browser session — the MCP server polls for it
check("8. no CDP port before any browser session (bound lazily)", inst.get("cdpPort", 0) == 0, f"cdpPort={inst.get('cdpPort')}")
ctl("browser.create", url=f"file://{repo}/index.html")
port = wait(lambda: instance_json(p.pid).get("cdpPort") or None, 40)
check("9. CDP port appears once a browser session mounts", bool(port), f"cdpPort={port}")
real = os.path.realpath(str(repo))
paths = [os.path.realpath(x) for x in instance_json(p.pid).get("worktreePaths", [])]
check("10. instance advertises the worktree the MCP server keys on", real in paths, paths)

# does a real opencode server in that worktree connect the MCP?
env = dict(os.environ); env["PATH"] = OPENCODE_PATH + ":" + env["PATH"]
for k in ["CLAUDECODE","CLAUDE_CODE_SESSION_ID","CLAUDE_CODE_CHILD_SESSION"]: env.pop(k, None)
srv = subprocess.Popen(["opencode","serve","--port","4899","--hostname","127.0.0.1"],
                       cwd=str(repo), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
import urllib.request
def get(path):
    try: return json.loads(urllib.request.urlopen(f"http://127.0.0.1:4899{path}", timeout=4).read())
    except Exception: return None
wait(lambda: get("/global/health"), 30)
st = wait(lambda: (get("/mcp") or {}).get("synth-browser") or None, 40)
check("11. opencode connects the bundled browser MCP server", st and st.get("status") == "connected", st)
srv.terminate(); p.terminate()
sys.exit(result())
