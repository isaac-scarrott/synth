"""Every session's login wrapper is written on demand, not once at startup.

The incident: a Synth left running from Friday to Tuesday could not open another session at all.
Every row it spawned died on the spot and parked as "Claude quit", while the rows already up kept
working — because the shell they exec'd had exec'd long ago.

`TerminalLauncher` writes its wrapper (the script that scrubs the terminal engine's identity out
of the child env before exec'ing the login shell) into the per-user temp dir, which macOS sweeps
of anything untouched for three days *while the app is still running*. The path was cached in a
`static let`, computed at the first spawn — so once the sweep took the file, every later row exec'd
a path that no longer existed, exited immediately, and was reported as the agent quitting.

So the claim worth proving against a running app is that the wrapper going missing under a live
Synth costs nothing: the next row writes it again and comes up exactly as the first one did.
Deleting the file stands in for the sweep — it is the same disappearance, on the same path, and
unlike a three-day wait it lands whenever the gate runs.
"""
import os, sys; sys.path.insert(0, ".")
from lib import *

print("=== T33: the login wrapper is rewritten on demand, not cached from startup ===")
kill_all()
repo = fresh_repo()
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t33.log")
ctl = Ctl(sock, repo)

# The app inherits TMPDIR from this process, so its NSTemporaryDirectory() is ours.
wrapper = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"synth-login-{p.pid}.sh")


# opencode rather than Claude only because it goes live without answering a trust prompt for a
# folder it has never seen (t7). The wrapper is what every row's shell is exec'd through, whatever
# it goes on to run — an agent that boots is the evidence that the shell did.
def spawn_live_row():
    sid = ctl("automation.newAgent", agent="opencode")["sessionId"]
    return sid, wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 90)


# ------------------------------------------------------ 1. the first row writes it and comes up
first, live = spawn_live_row()
check("1. a spawned row goes live", bool(live), (ctl.row(first) or {}).get("status"))
check("2. it wrote the login wrapper", os.path.exists(wrapper), wrapper)

# --------------------------------------------- 2. the sweep takes it out from under a live Synth
os.unlink(wrapper)
check("3. the wrapper is gone, as the three-day temp sweep leaves it",
      not os.path.exists(wrapper))

# ------------------------------------------------------------- 3. the next row costs it nothing
second, live2 = spawn_live_row()
check("4. the next row still goes live", bool(live2), (ctl.row(second) or {}).get("status"))
check("5. it wrote the wrapper again", os.path.exists(wrapper), wrapper)
check("6. and it stayed — no row parked on a quit card",
      not any(x["kind"] == "undo" for x in ctl("automation.notifs").get("notifs", [])))

p.terminate()
sys.exit(result())
