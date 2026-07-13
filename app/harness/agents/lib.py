import json, socket, subprocess, time, os, pathlib, uuid, signal

import tempfile
# Scratch: repos, seeded state and logs for a run. Never the user's real Synth state.
H = os.environ.get("SYNTH_HARNESS_DIR") or tempfile.mkdtemp(prefix="synth-agent-gate-")
# SYNTH_APP overrides the shared pointer file, so a worktree's build can be gated
# without redirecting other checkouts' harness runs.
APP = os.environ.get("SYNTH_APP") or open("/tmp/synth-app-path.txt").read().strip()
OPENCODE_PATH = os.environ.get("SYNTH_OPENCODE_BIN_DIR", os.path.expanduser("~/.npm-global/bin"))

FAILS = []
def check(name, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + name + (f" — {detail}" if detail else ""), flush=True)
    if not ok: FAILS.append(name)

def result():
    print("\nRESULT: " + ("ALL PASS" if not FAILS else f"{len(FAILS)} FAILED: {FAILS}"), flush=True)
    return 1 if FAILS else 0

def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw).stdout.strip()

def kill_all():
    """Tear down only THIS harness's app and its children.

    Never match on a bare `Synth.app/...` pattern: the developer's own Synth is built to the same
    relative path in their checkout, and a broad pkill takes their running app down with it.
    """
    exe = f"{APP}/Contents/MacOS/Synth"
    sh(f"pkill -f '{exe}'")
    sh(f"pkill -f '{APP}/Contents/Frameworks'")   # our CEF helpers, which hold the CDP port
    sh("pkill -f 'opencode --port'")
    for _ in range(50):
        if not sh(f"pgrep -f '{exe}'"): break
        time.sleep(0.2)
    time.sleep(1.5)

WT_ROOT = str(pathlib.Path.home() / "Library/Application Support/Synth/worktrees")

def fresh_repo(name="repo", branches=()):
    d = pathlib.Path(H) / name
    sh(f"rm -rf {d}")
    # a prior run's worktree root for this repo path would make `git worktree add` hit an
    # existing directory — the harness, not the product, would fail.
    sh(f"rm -rf '{WT_ROOT}'/{name}-*")
    d.mkdir(parents=True)
    sh(f"git -C {d} init -q && git -C {d} config user.email t@t.co && git -C {d} config user.name t")
    (d / "README.md").write_text("hello\n")
    (d / "index.html").write_text("<!doctype html><html><body><h1 id='hero'>Synth harness page</h1><button id='cta'>Click me</button></body></html>\n")
    sh(f"git -C {d} add -A && git -C {d} commit -qm init")
    return d

def seed_state(repo, sessions=None, template=None, extra_branches=()):
    st = {
        "version": 1,
        "workspaces": [{
            "id": str(uuid.uuid4()), "name": "repo", "url": f"file://{repo}", "colorIndex": 0,
            "branches": [{
                "id": str(uuid.uuid4()), "name": sh(f"git -C {repo} branch --show-current"),
                "worktreeURL": f"file://{repo}", "lastActivity": "now",
                "sessions": sessions or [],
            }],
        }],
        "expanded": [],
    }
    if template is not None:
        st["globalSessionTemplate"] = template
    sd = pathlib.Path(H) / "state"
    sh(f"rm -rf {sd}"); sd.mkdir(parents=True)
    (sd / "state.json").write_text(json.dumps(st))
    return sd

def sweep_dead_sockets():
    """A recycled pid inherits a dead instance's /tmp/synth-ctl-<pid>.sock. A launch that merely
    waits for the file to exist then 'connects' to that corpse — so drop ownerless sockets first."""
    import glob
    for path in glob.glob("/tmp/synth-ctl-*.sock"):
        try: pid = int(path.rsplit("-", 1)[1].split(".")[0])
        except ValueError: continue
        try: os.kill(pid, 0)
        except OSError:
            try: os.unlink(path)
            except FileNotFoundError: pass

def launch(state_dir, log, theme=None, extra_args=()):
    sweep_dead_sockets()
    env = dict(os.environ)
    env["PATH"] = OPENCODE_PATH + ":" + env["PATH"]
    env["SYNTH_AUTOMATION"] = "1"
    env["SYNTH_STATE_DIR"] = str(state_dir)
    for k in ["CLAUDECODE","CLAUDE_CODE_SESSION_ID","CLAUDE_CODE_CHILD_SESSION","CLAUDE_CODE_ENTRYPOINT","CLAUDE_CODE_EXECPATH"]:
        env.pop(k, None)
    f = open(log, "w")
    # NSArgumentDomain pins the theme (and any extra_args defaults, e.g. the MCP toggles)
    # for this process only — the developer's Synth is untouched.
    argv = [f"{APP}/Contents/MacOS/Synth"] + (["-synth-theme", theme] if theme else []) + list(extra_args)
    p = subprocess.Popen(argv, stdout=f, stderr=f, env=env)
    sock = f"/tmp/synth-ctl-{p.pid}.sock"
    # Ready means "answers a request", not "the socket file exists".
    for _ in range(300):
        if p.poll() is not None:
            raise RuntimeError(f"Synth exited during launch (rc={p.poll()}); see {log}")
        if os.path.exists(sock):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(2)
                s.connect(sock)
                s.sendall(b'{"verb":"automation.sessions","worktreePath":"/probe"}\n')
                if s.recv(64):
                    s.close(); break
                s.close()
            except Exception: pass
        time.sleep(0.2)
    return p, sock

class Ctl:
    def __init__(self, sock, worktree):
        self.sock, self.wt = sock, str(worktree)
    def __call__(self, verb, worktree=None, **kw):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(30); s.connect(self.sock)
        r = {"verb": verb, "worktreePath": str(worktree or self.wt)}; r.update(kw)
        s.sendall((json.dumps(r) + "\n").encode())
        b = b""
        while not b.endswith(b"\n"):
            c = s.recv(65536)
            if not c: break
            b += c
        s.close()
        return json.loads(b.decode().strip() or "{}")
    def sessions(self, worktree=None):
        return self("automation.sessions", worktree=worktree).get("sessions", [])
    def row(self, sid, worktree=None):
        return next((r for r in self.sessions(worktree) if r["sessionId"] == sid), None)

def wait(fn, secs=30, every=0.3):
    end = time.time() + secs
    while time.time() < end:
        v = fn()
        if v: return v
        time.sleep(every)
    return None

def instance_json(pid):
    p = pathlib.Path.home() / "Library/Application Support/Synth/instances" / f"{pid}.json"
    return json.loads(p.read_text()) if p.exists() else {}
