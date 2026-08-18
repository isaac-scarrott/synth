"""What the shim hands Claude, asserted on the command line itself.

Two failures live here and neither shows up in a driven session, because both only bite the
invocations a driven session never makes. `claude setup-token` inside Synth died with
"MCP config file not found: <cwd>/setup-token": `--mcp-config` takes a LIST, so the injected
config swallowed the subcommand that followed it, and `setup-token` was missing from the set of
subcommands that pass through uninstrumented in the first place.

So this suite runs the shim directly against a fake `claude` that prints its argv — no app, no
PTY, no model turn — and then checks the shape it builds against the REAL claude's parser, which
is the only authority on what its own flags swallow.
"""
import sys, os, pathlib, subprocess, json; sys.path.insert(0, ".")
from lib import *

print("=== T29: the command line the shim builds for Claude ===")

SHIM = f"{APP}/Contents/MacOS/synth-hook"
clean_path = ":".join(d for d in os.environ["PATH"].split(":") if "synth-shims" not in d)
CLAUDE = sh(f"env -u ZDOTDIR -u SYNTH_SHIM_DIR PATH='{clean_path}' zsh -lc 'command -v claude'")

bin_dir = pathlib.Path(H) / "argvbin"; bin_dir.mkdir(parents=True, exist_ok=True)
fake = bin_dir / "fakeclaude"
fake.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\"\n"); fake.chmod(0o755)
link = bin_dir / "claude"
if link.exists() or link.is_symlink(): link.unlink()
link.symlink_to(SHIM)

MCP = '{"mcpServers":{"synth-browser":{"command":"node","args":["/tmp/server.mjs"]}}}'

def argv(*args, session=True):
    """The argv the real binary would be exec'd with, for `claude <args>` inside a session."""
    env = dict(os.environ, SYNTH_REAL_CLAUDE=str(fake), SYNTH_MCP_CLAUDE=MCP)
    env.pop("SYNTH_AGENT_MAP", None)
    if session: env["SYNTH_SESSION_ID"] = "11111111-1111-1111-1111-111111111111"
    else: env.pop("SYNTH_SESSION_ID", None)
    out = subprocess.run([str(link)] + list(args), capture_output=True, text=True, env=env)
    return out.stdout.splitlines()

# --- subcommands are not sessions -------------------------------------------------------------
# Every command the CLI answers to, hidden ones included (`claude attach|daemon|logs|
# remote-control|respawn|rm|self-hosted-runner|stop` are real and unlisted in `--help`). One of
# these missing is not a cosmetic gap: it gets a session's flags, and the ones that reject
# unknown options simply stop working inside Synth.
COMMANDS = ["agents", "attach", "auth", "auto-mode", "daemon", "doctor", "gateway", "import",
            "install", "logs", "mcp", "plugin", "plugins", "project", "remote-control", "respawn",
            "rm", "self-hosted-runner", "setup-token", "stop", "ultrareview", "update", "upgrade"]
unmodified = [c for c in COMMANDS if argv(c) == [c]]
check("1. every claude subcommand passes through untouched", unmodified == COMMANDS,
      sorted(set(COMMANDS) - set(unmodified)))
check("2. a one-shot passes through untouched", argv("-p", "hello") == ["-p", "hello"], argv("-p", "hello"))
check("3. and so does anything at all outside a Synth session",
      argv("whatever", session=False) == ["whatever"], argv("whatever", session=False))

# --- a session is instrumented ----------------------------------------------------------------
line = argv("--model", "sonnet")
check("4. a session gets its own id", "--session-id" in line, line)
check("5. the hook settings", "--settings" in line, line)
check("6. and the bundled MCP servers, off the command line", MCP in line, line)
check("7. the user's own arguments survive, at the end",
      line[-2:] == ["--model", "sonnet"], line)

# `--mcp-config <configs...>` reads every following word as another config until a flag stops it,
# so what matters is not where the injection sits but what sits after its value — and the word
# that exposed this was a bare one (`setup-token`), not a flag.
prompted = argv("fix the thing")
after_mcp = prompted[prompted.index(MCP) + 1] if MCP in prompted else ""
check("8. nothing can be read as a second MCP config: a flag follows the first",
      after_mcp.startswith("--"), [after_mcp] + prompted[-2:])

# --- the real parser has the last word --------------------------------------------------------
if not CLAUDE or "synth-shims" in CLAUDE:
    print("SKIP: claude is not installed"); sys.exit(result())
probe = subprocess.run([CLAUDE, "--mcp-config", MCP, "--settings", "{}", "doctor"],
                       capture_output=True, text=True)
check("9. claude itself parses that shape without eating the word after the config",
      "MCP config file not found" not in (probe.stdout + probe.stderr),
      (probe.stdout + probe.stderr).splitlines()[:2])
# The inverse, so the assertion above can never pass by accident: the order that shipped DOES eat it.
broken = subprocess.run([CLAUDE, "--settings", "{}", "--mcp-config", MCP, "doctor"],
                        capture_output=True, text=True)
check("10. and the order that doesn't end the list is genuinely fatal",
      "MCP config file not found" in (broken.stdout + broken.stderr),
      (broken.stdout + broken.stderr).splitlines()[:2])

sys.exit(result())
