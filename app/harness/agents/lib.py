import json, socket, subprocess, sys, time, os, pathlib, uuid, signal

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

def skip(reason):
    """A gate this machine cannot run — an agent that isn't installed, one that isn't signed in.
    One `SKIP:` line and a clean exit: run.sh counts it separately, so a missing prerequisite
    never reads as a pass and never reads as a product failure."""
    print(f"SKIP: {reason}", flush=True)
    sys.exit(0)

def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw).stdout.strip()

# Which Application Support sandbox the driven build uses. AppSupport keys it on the bundle's
# CFBundleName, so the dev build lives under "Synth Dev" and never shares state with a stable
# one — the harness has to follow the bundle it is actually driving rather than assume "Synth",
# or it reads files that were never written and sees every field as absent.
def support_dir():
    name = sh(f"/usr/libexec/PlistBuddy -c 'Print :CFBundleName' '{APP}/Contents/Info.plist'") or "Synth"
    return pathlib.Path.home() / "Library/Application Support" / name

def instance_json(pid):
    p = support_dir() / "instances" / f"{pid}.json"
    return json.loads(p.read_text()) if p.exists() else {}

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

WT_ROOT = str(support_dir() / "worktrees")

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

def launch(state_dir, log, theme=None, extra_args=(), env_extra=None):
    sweep_dead_sockets()
    env = dict(os.environ)
    env["PATH"] = OPENCODE_PATH + ":" + env["PATH"]
    env["SYNTH_AUTOMATION"] = "1"
    env["SYNTH_STATE_DIR"] = str(state_dir)
    for k in ["CLAUDECODE","CLAUDE_CODE_SESSION_ID","CLAUDE_CODE_CHILD_SESSION","CLAUDE_CODE_ENTRYPOINT","CLAUDE_CODE_EXECPATH"]:
        env.pop(k, None)
    # Last word, because TerminalManager seeds every PTY from the app's own environ: a gate that
    # must pin what a spawned agent sees (which SHELL answers the login-PATH probe, which
    # browser opener it can reach) sets it here or not at all.
    env.update(env_extra or {})
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

# --- Antigravity (`agy`) --------------------------------------------------------------------
# Two different programs answer to `agy`: the Antigravity CLI (the terminal agent Synth hosts)
# and the Nov-2025 Antigravity IDE's launcher, which only opens the GUI. Both live on a stock
# login PATH, the IDE's first. Everything below resolves the CLI the way Synth's detection has
# to — login-shell PATH, then this process's PATH, then the install hints, rejecting anything
# that resolves inside an `.app` bundle.

AGY_INSTALL_HINTS = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]

def login_path_dirs():
    """The PATH a login shell really has (ShellEnvironment.probe's exact invocation, sentinel
    and all, so rc-file chatter printed before the value can't be mistaken for it)."""
    shell = os.environ.get("SHELL") or "/bin/zsh"
    try:
        out = subprocess.run([shell, "-l", "-i", "-c", 'printf "\\001%s\\001" "$PATH"'],
                             capture_output=True, text=True, timeout=20,
                             stdin=subprocess.DEVNULL).stdout
    except Exception:
        return []
    parts = out.split("\001")
    return parts[1].split(":") if len(parts) > 2 else []

def in_app_bundle(path):
    """The structural tell that separates the IDE launcher from the CLI: it symlinks into
    /Applications/Antigravity.app. A GUI launcher is never the agent."""
    return ".app/" in os.path.realpath(path)

def agy_candidates():
    """Every `agy` a detection pass would consider, in search order."""
    dirs = login_path_dirs() + os.environ.get("PATH", "").split(":") \
         + [os.path.expanduser(d) for d in AGY_INSTALL_HINTS]
    seen, found = set(), []
    for d in dirs:
        c = os.path.join(d, "agy")
        if not d or c in seen: continue
        seen.add(c)
        if os.path.isfile(c) and os.access(c, os.X_OK): found.append(c)
    return found

def agy_binary():
    """The one Synth must land on: first candidate that isn't the IDE launcher."""
    return next((c for c in agy_candidates() if not in_app_bundle(c)), None)

def no_browser_env():
    """The popup ban. An `agy` that decides it needs a sign-in shells out to `open`, and a
    harness run must never spray browser tabs at whoever is at the keyboard — so every gate
    that can start one hands the app (and through it every PTY) a no-op `open` first on PATH
    and a BROWSER that does nothing."""
    d = pathlib.Path(H) / "no-browser"
    d.mkdir(parents=True, exist_ok=True)
    opener = d / "open"
    opener.write_text("#!/bin/sh\nexit 0\n")
    opener.chmod(0o755)
    return {"PATH": f"{d}:" + os.environ.get("PATH", ""), "BROWSER": "/usr/bin/true"}

def agy_signed_in():
    """`agy models` answers from the local session and fails signed out — the cheapest probe
    that distinguishes "installed" from "can actually take a turn"."""
    agy = agy_binary()
    if not agy: return False
    env = dict(os.environ); env.update(no_browser_env())
    try:
        r = subprocess.run([agy, "models"], capture_output=True, text=True, timeout=60,
                           stdin=subprocess.DEVNULL, env=env)
    except Exception:
        return False
    return r.returncode == 0 and bool(r.stdout.strip())

def require_agy():
    if not agy_binary():
        skip("the Antigravity CLI is not installed — `brew install --cask antigravity-cli`")

def require_agy_auth():
    require_agy()
    if not agy_signed_in():
        skip("`agy` is installed but signed out (`agy models` failed) — run `agy` once and sign "
             "in with a Google account; the live Antigravity gates take a real turn")

def agy_process():
    """The `ps` line of the Antigravity CLI a PTY is running. synth-hook exec's the real binary
    with argv[0] set to the absolute path Synth resolved, so this line *is* the detection answer
    — observed from outside rather than recomputed. Two exclusions: the shim wears the same name
    from the shim dir while it waits on its child, and the newest match wins so an `agy` still
    winding down from an earlier run in the same suite can't answer for this one."""
    found = []
    for pid in sh("pgrep -f '/agy'").split():
        line = sh(f"ps -o command= -p {pid}")
        if line.split(" ")[0].endswith("/agy") and "synth-shims-" not in line.split(" ")[0]:
            found.append((int(pid), line))
    return max(found)[1] if found else None

AGY_SETTINGS = pathlib.Path.home() / ".gemini/antigravity-cli/settings.json"

def agy_trust(path, trusted=True):
    """Stand in for the human at the keyboard on `agy`'s workspace trust prompt.

    On a path it has never seen, `agy` opens on a modal "do you trust the contents of this
    project?" — every fresh worktree hits it, and until it is answered the TUI swallows anything
    pasted at it. The answer is a keypress and lands in `agy`'s own settings; a gate that must
    reach the *other* side of that prompt sets it here, and only ever for its own scratch repos,
    so a run neither depends on what this machine happens to have trusted nor grants anything for
    the user's real worktrees. Synth itself never writes this file — a row blocked on the prompt
    is `needsInput`, which is what t15 asserts before granting."""
    path = str(pathlib.Path(path).resolve())
    st = json.loads(AGY_SETTINGS.read_text()) if AGY_SETTINGS.exists() else {}
    entries = [p for p in st.get("trustedWorkspaces", []) if p != path]
    if trusted: entries.append(path)
    st["trustedWorkspaces"] = entries
    AGY_SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    AGY_SETTINGS.write_text(json.dumps(st, indent=2))

def agy_transcript(conversation):
    """Where a conversation's turns land under the CLI's app data dir. Reading it is the only
    way to prove a resumed row is *inside* the old conversation rather than merely named after
    it (agy has no queryable server the way opencode does)."""
    return pathlib.Path.home() / ".gemini/antigravity-cli/brain" / conversation \
         / ".system_generated/logs/transcript_full.jsonl"
