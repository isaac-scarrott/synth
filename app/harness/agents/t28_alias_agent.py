"""A custom agent whose command is a shell ALIAS starts, and starts instrumented.

An alias lives only inside an interactive shell, so nothing Synth spawns can see one: the app
resolves it up front (`ShellEnvironment` reads zsh's own `$aliases`), hands the shim the program
it stood for, and drops the alias inside the session PTY so it can't shadow the shim it was
resolved into. Three seams, and the first two are invisible from outside — hence `--agent-check`,
which prints the resolution the launch would use, and a driven row for the third.

`liveAgent` is the whole assertion for the launch half: it is set by Claude's SessionStart hook,
which only fires when the shim injected `--settings`. An alias that reached the real binary
directly would run perfectly well and never report a thing.

Everything runs against a throwaway ZDOTDIR, so the aliases under test are the harness's own and
the developer's shell is neither read nor needed.
"""
import sys, os, json, pathlib; sys.path.insert(0, ".")
from lib import *

print("=== T28: an agent named by a shell alias ===")

kill_all(); repo = fresh_repo()

# The real claude, not a Synth shim standing in for it: a harness run started from inside a Synth
# session inherits that session's shim PATH, and an alias pointing back at a shim is the one thing
# resolution is required to refuse.
clean_path = ":".join(d for d in os.environ["PATH"].split(":") if "synth-shims" not in d)
CLAUDE = sh(f"env -u ZDOTDIR -u SYNTH_SHIM_DIR PATH='{clean_path}' zsh -lc 'command -v claude'")
if not CLAUDE or "synth-shims" in CLAUDE: skip("claude is not installed")

# The shell the app will probe: our aliases, and nothing else of the developer's.
zdot = pathlib.Path(H) / "aliasrc"; zdot.mkdir(parents=True, exist_ok=True)
(zdot / ".zshrc").write_text(
    f"alias synthclaude={CLAUDE}\n"
    f"alias synthclaude_flagged='{CLAUDE} --model sonnet'\n"
    f"alias synthclaude_chain=synthclaude\n"
    f"alias synthclaude_frag='{CLAUDE} | tee /tmp/synth-alias-gate'\n")
alias_env = {"ZDOTDIR": str(zdot)}

def resolve(command):
    """`Synth --agent-check <command>` — the resolution a launch of it would use."""
    env = " ".join(f"{k}={v}" for k, v in alias_env.items())
    out = sh(f"{env} '{APP}/Contents/MacOS/Synth' --agent-check {command} 2>&1")
    return {l.split()[1]: " ".join(l.split()[2:]) for l in out.splitlines() if l.startswith("PASS ")}

r = resolve("synthclaude")
check("1. a plain alias resolves to the program it names",
      r.get("agent-resolved", "").endswith(f"-> {CLAUDE}"), r)
check("2. and carries no arguments of its own", r.get("agent-args") == "", r)

r = resolve("synthclaude_flagged")
check("3. an alias that pins a flag resolves to the same program",
      r.get("agent-resolved", "").endswith(f"-> {CLAUDE}"), r)
check("4. and the flag survives as the launch's leading arguments",
      r.get("agent-args") == "--model sonnet", r)

check("5. an alias naming another alias is followed to the end",
      resolve("synthclaude_chain").get("agent-resolved", "").endswith(f"-> {CLAUDE}"),
      resolve("synthclaude_chain"))

# A shell fragment is not a program: splitting it on spaces and exec'ing the pieces would run
# something the user's own shell never would, so it resolves to nothing at all.
check("6. an alias that is a shell fragment resolves to nothing", not resolve("synthclaude_frag"),
      resolve("synthclaude_frag"))
check("7. a name that is neither alias nor program resolves to nothing", not resolve("synthclaude_absent"))

# --- the launch half -------------------------------------------------------------------------
sd = seed_state(repo)
state = json.loads((sd / "state.json").read_text())
state["customAgents"] = [{"id": "custom-alias-gate", "name": "Synth Claude",
                          "binary": "synthclaude", "base": "claudeCode", "named": True}]
(sd / "state.json").write_text(json.dumps(state))

p, sock = launch(sd, f"{H}/t28.log", env_extra=alias_env); ctl = Ctl(sock, repo)
sid = ctl("automation.newAgent", agent="custom-alias-gate")["sessionId"]
check("8. a row starts for an agent whose command is only an alias", bool(sid))
live = wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 20)
for _ in range(4):          # a path Claude has never seen opens on a trust prompt
    if live: break
    ctl("automation.key", keyCode=36, chars="\r")
    live = wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 25)
check("9. and it reports as an agent — the shim ran, so the alias didn't shadow it", bool(live))

p.terminate()
sys.exit(result())
