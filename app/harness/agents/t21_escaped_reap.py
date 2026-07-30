import sys, uuid, json, pathlib, subprocess, time; sys.path.insert(0, ".")
from lib import *
import lib

print("=== T21: a session reaps what escaped its process group ===")

# The escape this exists for: an interactive shell puts every background job in its OWN process
# group, so the `killpg` teardown never reaches it. (Claude Code's Bash tool does the same thing
# deliberately with setsid; `&` at a zsh prompt is the same shape and needs no agent to produce.)
#
# The reaper only touches processes working inside a folder Synth created, so the branch has to
# live under the real worktree root — a repo in the harness temp dir is correctly ignored, which
# is why every other suite runs with this code inert.
WT = pathlib.Path(WT_ROOT) / f"t20-{uuid.uuid4().hex[:8]}"
checkout = WT / "checkout"
checkout.mkdir(parents=True)
repo = str(checkout)
# The channel's support dir is "Synth Dev": every shell-out survives the space, and the state file
# needs a percent-encoded URI rather than the bare f"file://{path}" seed_state builds.
sh(f"git -C '{repo}' init -q && git -C '{repo}' config user.email t@t.co && git -C '{repo}' config user.name t")
(checkout / "README.md").write_text("hello\n")
sh(f"git -C '{repo}' add -A && git -C '{repo}' commit -qm init")

state = {
    "version": 1,
    "workspaces": [{
        "id": str(uuid.uuid4()), "name": "repo", "url": checkout.as_uri(), "colorIndex": 0,
        "branches": [{
            "id": str(uuid.uuid4()), "name": sh(f"git -C '{repo}' branch --show-current"),
            "worktreeURL": checkout.as_uri(), "lastActivity": "now", "sessions": [],
        }],
    }],
    "expanded": [],
}
sd = pathlib.Path(lib.H) / "state-t20"
sh(f"rm -rf '{sd}'"); sd.mkdir(parents=True)
(sd / "state.json").write_text(json.dumps(state))

p, sock = launch(sd, f"{lib.H}/t20.log")
ctl = Ctl(sock, repo)

# A scratch terminal runs in the branch's worktree and closes through TerminalManager.terminate —
# the same teardown a session row uses, reached without needing a rendered pane.
opened = wait(lambda: ctl("automation.scratch", action="open").get("open") or None, 20)
check("1. scratch terminal open in the worktree", bool(opened))

# `nohup … & disown` is the shape that actually survives: nohup ignores the SIGHUP the closing PTY
# sends, and disown drops the job from zsh's table so the shell doesn't HUP it on exit either. A
# bare `sleep 900 &` proves nothing here — zsh reaps its own jobs, so it dies with or without this
# code, and the test would pass for the wrong reason.
#
# It has to be a user binary, not a system one. macOS strips the environment out of
# KERN_PROCARGS2 for SIP-protected platform binaries, so /bin/sleep could never carry a readable
# stamp (and a copy of it won't run at all — the signature doesn't survive the move). Every
# process this reaper actually exists for — node, python, the dev servers holding the memory —
# is a user binary whose stamp reads back fine.
time.sleep(3)   # the paste is only read once the login shell has reached a prompt
ctl("automation.scratch", action="run",
    text=f"nohup {sys.executable} -c 'import time; time.sleep(900)' >/dev/null 2>&1 & disown")


def escaped():
    """Live marker processes whose cwd is inside our worktree, with their process group."""
    out = subprocess.run(["ps", "-axo", "pid=,pgid=,command="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        if "time.sleep(900)" not in line or "ps -axo" in line:
            continue
        f = line.split()
        pid = int(f[0])
        cwd = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                             capture_output=True, text=True).stdout
        if str(WT) in cwd:
            found.append((pid, int(f[1])))
    return found


job = wait(lambda: escaped() or None, 30)
check("2. the background job is running in the worktree", bool(job), job)

# Its own process group is precisely the blind spot: killpg on the session's group cannot see it.
check("3. it left the session's process group", bool(job) and job[0][0] == job[0][1],
      f"job pgid={job[0][1]}" if job else "")

ctl("automation.scratch", action="close")
ctl("automation.scratch", action="confirm")

gone = wait(lambda: (not escaped()) or None, 30)
check("4. closing the terminal reaps it", bool(gone),
      "reaped" if gone else f"still alive: {escaped()}")

# Nothing else in the app can reach this process, so the reaper's own record is the proof that it
# died on purpose rather than by some path that would have got it anyway.
logged = subprocess.run(
    ["/usr/bin/log", "show", "--last", "5m", "--style", "compact",
     "--predicate", 'subsystem == "io.github.isaac-scarrott.synth" AND category == "reaper"'],
    capture_output=True, text=True).stdout
check("5. the reaper is what killed it", str(job[0][0]) in logged if job else False,
      next((l.split("reaping")[-1].strip() for l in logged.splitlines() if "reaping" in l), "no reap logged"))

p.terminate()
sh(f"rm -rf '{WT}'")
sys.exit(result())
