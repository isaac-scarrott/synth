"""Antigravity detection: `agy` names two different programs, and Synth must pick the agent.

Google shipped the Antigravity CLI under the command name the Nov-2025 Antigravity IDE already
used for its GUI launcher, and on a stock login PATH the IDE's copy comes first. Resolving to it
would give a session a program that opens a window and never speaks to a hook — a row that boots,
looks fine, and reports nothing forever. The rule is structural rather than a version sniff: a
candidate whose symlink resolves inside an `.app` bundle is not the CLI.

Part 1 stages both programs on a PATH this suite controls, IDE first, and watches which one the
session actually exec's — so the answer needs neither a sign-in, a token, nor the machine to
happen to have the collision installed. Part 2 puts the real machine PATH back and asserts
Antigravity still comes out installed (its shim, the thing ⌘K and Settings read). That the real
PATH also resolves to a non-`.app` binary is proven where it can only be proven — against a live
process, in t15.
"""
import sys, pathlib, time; sys.path.insert(0, ".")
from lib import *

print("=== T14: `agy` resolves to the Antigravity CLI, never the IDE launcher ===")
require_agy()
kill_all()

# --- Part 1: two `agy`s on a PATH we control -----------------------------------------------
work = pathlib.Path(H) / "detect"
sh(f"rm -rf '{work}'")
ide_bin = work / "ide-bin"                                    # what the IDE puts on PATH
ide_app = work / "Antigravity.app/Contents/Resources/app/bin"  # what its `agy` really is
cli_bin = work / "cli-bin"
for d in (ide_bin, ide_app, cli_bin): d.mkdir(parents=True)
ran = work / "ran"

# Each stub records that it was reached and then stays alive, so the session looks like a
# running agent rather than an instant exit the app might retry. The sleep wears a distinctive
# duration purely so teardown can find it.
def stub(path, tag):
    path.write_text(f"#!/bin/sh\nprintf '{tag} %s\\n' \"$0\" >> '{ran}'\nexec /bin/sleep 61703\n")
    path.chmod(0o755)

stub(ide_app / "antigravity", "IDE")
(ide_bin / "agy").symlink_to(ide_app / "antigravity")
stub(cli_bin / "agy", "CLI")

# Synth asks the login shell for its PATH; this one answers with the staged pair and hands every
# other invocation (the PTYs) to the real zsh untouched.
probe_path = f"{ide_bin}:{cli_bin}"
fake_shell = work / "login-shell.sh"
fake_shell.write_text(f"""#!/bin/sh
for a in "$@"; do
  case "$a" in *'$PATH'*) printf '\\001%s\\001' '{probe_path}'; exit 0;; esac
done
exec /bin/zsh "$@"
""")
fake_shell.chmod(0o755)

check("0. the hazard is staged: the `.app` launcher comes first on the probed PATH",
      in_app_bundle(str(ide_bin / "agy")) and not in_app_bundle(str(cli_bin / "agy")),
      probe_path)

# Prove the stand-in shell answers Synth's probe before trusting a session to it. If it didn't,
# detection would fall through to the install hints and reach the machine's real `agy` — the one
# launch this suite must never make.
real_shell = os.environ.get("SHELL", "")
os.environ["SHELL"] = str(fake_shell)
probed = login_path_dirs()
os.environ["SHELL"] = real_shell
staged = probed == [str(ide_bin), str(cli_bin)]
check("1. the staged PATH is what a login-shell probe returns", staged, probed)

repo = fresh_repo(); sd = seed_state(repo)
env = no_browser_env()
env["SHELL"] = str(fake_shell)
# Keep the real installs out of reach on the fallback paths too, so a wrong answer can only ever
# run the harmless stub: drop every dir that carries an `agy` from the PATH the app inherits, and
# put the staged pair (IDE first, again) in front of what's left.
inherited = [d for d in [OPENCODE_PATH] + env["PATH"].split(":")
             if d and not os.path.exists(os.path.join(d, "agy"))]
env["PATH"] = ":".join([str(ide_bin), str(cli_bin)] + inherited)
p, sock = launch(sd, f"{H}/t14a.log", env_extra=env)
ctl = Ctl(sock, repo)

shims = f"/tmp/synth-shims-{p.pid}"
check("2. Antigravity counts as installed — it gets a shim beside the others",
      bool(wait(lambda: os.path.exists(f"{shims}/agy"), 30)), sh(f"ls {shims}"))
check("3. adding it left the existing agents' shims alone",
      os.path.exists(f"{shims}/claude") and os.path.exists(f"{shims}/opencode"), sh(f"ls {shims}"))

# With no shim, `agy` in the PTY would resolve on the login shell's own PATH — the same forbidden
# launch — so the session only happens once both guards hold.
if staged and os.path.exists(f"{shims}/agy"):
    sid = ctl("automation.newAgent", agent="antigravity")["sessionId"]
    check("4. the row is an antigravity row", (ctl.row(sid) or {}).get("kind") == "antigravity",
          (ctl.row(sid) or {}).get("kind"))
    mark = wait(lambda: (ran.read_text() if ran.exists() else "") or None, 40) or ""
    check("5. the session exec'd the CLI", mark.startswith("CLI "), mark.strip().replace("\n", " | "))
    check("6. the `.app` candidate was never exec'd", "IDE" not in mark,
          mark.strip().replace("\n", " | "))

p.terminate(); time.sleep(1)
sh("pkill -f 'sleep 61703'")
kill_all()

# --- Part 2: the machine's own PATH ---------------------------------------------------------
# Detection has to survive the real thing, not just the staged one. Whether this machine even
# carries the IDE is reported rather than asserted — the collision is the reason the rule exists,
# not a prerequisite for it.
cands = agy_candidates()
print(f"     candidates on this machine: {cands}")
print("     IDE launcher present and first: "
      f"{bool(cands) and in_app_bundle(cands[0])}")

repo = fresh_repo(); sd = seed_state(repo)
p2, sock2 = launch(sd, f"{H}/t14b.log", env_extra=no_browser_env())
check("7. with the real PATH, Antigravity is still detected as installed",
      bool(wait(lambda: os.path.exists(f"/tmp/synth-shims-{p2.pid}/agy"), 30)),
      sh(f"ls /tmp/synth-shims-{p2.pid}"))
check("8. its shim routes through synth-hook, like every other agent's",
      os.path.basename(os.path.realpath(f"/tmp/synth-shims-{p2.pid}/agy")) == "synth-hook",
      os.path.realpath(f"/tmp/synth-shims-{p2.pid}/agy"))
p2.terminate()
sys.exit(result())
