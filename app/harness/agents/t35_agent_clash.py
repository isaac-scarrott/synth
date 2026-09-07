"""A custom agent whose command a built-in already runs is offered once, not twice.

Settings has always said so on the row ("OpenCode 2 is already one of Synth's agents"), but the
warning was only words: the descriptor still reached `AgentRegistry.all`, so ⌘K carried two of
every "New OpenCode 2" and both started the same binary. The registry now leaves a clashing agent
out, which is a thing only the offer list can show — hence a driven palette rather than a unit of
the rule.

`opencode2` is the clash under test because it is a built-in command; an agent Synth cannot find
on this machine is offered zero times, and zero rows would pass a "not twice" assertion without
proving anything, so this gate wants the binary present.
"""
import sys, os, json
sys.path.insert(0, ".")
from lib import *

print("=== T35: a custom agent that duplicates a built-in's command ===")

if not os.access(os.path.expanduser("~/.opencode/bin/opencode2"), os.X_OK):
    skip("no `opencode2` CLI at ~/.opencode/bin — nothing to clash with")

kill_all()
repo = fresh_repo()
sd = seed_state(repo)
state = json.loads((sd / "state.json").read_text())
state["customAgents"] = [{"id": "custom-clash-gate", "name": "OpenCode 2",
                          "binary": "opencode2", "base": "opencode", "named": True}]
(sd / "state.json").write_text(json.dumps(state))

p, sock = launch(sd, f"{H}/t35.log")
ctl = Ctl(sock, repo)

ctl("automation.paletteOpen")
rows = ctl("automation.paletteQuery", query="new opencode").get("items", [])
check("1. the clashing agent is offered once, not once per row that claims its command",
      rows.count("New OpenCode 2") == 1, rows)
# The built-in is what survives — dropping both would lose the agent, not de-duplicate it.
check("2. the agent it clashes with is untouched", "New OpenCode" in rows, rows)

p.terminate()
sys.exit(result())
