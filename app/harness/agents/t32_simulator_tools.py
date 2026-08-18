import sys, time; sys.path.insert(0,".")
from lib import *
from mcpclient import MCPServer
print("=== T32: the simulator tool surface names its session, like the browser's ===")

# Schemas only, and deliberately: booting a device takes tens of seconds and depends on which
# runtimes this machine has installed, and none of that is what changed. What changed is the
# contract — simulator_focus is gone and every tool that acts on a device requires a sessionId,
# the same removal ADR-0011 stage five made to the browser and for the same reason: one server
# process serves a whole agent INCLUDING its sub-agents, so a process-wide current-session
# pointer is one variable several agents write.

kill_all(); repo = fresh_repo(); sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t32.log"); ctl = Ctl(sock, repo)
time.sleep(2)

env = ctl("automation.mcpLaunchEnv").get("env", {})
import json
registered = json.loads(env.get("SYNTH_MCP_CLAUDE", "{}")).get("mcpServers", {})
if "synth-simulator" not in registered:
    # Synth only registers it when this machine has simulator runtimes at all.
    skip("no simulator support on this machine, so Synth registers no synth-simulator server")

mcp = MCPServer(env, server="synth-simulator").__enter__()

check("1. simulator_focus is gone", "simulator_focus" not in mcp.tools, sorted(mcp.tools))

acts = ["simulator_tap", "simulator_swipe", "simulator_type", "simulator_press_button",
        "simulator_screenshot", "simulator_describe", "simulator_launch", "simulator_terminate",
        "simulator_install", "simulator_open_url", "simulator_rotate", "simulator_shake",
        "simulator_close"]
missing = [t for t in acts if t not in mcp.tools]
check("2. every tool that acts on a device is present", not missing, missing)
unrequired = [t for t in acts if "sessionId" not in mcp.required(t)]
check("3. and every one of them REQUIRES sessionId", not unrequired, unrequired)

# The two that name no session: one lists this worktree's sessions, one lists the machine's
# devices. Requiring a session on either would be asking for the answer to get the question.
for i, name in enumerate(("simulator_list", "simulator_devices"), start=4):
    check(f"{i}. {name} needs no session", not mcp.required(name), mcp.required(name))

# A tool called without one is refused by the protocol, not by the tool — which is what makes
# the requirement real rather than advisory.
out, err = mcp.call("simulator_screenshot")
check("6. a call with no sessionId is refused", err and "sessionId" in out, out[:200])

mcp.close()
p.terminate()
sys.exit(result())
