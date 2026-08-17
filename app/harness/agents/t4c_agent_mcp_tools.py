"""Every hosted agent really loads the bundled MCP servers off a launch that wrote no file.

t4a proves the app builds the right registration and t4b proves one agent (opencode) drives the
browser with it. Between them sat the gap this closes: for Claude Code and `agy` the chain was
only ever asserted up to "our registration was on the command line", which is not the claim.
Since 2026-08-17 the registration IS the launch — `--mcp-config` for claude,
`.agents/mcp_config.json` in the `--add-dir` dir for agy — so a break anywhere in
decorate → env → shim → agent leaves the agent with no tools and nothing else to say so.

The signal is the server *process*. An agent that has read our registration spawns
`node <sandbox>/browser-mcp/server.mjs` itself; one that hasn't, doesn't. It is deterministic,
costs no model turn, and is attributable because each agent is run alone and the channel's
sandbox path is in the command line (the stable channel's servers can't be mistaken for the dev
channel's). Claude additionally goes the whole way to a tool call, because the flag route is the
newest and the cheapest of the three to drive.

`agy` needs a signed-in CLI and is skipped without one.
"""
import sys, time, pathlib; sys.path.insert(0, ".")
from lib import *

print("=== T4c: every agent spawns the bundled MCP servers, with nothing on disk ===")

SERVER = "Synth Dev/browser-mcp/server.mjs"

def servers_up():
    """Live `synth-browser` server processes belonging to THIS channel's sandbox."""
    out = sh(f"ps -Ao command= | grep '{SERVER}' | grep -v grep || true")
    return [l for l in out.splitlines() if l.strip()]

def row_live(ctl, agent, gates=False, secs=60):
    sid = ctl("automation.newAgent", agent=agent)["sessionId"]
    live = wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 8)
    # A path Claude or agy has never seen opens on a trust prompt and fires no hook until it is
    # answered — the path's doing, not ours (there is no .mcp.json left to approve).
    for _ in range(4 if gates else 0):
        if live: break
        ctl("automation.key", keyCode=36, chars="\r")
        live = wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 20)
    return sid, (live or wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), secs))

kill_all(); repo = fresh_repo()
(pathlib.Path(repo) / "second.html").write_text("<!doctype html><title>SECOND PAGE</title><h1>second</h1>")
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t4c.log"); ctl = Ctl(sock, repo)
time.sleep(3)   # let the launch config settle before any agent starts

check("1. no MCP config file in the worktree", not any(
    (pathlib.Path(repo) / f).exists() for f in [".mcp.json", "opencode.json", ".agents/mcp_config.json"]))
check("2. and no server running before any agent starts", not servers_up(), servers_up())

# --- Claude Code: the `--mcp-config` route, all the way to a tool call ------------------------
sid, live = row_live(ctl, "claudeCode", gates=True)
check("3. Claude row live", bool(live))
check("4. Claude spawned the bundled browser server off the flag alone",
      bool(wait(lambda: servers_up() or None, 60)), servers_up())

r = ctl("browser.create", url=f"file://{repo}/index.html", ownerSessionId=sid)
bid = r.get("sessionId")
addr = wait(lambda: ((ctl("automation.state", sessionId=bid) or {}).get("address") or None), 40)
check("5. browser mounted on page 1, owned by the Claude row", bool(addr) and "index.html" in addr, addr)
ctl("automation.deliver", sessionId=sid, text=(
    f"Use your synth-browser MCP tools. First call browser_list to find the open Synth browser "
    f"session. Then call browser_navigate to send that browser to file://{repo}/second.html . "
    f"Do not ask me any questions; just call the tools, then reply DONE."))
def addr_now():
    return (ctl("automation.state", sessionId=bid) or {}).get("address") or ""
moved = None
for _ in range(6):
    moved = wait(lambda: ("second.html" in addr_now()) or None, 30, 0.5)
    if moved: break
    # A permission prompt for a tool call is a keypress; a Return at an agent with nothing to
    # confirm costs an empty turn, not a wrong one.
    ctl("automation.key", keyCode=36, chars="\r")
check("6. the Claude agent navigated the real browser through an MCP tool call", bool(moved), addr_now())
p.terminate(); time.sleep(2); kill_all()
check("7. the server dies with the session that spawned it",
      not wait(lambda: (not servers_up()) and None, 5) and not servers_up(), servers_up())

# --- opencode: the `OPENCODE_CONFIG_CONTENT` route, merged by the shim ------------------------
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t4c-oc.log"); ctl = Ctl(sock, repo)
time.sleep(3)
sid, live = row_live(ctl, "opencode")
check("8. opencode row live", bool(live))
check("9. opencode spawned the bundled browser server off the env alone",
      bool(wait(lambda: servers_up() or None, 60)), servers_up())
p.terminate(); time.sleep(2); kill_all()

# --- agy: the `.agents/mcp_config.json` inside the --add-dir workspace ------------------------
require_agy_auth()
agy_trust(repo)          # the keypress a user makes once per worktree
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t4c-agy.log"); ctl = Ctl(sock, repo)
time.sleep(3)
# agy spends its first seconds on a sign-in spinner; live means the TUI reached its input box.
sid, live = row_live(ctl, "antigravity", secs=90)
check("10. agy row live", bool(live))
# Unlike the other two, agy starts its servers lazily — a row that never takes a turn never
# spawns one — so the probe is a turn that has nothing to do with the browser. Building the
# request is what makes it connect, which is exactly the assertion: the registration was read.
check("11. agy takes a turn",
      ctl("automation.deliver", sessionId=sid, text="Reply with exactly SYNTHOK and nothing else.")
      .get("ok", False))
# agy loads workspace customizations from every dir it is given, added dirs included — this is
# the whole reason its registration could leave the user's repo.
check("12. agy spawned the bundled browser server from the injected workspace",
      bool(wait(lambda: servers_up() or None, 120)), servers_up())
p.terminate()
sys.exit(result())
