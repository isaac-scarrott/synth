import sys, time, json, pathlib; sys.path.insert(0,".")
from lib import *
print("=== T4a: MCP servers reach every agent WITHOUT a file in the worktree ===")
kill_all(); repo = fresh_repo(); sd = seed_state(repo)

# Two files planted before launch, exactly as an upgrade from a build that still wrote them
# finds: one Synth's own (must be swept up), one the user has since made theirs (must survive).
stranded = pathlib.Path(repo) / ".mcp.json"
stranded.write_text(json.dumps({"mcpServers": {"synth-browser": {"command": "node", "args": ["/stale/server.mjs"]}}}))
theirs = pathlib.Path(repo) / "opencode.json"
theirs.write_text(json.dumps({"mcp": {"my-own-server": {"type": "local", "command": ["node", "x.mjs"]}}}))

p, sock = launch(sd, f"{H}/t4a.log"); ctl = Ctl(sock, repo)
time.sleep(3)  # the launch config syncs on the autosave cadence

check("1. no .mcp.json written into the worktree", not stranded.exists())
check("2. no opencode.json written into the worktree",
      json.loads(theirs.read_text()).get("mcp", {}).get("synth-browser") is None)
check("3. a config that became the user's is left alone",
      "my-own-server" in json.loads(theirs.read_text()).get("mcp", {}))
check("4. no .agents/mcp_config.json written into the worktree",
      not (pathlib.Path(repo) / ".agents/mcp_config.json").exists())
# The whole point: a user repo ignores none of these names, so anything Synth leaves here is
# untracked noise in the user's own `git status` forever. The one file left is the one this
# suite planted as the user's, which is exactly what should survive.
untracked = [l.split(maxsplit=1)[1] for l in
             subprocess.run(["git", "status", "--porcelain", "-uall"], cwd=str(repo),
                            capture_output=True, text=True).stdout.splitlines() if l.strip()]
check("5. nothing untracked but the user's own file",
      set(untracked) == {"opencode.json"}, untracked)

# The launch env IS the registration now — this is what the PTY hands every agent.
env = ctl("automation.mcpLaunchEnv").get("env", {})
claude = json.loads(env.get("SYNTH_MCP_CLAUDE", "{}")).get("mcpServers", {})
oc = json.loads(env.get("SYNTH_MCP_OPENCODE", "{}")).get("mcp", {})
agy = json.loads(env.get("SYNTH_MCP_AGY", "{}")).get("mcpServers", {})
check("6. Claude's schema: mcpServers.synth-browser.{command,args}",
      claude.get("synth-browser", {}).get("command") == "node"
      and "server.mjs" in " ".join(claude.get("synth-browser", {}).get("args", [])), claude)
check("7. opencode's schema: type=local + command array",
      oc.get("synth-browser", {}).get("type") == "local"
      and isinstance(oc.get("synth-browser", {}).get("command"), list), oc)
check("8. agy takes Claude's schema", agy.get("synth-browser", {}).get("command") == "node", agy)
# The server discovers the app through <sandbox>/instances and has no other way to learn which
# channel installed it, so EVERY agent's entry must carry the sandbox — a dev build whose agents
# read "Synth/instances" finds nothing, or finds a running stable Synth and drives its browser.
sandbox = str(support_dir())
check("9. every agent's entry carries this channel's sandbox",
      all(e.get("SYNTH_SUPPORT_DIR") == sandbox for e in
          [claude.get("synth-browser", {}).get("env", {}),
           oc.get("synth-browser", {}).get("environment", {}),
           agy.get("synth-browser", {}).get("env", {})]), sandbox)
check("10. every agent's entry names this worktree (no CLAUDE_PROJECT_DIR to fall back on)",
      all(e.get("SYNTH_WORKTREE") == str(repo) for e in
          [claude.get("synth-browser", {}).get("env", {}),
           oc.get("synth-browser", {}).get("environment", {}),
           agy.get("synth-browser", {}).get("env", {})]), str(repo))
# A path Synth doesn't manage gets nothing: the servers scope every tool to a managed worktree.
check("11. no servers offered outside a managed worktree",
      ctl("automation.mcpLaunchEnv", worktree=str(pathlib.Path(repo).parent)).get("ok") is not True)

inst = instance_json(p.pid)
# the CDP port is bound lazily, by the first browser session — the MCP server polls for it
check("12. no CDP port before any browser session (bound lazily)", inst.get("cdpPort", 0) == 0, f"cdpPort={inst.get('cdpPort')}")
ctl("browser.create", url=f"file://{repo}/index.html")
port = wait(lambda: instance_json(p.pid).get("cdpPort") or None, 40)
check("13. CDP port appears once a browser session mounts", bool(port), f"cdpPort={port}")
real = os.path.realpath(str(repo))
paths = [os.path.realpath(x) for x in instance_json(p.pid).get("worktreePaths", [])]
check("14. instance advertises the worktree the MCP server keys on", real in paths, paths)

# Does a real opencode connect the browser server off nothing but that env? This is the shim's
# job in production (it merges SYNTH_MCP_OPENCODE into OPENCODE_CONFIG_CONTENT); here the gate
# hands opencode the same variable directly, so a break in the config's SHAPE still fails.
oenv = dict(os.environ); oenv["PATH"] = OPENCODE_PATH + ":" + oenv["PATH"]
oenv["OPENCODE_CONFIG_CONTENT"] = env.get("SYNTH_MCP_OPENCODE", "{}")
for k in ["CLAUDECODE","CLAUDE_CODE_SESSION_ID","CLAUDE_CODE_CHILD_SESSION"]: oenv.pop(k, None)
srv = subprocess.Popen(["opencode","serve","--port","4899","--hostname","127.0.0.1"],
                       cwd=str(repo), env=oenv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
import urllib.request
def get(path):
    try: return json.loads(urllib.request.urlopen(f"http://127.0.0.1:4899{path}", timeout=4).read())
    except Exception: return None
wait(lambda: get("/global/health"), 30)
st = wait(lambda: (get("/mcp") or {}).get("synth-browser") or None, 40)
check("15. opencode connects the bundled browser MCP server from the env alone",
      st and st.get("status") == "connected", st)
srv.terminate(); p.terminate()
sys.exit(result())
