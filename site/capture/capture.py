#!/usr/bin/env python3
"""Record the landing page's product figures from the real app.

    python3 site/capture/capture.py                # every scene
    python3 site/capture/capture.py --only hero    # just one
    python3 site/capture/capture.py --build        # rebuild the bundle first
    python3 site/capture/capture.py --invisible    # leave the desktop alone (see below)

Everything curated — which repos, which branches, the session titles, what the agent is asked to
do, the approval card's branch — lives in `scenes.py`. This file knows how to stage a scene, not
what is in one.

The figures are meta: the work on screen is the work of building this site. Nothing in them is a
mock-up of the product.

How a scene is staged, and why each step is there:

  Real repos.       Each project is a real repository on this machine, cloned into a scratch
                    directory, with a real `git worktree` per branch. A clone and never the
                    checkout, because a live coding agent runs in these — and Synth reconciles
                    branch rows against disk on restore, so a made-up path would photograph an
                    empty sidebar anyway.

  A seeded app.     `$SYNTH_STATE_DIR` makes Synth boot from a state.json we wrote, and
                    `$SYNTH_SUPPORT_DIR` keeps its worktrees, browser profile and instance
                    registry out of the one the owner's own Synth uses.

  On the screen.    `SYNTH_AUTOMATION=1` alone parks every window at zero alpha, which keeps a
                    gate run off its owner's desktop — and makes two of these figures
                    impossible. A CEF page and a simulator's video layer are drawn by other
                    processes into surfaces the app's own view hierarchy has no access to, so
                    the app rendering itself gives a blank page and a black device screen. Only
                    the window server has that picture, and it only composites what is really on
                    a display. So the default run adds `SYNTH_AUTOMATION_VISIBLE=1`, brings the
                    window forward and photographs it with `screencapture -l`. `--invisible`
                    goes back to the parked path: the desktop is left alone, and the browser and
                    simulator figures come back empty.

  A real agent.     A row that says Claude Code runs Claude Code. It is spawned into the clone,
                    handed the prompt `scenes.py` gives it, and whatever it does is what the
                    figure shows — so the output costs real quota and differs run to run. One
                    turn per row, and only for the figures that need its output; a row that only
                    has to *be* a live agent is booted and left alone.

  Staged status.    A row that is NOT a live agent — a shell, a browser — gets its status from
                    the hook socket, one JSON line per signal. The same wire a real shell's own
                    reporter uses, so the picture is the product's, not a drawing of it.

Teardown matches on the exact executable path this script launched. The owner's own Synth runs
from a different bundle, and a broad `pkill -f Synth` would take it down with them working in it.
"""

import argparse
import http.server
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
IMG = HERE.parent / "img"
sys.path.insert(0, str(HERE))
import scenes  # noqa: E402

# A bundle of its own, at a path nothing else launches — see build.sh.
APP = REPO / "app/.build/arm64-apple-macosx/debug/Synth Capture.app"
EXE = APP / "Contents/MacOS/Synth"

SCRATCH = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / "synth-capture"
# Rebuilt every run: the tree, the state, the pages, the logs.
REPOS, WORKTREES = SCRATCH / "repos", SCRATCH / "worktrees"
STATE, SITE, LOGS = SCRATCH / "state", SCRATCH / "site", SCRATCH / "logs"
# Kept between runs: the app's Application Support sandbox. The MCP install under it is an
# `npm install`, and paying for that on every capture would make the rig feel broken.
SUPPORT = SCRATCH / "support"
# An empty $ZDOTDIR. Synth's injected zsh config re-sources the user's own .zshrc, which on a
# developer's machine prints things, and a spawned agent should open on a clean shell.
NOZDOT = SCRATCH / "no-zdot"


NS = uuid.UUID("5b0f1e4a-9a3a-4c3f-9a2e-9d1c0f7b6a11")


def uid(*parts):
    """A stable id for anything in the scene tree, so a hook signal can address a row by name."""
    return str(uuid.uuid5(NS, "/".join(parts)))


def sh(cmd, cwd=None):
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True).stdout.strip()


def say(msg):
    print(msg, flush=True)


# ─────────────────────────────────────────────────────────────────────────────
# The tree on disk
# ─────────────────────────────────────────────────────────────────────────────

def build_tree(spec=None):
    """One git repo per project, one real worktree per branch, and the state.json to match."""
    for d in (REPOS, WORKTREES, STATE, LOGS, NOZDOT):
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True, exist_ok=True)
    SUPPORT.mkdir(parents=True, exist_ok=True)

    workspaces, expanded, trust = [], [], []
    for project in scenes.PROJECTS:
        repo = REPOS / project["name"]
        source = pathlib.Path(os.path.expanduser(project["repo"]))
        if not (source / ".git").exists():
            raise SystemExit(f"{source} is not a git repo — scenes.py names it as {project['name']}")
        # A clone, never the checkout. A live coding agent runs in these, and the repo the owner
        # is working in is the one thing that must not be at risk. `--local` hardlinks the object
        # store, so cloning a large repo costs almost nothing and touches the source read-only.
        sh(f"git clone --quiet --local '{source}' '{repo}'")
        # A clone of a clone inherits no identity, and an agent that tries to commit would stop
        # on git's "please tell me who you are" instead of doing the work.
        sh("git config user.email capture@synth.local && git config user.name capture", cwd=repo)

        ws_id = uid(project["name"])
        expanded.append(ws_id)
        branches = []
        for branch in project["branches"]:
            name = branch["name"]
            if name == project["base"]:
                path = repo
            else:
                path = WORKTREES / f"{project['name']}-{name.replace('/', '-')}"
                sh(f"git worktree add -q -b {name} '{path}'", cwd=repo)
            # A checkout carries what is committed. The work these figures are about is not: asked
            # to read the landing page, the agent answered — correctly, and uselessly — that there
            # is no such directory. So the named paths are copied in, per worktree, because that is
            # where the agent actually runs.
            copy_in(source, path, project.get("copy_in", []))
            trust.append(path)
            br_id = uid(project["name"], name)
            if branch.get("expanded"):
                expanded.append(br_id)
            branches.append({
                "id": br_id, "name": name,
                # The path is quoted because a worktree root can contain spaces; an unescaped
                # URL decodes to a path that does not exist and the row drops as missing.
                "worktreeURL": "file://" + urllib.parse.quote(str(path)),
                "lastActivity": "now",
                "sessions": [persisted(project, branch, s) for s in branch["sessions"]],
            })
            if spec and spec.get("split"):
                keys = {s["key"] for s in branch["sessions"]}
                left, right = spec["open"], spec["split"]["right"]
                if left in keys and right in keys:
                    branches[-1]["layout"] = {"split": {
                        "dir": "row", "split": spec["split"]["fraction"],
                        "a": {"leaf": {"session": uid(project["name"], name, left)}},
                        "b": {"leaf": {"session": uid(project["name"], name, right)}},
                    }}
        workspaces.append({"id": ws_id, "name": project["name"],
                           "url": "file://" + urllib.parse.quote(str(repo)),
                           "colorIndex": project["chip"], "branches": branches})

    state = {"version": 1, "workspaces": workspaces, "expanded": expanded}
    if scenes.CLAUDE_FLAGS:
        state["globalAgentFlags"] = {"claudeCode": scenes.CLAUDE_FLAGS}
    (STATE / "state.json").write_text(json.dumps(state))
    return trust


def copy_in(source, into, extras):
    """Uncommitted work, carried from the checkout into a scratch worktree. Read-only on the
    source side: nothing here ever writes back to the repo the owner is working in."""
    for extra in extras:
        src, dst = source / extra, into / extra
        if not src.exists():
            raise SystemExit(f"scenes.py asks to copy {extra} into the clone, but {src} is missing")
        if src.is_dir():
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            shutil.copy2(src, dst)


def persisted(project, branch, session):
    """One session row as the on-disk snapshot spells it (PersistedSession)."""
    row = {
        "id": uid(project["name"], branch["name"], session["key"]),
        "kind": session["kind"],
        "title": session["title"],
        # Hand-picked, so neither the agent's auto-title nor the shell's per-command reporter
        # renames a row the scene file named.
        "titleIsCustom": True,
    }
    if session.get("url"):
        row["browserURL"] = session["url"].replace("{site}", SITE_ORIGIN)
    if session.get("device_udid"):
        row["simulatorUDID"] = session["device_udid"]
    return row


def all_sessions():
    """Every session in the tree, as (session dict, its id, its branch's worktree path)."""
    out = []
    for project in scenes.PROJECTS:
        repo = REPOS / project["name"]
        for branch in project["branches"]:
            path = repo if branch["name"] == "main" else \
                WORKTREES / f"{project['name']}-{branch['name'].replace('/', '-')}"
            for s in branch["sessions"]:
                out.append((s, uid(project["name"], branch["name"], s["key"]), str(path)))
    return out


def find(key):
    for s, sid, wt in all_sessions():
        if s["key"] == key:
            return s, sid, wt
    raise SystemExit(f"scenes.py names no session '{key}'")


# ─────────────────────────────────────────────────────────────────────────────
# The pages on localhost
# ─────────────────────────────────────────────────────────────────────────────

SITE_ORIGIN = "http://localhost:3000"


def serve():
    """Host this site, read-only, for the run.

    The page in the browser and on the phone is `site/index.html` itself — the figures are about
    building it, so a mock-up of somebody else's product would be the one staged thing left. The
    working checkout is served rather than the clone because it is the current page, and it is
    only ever read. Port 3000 when it is free, because the browser row's address bar is part of
    the picture.
    """
    global SITE_ORIGIN
    root = pathlib.Path(scenes.SITE_ROOT)
    if not (root / scenes.PAGE.lstrip("/")).exists():
        raise SystemExit(f"no {scenes.PAGE} under {root} — scenes.SITE_ROOT points at nothing")

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(root), **kw)

        def log_message(self, *a):
            pass

    port = 3000
    try:
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError:
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        port = srv.server_address[1]
        say(f"  note: port 3000 is taken, serving on {port} — the address bar will say so")
    SITE_ORIGIN = f"http://localhost:{port}"
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


AGENT_KINDS_EXCLUDED = {"terminal", "browser", "simulator", "markdown", "inspect"}


def is_agent(session):
    """Any kind that is not one of the fixed few is an agent id — the same rule SessionKind
    applies when it decodes a snapshot."""
    return session["kind"] not in AGENT_KINDS_EXCLUDED


# ─────────────────────────────────────────────────────────────────────────────
# Driving the app
# ─────────────────────────────────────────────────────────────────────────────

class Ctl:
    """One JSON line per request over the control socket, one back."""

    def __init__(self, path):
        self.path = path

    def __call__(self, verb, worktree=None, timeout=60, **kw):
        # Every verb is refused before it is dispatched unless `worktreePath` names a branch
        # this Synth manages — app-wide verbs (the palette, the screenshot, the window) included.
        # So a call that is about no branch in particular still has to name one.
        worktree = worktree or str(REPOS / scenes.PROJECTS[0]["name"])
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(self.path)
        req = {"verb": verb, "worktreePath": worktree}
        req.update(kw)
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        s.close()
        return json.loads(buf.decode().strip() or "{}")


def hook(sock_path, session_id, **fields):
    """One signal to the hook socket — the same wire `synth-hook` uses from inside a session.

    A refused connection here means the app is gone, not that the signal was bad: the socket file
    outlives the process that bound it. Say which, and where the app's own log is, rather than
    letting a bare ECONNREFUSED stand in for "Synth died"."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(sock_path)
    except OSError as why:
        raise AppDied(f"the hook socket stopped answering ({why}) — Synth exited mid-scene; "
                      f"its log is under {LOGS}") from None
    s.sendall((json.dumps({"session": session_id, **fields}) + "\n").encode())
    s.close()


def wait(fn, secs=30, every=0.3):
    end = time.time() + secs
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(every)
    return None


def sweep_dead_sockets():
    """A recycled pid inherits a dead instance's control socket; a launch that only checks the
    file exists then talks to a corpse. Drop the ownerless ones first."""
    import glob
    for path in glob.glob("/tmp/synth-ctl-*.sock"):
        try:
            pid = int(path.rsplit("-", 1)[1].split(".")[0])
            os.kill(pid, 0)
        except (ValueError, OSError):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def launch(scene_name, theme, visible=True):
    sweep_dead_sockets()
    env = dict(os.environ)
    env["SYNTH_AUTOMATION"] = "1"
    # A window nobody can see is a window the window server does not composite, and both the CEF
    # page and the simulator's video layer live outside the app's own view hierarchy — parked,
    # they photograph as white and black. A visible run keeps the desktop for its length.
    if visible:
        env["SYNTH_AUTOMATION_VISIBLE"] = "1"
    env["SYNTH_STATE_DIR"] = str(STATE)
    env["SYNTH_SUPPORT_DIR"] = str(SUPPORT)
    env["ZDOTDIR"] = str(NOZDOT)
    # Session markers this script may have inherited from the agent running it. A spawned shell
    # that sees them behaves as a subagent's.
    for k in ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
              "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "OPENCODE", "AGENT"):
        env.pop(k, None)
    log = open(LOGS / f"{scene_name}.log", "w")
    # NSArgumentDomain, so these are pinned for this process alone — the owner's own Synth,
    # and its preferences, are untouched. Simulator sessions are behind an Experimental toggle
    # that defaults off; the approval frame needs the synth-app server on.
    # NSArgumentDomain takes a property-list literal, not the word YES: `object(forKey:) as? Bool`
    # on the string "YES" is nil, and the pref silently keeps its default.
    argv = [str(EXE), "-synth-theme", theme,
            "-synth-tabs", "<true/>",
            "-synth-simulator-sessions", "<true/>", "-synth-mcp-simulator", "<true/>",
            "-synth-mcp-app", "<true/>"]
    proc = subprocess.Popen(argv, stdout=log, stderr=log, env=env)
    ctl_path = f"/tmp/synth-ctl-{proc.pid}.sock"
    ready = wait(lambda: os.path.exists(ctl_path) and probe(ctl_path), 60, 0.2)
    if not ready:
        raise SystemExit(f"Synth never answered; see {LOGS / f'{scene_name}.log'}")
    return proc, Ctl(ctl_path), f"/tmp/synth-hook-{proc.pid}.sock"


def probe(path):
    try:
        return bool(Ctl(path)("automation.sessions", timeout=3))
    except Exception:
        return False


def teardown(proc):
    """Only what this script started. Matching on a bare `Synth.app/...` pattern would find the
    owner's own build, running from their checkout at a path of the same shape."""
    sh(f"pkill -f '{EXE}'")
    sh(f"pkill -f '{APP}/Contents/Frameworks'")   # the CEF helpers holding the CDP port
    for _ in range(50):
        if not sh(f"pgrep -f '{EXE}'"):
            break
        time.sleep(0.2)
    try:
        proc.wait(timeout=5)
    except Exception:
        pass
    # The CEF helpers hold the browser profile in the support dir, and a new instance that starts
    # while a dying one still has it comes up without an engine — or not at all.
    for _ in range(50):
        if not sh(f"pgrep -f '{APP}/Contents/Frameworks'"):
            break
        time.sleep(0.2)
    time.sleep(1.5)


# ─────────────────────────────────────────────────────────────────────────────
# Staging
# ─────────────────────────────────────────────────────────────────────────────

def stage_rows(ctl, hook_path):
    """Give every non-agent row the status the scene file gives it, over the hook socket — the
    same wire a real shell's own reporter uses. An agent row is not staged: it is a live process
    and its status is whatever it is really doing."""
    for s, sid, _ in all_sessions():
        for signal in s.get("signals", []):
            hook(hook_path, sid, signal=signal)
            time.sleep(0.15)


def row(ctl, worktree, sid):
    # Case-insensitively: Swift's `uuidString` is upper-case, Python's `uuid5` lower.
    return next((r for r in ctl("automation.sessions", worktree=worktree).get("sessions", [])
                 if r["sessionId"].lower() == sid.lower()), None)


def drive_agent(ctl, key, deliver=True, expect=None):
    """Bring a real agent up in a real clone, and — when the figure needs its output — spend one
    turn on it.

    One turn, never more: this is live quota and live variance, so the prompt in `scenes.py` has
    to reach the state the figure wants in a single pass. A figure that only needs the row to
    *exist* as a live agent (the deck's card, the approval frame's requester) passes deliver=False
    and costs nothing.
    """
    s, sid, wt = find(key)
    # No waiting on a person here: `preflight_trust` has already had every folder-trust question
    # answered before the first shot, so an agent that does not come up now is a real failure.
    live = wait(lambda: (row(ctl, wt, sid) or {}).get("liveAgent"), 120, 1)
    if not live:
        raise Skip(f"claude never came up in {wt} — see the log")
    if not (deliver and s.get("prompt")):
        say("  claude is live (no turn spent)")
        return
    ctl("automation.deliver", worktree=wt, sessionId=sid, text=s["prompt"])
    if not wait(lambda: (row(ctl, wt, sid) or {}).get("status") == "working", 90, 0.5):
        say("  ! the turn never started — capturing whatever the row is showing")
        return
    settled = wait(lambda: (row(ctl, wt, sid) or {}).get("status") in ("needsInput", "idle", "error"),
                   420, 1)
    status = (row(ctl, wt, sid) or {}).get("status")
    say(f"  claude finished its turn: {status}" + ("" if settled else " (timed out waiting)"))
    if expect and status != expect:
        raise WrongState(f"the turn ended {status}, not {expect} — the agent answered instead of "
                         f"stopping to ask")
    time.sleep(2)


def png_pixels(path):
    """Just enough PNG to find where the picture actually is: 8-bit RGB/RGBA, no interlacing,
    which is what NSBitmapImageRep writes. Returns (width, height, rows of (r,g,b))."""
    import struct
    import zlib
    raw = pathlib.Path(path).read_bytes()
    pos, idat, w = 8, b"", None
    while pos < len(raw):
        length, kind = struct.unpack(">I4s", raw[pos:pos + 8])
        body = raw[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            w, h, depth, colour = struct.unpack(">IIBB", body[:10])
            if depth != 8 or colour not in (2, 6) or body[12] != 0:
                return None
            channels = 3 if colour == 2 else 4
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length
    if w is None:
        return None
    data = zlib.decompress(idat)
    stride = w * channels
    rows, prev, at = [], bytes(stride), 0
    for _ in range(h):
        filt, line, at = data[at], bytearray(data[at + 1:at + 1 + stride]), at + 1 + stride
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if filt == 1:
                line[i] = (line[i] + a) & 255
            elif filt == 2:
                line[i] = (line[i] + b) & 255
            elif filt == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append([tuple(line[i:i + 3]) for i in range(0, stride, channels)])
        prev = bytes(line)
    return w, h, rows


def trim(path, pad=48):
    """Crop away the flat surround. The ⌘K palette floats in a panel far larger than the card,
    and everything around it renders as one dead grey — a figure of a card, published with a
    field of grey around it, is a figure nobody framed."""
    read = png_pixels(path)
    if not read:
        return
    w, h, rows = read
    ground = rows[0][0]
    def ink(px):
        return max(abs(px[i] - ground[i]) for i in range(3)) > 10
    xs = [x for row in rows for x in range(w) if ink(row[x])]
    ys = [y for y in range(h) if any(ink(px) for px in rows[y])]
    if not xs or not ys:
        return
    left, right = max(0, min(xs) - pad), min(w, max(xs) + pad)
    top, bottom = max(0, min(ys) - pad), min(h, max(ys) + pad)
    sh(f"sips -c {bottom - top} {right - left} --cropOffset {top} {left} '{path}' --out '{path}'")


def window_number(ctl, panel):
    """The window server's id for the frame this scene is about. The ⌘K palette floats in a
    panel of its own, so which window a capture wants is not always the one that was sized."""
    windows = ctl("automation.windows").get("windows", [])
    match = [w for w in windows if bool(w.get("panel")) == panel]
    return match[0]["windowNumber"] if match else None


def blank(path):
    """True when the picture is one flat colour. `screencapture -l` answers with an empty frame
    for a window the compositor has nothing current for, and an empty frame that reports success
    is worse than a failure — so every capture is looked at before it is believed."""
    read = png_pixels(path)
    if not read:
        return False
    w, h, rows = read
    ground = rows[0][0]
    return not any(max(abs(px[i] - ground[i]) for i in range(3)) > 10
                   for row in rows[::8] for px in row[::8])


def shoot(ctl, name, palette=False, visible=True, suffix=""):
    IMG.mkdir(parents=True, exist_ok=True)
    out = IMG / f"{name}{suffix}@2x.png"

    if visible:
        # The window server's own picture of the window, which is the only picture that includes
        # what other processes drew into it: the CEF page and the simulator's video layer.
        # -o drops the drop shadow (the page draws its own frame) and -x mutes the shutter.
        number = window_number(ctl, panel=palette)
        if number is None:
            raise SystemExit(f"no {'panel' if palette else 'window'} to photograph")
        # An obscured window can hand back a stale or empty frame. Fronting first is cheap, and
        # this run was authorised to take the screen.
        ctl("automation.front")
        time.sleep(1.2)
        sh(f"screencapture -x -o -l {number} '{out}'")
        if not out.exists() or blank(out):
            raise SystemExit(f"screencapture -l {number} came back empty for {name}")
        # The ⌘K panel is as large as the window it floats over and mostly transparent; captured
        # alone, the card sits in a field of dead grey. The page's own approval figure is a card
        # on its own too, so crop to it rather than publish the field.
        if palette:
            trim(out)
    else:
        # The parked path: the app renders its own content view, with no window server involved.
        # Omitting "window" prefers whatever panel floats in front.
        req = {} if palette else {"window": "main"}
        r = ctl("automation.screenshot", path=str(out), **req)
        if not r.get("ok"):
            raise SystemExit(f"screenshot failed: {r}")
        if palette:
            trim(out)

    w, h = sh(f"sips -g pixelWidth -g pixelHeight '{out}'").split("\n")[-2:]
    px = w.split(":")[-1].strip() + "×" + h.split(":")[-1].strip()
    say(f"  → {out.relative_to(REPO)}  {px}  {out.stat().st_size / 1024:.0f} KB")
    return out


def node_playwright():
    """playwright-core, wherever an install of it exists. Synth's own MCP install is the one
    that is always there on a machine that has run Synth; the capture sandbox grows its own
    once its npm install has finished."""
    for base in (SUPPORT, pathlib.Path.home() / "Library/Application Support/Synth"):
        p = base / "browser-mcp/node_modules/playwright-core"
        if p.exists():
            return str(p)
    return None


# ─────────────────────────────────────────────────────────────────────────────
# The scenes
# ─────────────────────────────────────────────────────────────────────────────

def scene_hero(ctl, hook_path, spec):
    """Wait for the live page and verify the restored split before pressing the shutter."""
    _, sid, wt = find(spec["split"]["right"])
    if not wait(lambda: SITE_ORIGIN in (
            ctl("automation.state", worktree=wt, sessionId=sid).get("address") or ""), 60):
        raise Skip("hero browser did not load the landing page")
    layout = ctl("automation.layout")
    tree = layout.get("tree", {})
    if (layout.get("panes") != 2 or tree.get("dir") != "row"
            or abs(tree.get("split", 0) - spec["split"]["fraction"]) > 0.01
            or tree.get("a", {}).get("session", "").lower() != find(spec["open"])[1].lower()
            or tree.get("b", {}).get("session", "").lower() != sid.lower()):
        raise Skip(f"hero split did not restore: {layout}")


def scene_browser(ctl, hook_path, spec):
    """Comment mode on, with a comment pinned to each element `scenes.COMMENTS` names —
    queued, not sent, so the island is still standing when the shutter falls."""
    _, sid, wt = find(spec["open"])
    # The origin, not the path: `scenes.PAGE` may be "/", which is in every URL ever written.
    needle = "localhost"
    wait(lambda: needle in (ctl("automation.state", worktree=wt, sessionId=sid).get("address") or ""), 60)
    ctl("automation.commentMode", worktree=wt, sessionId=sid)
    if not wait(lambda: ctl("automation.state", worktree=wt, sessionId=sid).get("commentModeActive"), 20):
        say("  ! comment mode never engaged — capturing the plain page")
        return
    pw = node_playwright()
    port = wait(lambda: instance_cdp_port(), 30)
    if not (pw and port):
        say("  ! no playwright / no CDP port — capturing comment mode with no pins")
        return
    out = subprocess.run(
        ["node", str(HERE / "comments.js"), str(port), needle,
         json.dumps(scenes.COMMENTS)],
        capture_output=True, text=True, env=dict(os.environ, PLAYWRIGHT=pw))
    say(f"  comments: {out.stdout.strip() or out.stderr.strip()}")
    # What the app holds, not what the driver asked for: a click that missed the element still
    # looks like a click from the outside, and an island standing empty in the figure while the
    # run reports success is the failure this rig exists not to have.
    held = wait(lambda: ctl("automation.state", worktree=wt, sessionId=sid).get("pendingComments"), 20)
    say(f"  the island holds {held or 0} of {len(scenes.COMMENTS)}")
    if (held or 0) < len(scenes.COMMENTS):
        say("  ! not every comment landed — check the selectors in scenes.COMMENTS")


def instance_cdp_port():
    d = SUPPORT / "instances"
    for f in d.glob("*.json") if d.exists() else []:
        try:
            port = json.loads(f.read_text()).get("cdpPort")
        except Exception:
            continue
        if port:
            return port
    return None


def scene_simulator(ctl, hook_path, spec):
    """A booted device showing the checkout page in mobile Safari. A whole iOS app is more than
    a first pass needs; the point of the figure is that the device is a session in the window."""
    _, _, wt = find("claude")            # the simulator joins the branch the hero is about
    r = ctl("simulator.create", worktree=wt, device=scenes.SIMULATOR["device"], timeout=120)
    if not r.get("ok"):
        raise Skip(r.get("error", "simulator.create refused"))
    sid, r_udid = r["sessionId"], r["udid"]
    say(f"  device: {r.get('device')} · {r.get('runtime')}")
    ctl("automation.jump", worktree=wt, sessionId=sid)
    ok = wait(lambda: next((s for s in ctl("simulator.list", worktree=wt).get("sessions", [])
                            if s["sessionId"] == sid and s.get("attached")), None), 240, 2)
    if not ok:
        raise Skip("the device never attached within four minutes")
    # Synth reports the pane attached as soon as it has a framebuffer, which is earlier than
    # `simctl` will accept a command — the device is still in "Booting" and refuses openurl. So
    # wait for the device's own state, then keep asking: the first url after a cold boot often
    # lands before SpringBoard is ready to hand it to Safari.
    url = SITE_ORIGIN + scenes.SIMULATOR["page"]
    wait(lambda: "Booted" in sh(f"xcrun simctl list devices | grep -i {r_udid}"), 180, 2)
    opened = wait(lambda: ctl("simulator.openUrl", worktree=wt, sessionId=sid,
                              url=url, timeout=120).get("ok"), 120, 4)
    if not opened:
        raise Skip("the device booted but never accepted the url")
    time.sleep(10)                       # Safari's cold start, then the page

    # The pane's own screenshot of the device, alongside the window capture. The two disagree —
    # the device is showing the page, the window capture renders its screen black — and that
    # disagreement is the finding this scene exists to record.
    proof = LOGS / "simulator-device.png"
    r = ctl("simulator.screenshot", worktree=wt, sessionId=sid, path=str(proof), timeout=120)
    say(f"  the device's own frame: {r.get('width')}×{r.get('height')} at {proof}"
        if r.get("ok") else f"  the device would not hand back a frame: {r.get('error')}")


def scene_approval(ctl, hook_path, spec):
    """The frame an agent's request for a worktree stops on. `app.worktreeCreate` parks its
    connection until a person answers, so it is asked from a thread and declined afterwards —
    the picture is the question, and cutting the branch would be a side effect nobody asked for."""
    _, requester, wt = find(scenes.APPROVAL["asked_by"])
    answer = {}

    def ask():
        answer["r"] = ctl("app.worktreeCreate", worktree=wt,
                          branch=scenes.APPROVAL["branch"], base=scenes.APPROVAL["base"],
                          handoff=scenes.APPROVAL["handoff"], ownerSessionId=requester,
                          timeout=300)

    t = threading.Thread(target=ask, daemon=True)
    t.start()
    if not wait(lambda: ctl("automation.agentPrompts", worktree=wt).get("prompts"), 30):
        raise Skip("no approval prompt arrived — is the synth-app MCP server switched off?")
    frame = wait(lambda: (ctl("automation.palette", worktree=wt).get("crumb") or None), 20)
    if not frame:
        raise Skip("the prompt queued but the palette never opened")
    say(f"  frame: {frame!r} · {ctl('automation.palette', worktree=wt).get('items')}")


def scene_attention(ctl, hook_path, spec):
    """The notification deck. `notifRoute` pins the in-app route so the cards land in the deck
    rather than as banners on the desktop of whoever is running this."""
    # The open session's card is cleared the moment it is raised — you are looking at the thing.
    # So move the pane off the live Claude first: the card the deck is really about is the one
    # that says an agent has stopped and wants you, and that agent has to be in the background
    # for the deck to carry it at all.
    #
    # Onto the browser rather than a shell. A shell at its prompt is nearly empty behind the deck,
    # and the prompt itself carries the machine's user and hostname — which is not something to
    # publish on a landing page.
    _, dev_sid, dev_wt = find("web")
    ctl("automation.jump", worktree=dev_wt, sessionId=dev_sid)
    time.sleep(1.5)
    ctl("automation.notifRoute", route="deck")

    # One card per kind, in the order the deck should stack them. The live Claude's needs-input
    # is fired over the hook socket rather than by spending another turn on it — the card is
    # raised by the status transition, and the transition is the same one its own hook sends.
    order = [("tests", "term-error"), ("shell", "term-idle"), ("claude", "needsInput")]
    for key, signal in order:
        _, sid, _ = find(key)
        hook(hook_path, sid, signal="working")
        time.sleep(0.3)
        hook(hook_path, sid, signal=signal)
        time.sleep(0.8)
    deck = ctl("automation.notifs").get("notifs", [])
    for card in deck:
        say(f"  card: {card['title']} — {card['message']} · {card['sub']}")
    if not deck:
        raise Skip("nothing reached the deck")
    time.sleep(1.5)


class Skip(Exception):
    """A scene this machine cannot stage. Said out loud and skipped, never faked."""


class Retryable(Skip):
    """A scene that did not get a fair turn, rather than one that cannot be staged. The run has
    another go at it before giving up."""


class AppDied(Retryable):
    """Synth exited part-way through a scene."""


class WrongState(Retryable):
    """The scene ran but did not reach the state it is a picture of. A live agent is not
    deterministic: asked to stop and ask, it sometimes answers in prose instead, which never
    reaches needs-input — and a hero figure whose agent is idle has no badges on the tab, no
    roll-up on the branch, and no question in the pane. Shipping that frame would be shipping a
    picture of the wrong thing."""


STAGERS = {"hero": scene_hero, "browser": scene_browser, "simulator": scene_simulator,
           "approval": scene_approval, "attention": scene_attention}


# ─────────────────────────────────────────────────────────────────────────────

def record(name, spec, visible=True, theme=None, suffix=""):
    say(f"\n{name}{suffix} — {spec['what']}")
    # Every scene gets the tree fresh — new clones, new worktrees, new state. Synth autosaves
    # back into `$SYNTH_STATE_DIR`, so a scene would otherwise inherit the last one's app; and a
    # live agent has been editing in these worktrees, so the next scene deserves a clean one.
    build_tree(spec)
    theme = theme or spec.get("theme", scenes.THEME)
    w, h = spec.get("window", scenes.WINDOW)

    proc, ctl, hook_path = launch(name + suffix, theme, visible=visible)
    try:
        r = ctl("automation.windowSize", w=float(w), h=float(h))
        if not r.get("ok"):
            say(f"  ! windowSize: {r.get('error')} — the frame is whatever AppKit chose")

        if spec.get("open"):
            opened, sid, wt = find(spec["open"])
            ctl("automation.jump", worktree=wt, sessionId=sid)
            time.sleep(2.5)              # the pane appears and its process starts
            if is_agent(opened):
                drive_agent(ctl, spec["open"], deliver=spec.get("drive", True),
                            expect=spec.get("expect"))

        stage_rows(ctl, hook_path)
        # Staging a status raises its card, and a deck floating over the sidebar is only wanted
        # in the scene that is about the deck. Dismissed the way a person dismisses one.
        if name != "attention":
            for card in ctl("automation.notifs").get("notifs", []):
                ctl("automation.notifDismiss", sessionId=card["sessionId"])
            time.sleep(0.6)
        STAGERS[name](ctl, hook_path, spec)
        time.sleep(1.8)                  # indicators animate in; let them land
        return shoot(ctl, name, palette=spec.get("palette", False),
                     visible=visible, suffix=suffix)
    finally:
        teardown(proc)


def preflight_trust(wanted, visible):
    """Get every folder-trust question out of the way before the run starts, in one sitting.

    Claude Code asks whether it trusts a folder the first time it runs anywhere it has not seen,
    and a scratch worktree is new the first time this rig uses it. The rig will not answer that
    for anyone — it is a security prompt, and the answer belongs to the person whose machine this
    is. But being interrupted three times, minutes apart, in the middle of a run is worse than
    being asked once: so every agent this run will need is brought up here, together, before a
    single shot is taken.

    Nothing to answer is the normal case. The paths do not change between runs, so once a branch
    has been trusted it stays trusted, and this returns in the time it takes Claude to boot.
    """
    keys = {scenes.SCENES[n].get("open") for n in wanted}
    agents = [(s, sid, wt) for s, sid, wt in all_sessions()
              if is_agent(s) and s["key"] in keys]
    if not agents:
        return

    build_tree()
    proc, ctl, _ = launch("preflight", scenes.THEME, visible=visible)
    try:
        w, h = scenes.WINDOW
        ctl("automation.windowSize", w=float(w), h=float(h))
        # Opening a row is what spawns its agent, so every one of them has to be opened before
        # any of them can be waiting on anything.
        pending = []
        for s, sid, wt in agents:
            ctl("automation.jump", worktree=wt, sessionId=sid)
            if not wait(lambda: (row(ctl, wt, sid) or {}).get("liveAgent"), 30, 0.5):
                pending.append((s, sid, wt))
        if not pending:
            say("every worktree is already trusted — nothing to answer")
            return

        say("")
        say(f"{len(pending)} worktree(s) Claude has not seen before. It is asking whether it "
            "trusts them, and this rig will not answer that for you.")
        say("Synth is on screen. Answer each prompt as it comes up — the run continues by itself.")
        for s, sid, wt in pending:
            # One at a time, each brought into view as it is asked about: three identical dialogs
            # with nothing to tell them apart is a guessing game.
            ctl("automation.jump", worktree=wt, sessionId=sid)
            ctl("automation.front")
            say(f"  → {wt}")
            if wait(lambda: (row(ctl, wt, sid) or {}).get("liveAgent"), 300, 1):
                say("    trusted")
            else:
                say("    still not live — the scenes that need this agent will skip")
    finally:
        teardown(proc)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--only", action="append", help="record just this scene (repeatable)")
    ap.add_argument("--build", action="store_true", help="rebuild the app bundle first")
    ap.add_argument("--invisible", action="store_true",
                    help="park the window and let the app render itself — leaves the desktop "
                         "alone, but a browser page comes back blank and a device screen black")
    args = ap.parse_args()

    if args.build or not EXE.exists():
        say("building the capture bundle…")
        subprocess.run([str(HERE / "build.sh")], check=True)
    if not EXE.exists():
        raise SystemExit(f"no bundle at {APP} — run site/capture/build.sh")

    visible = not args.invisible
    if visible:
        say("This run uses the screen: Synth will come to the front for each shot.")
        # A pointer resting over the window hovers whatever row is under it, and the hover is in
        # the picture — a sidebar row rendered with its hover affordances reads as mis-selected.
        say("Park the pointer away from the middle of the screen, then leave the Mac alone.")

    srv = serve()
    say(f"serving {scenes.SITE_ROOT} on {SITE_ORIGIN}")

    wanted = args.only or list(scenes.SCENES)
    for name in wanted:
        if name not in scenes.SCENES:
            raise SystemExit(f"scenes.py has no scene '{name}' — one of {list(scenes.SCENES)}")
    preflight_trust(wanted, visible)

    made, skipped = [], []
    for name in wanted:
        if name not in scenes.SCENES:
            raise SystemExit(f"scenes.py has no scene '{name}' — one of {list(scenes.SCENES)}")
        spec = scenes.SCENES[name]
        # Light first, then the dark twin for the scenes that want one — a separate run each,
        # because the theme is pinned at launch.
        takes = [(None, "")] + ([("dark", "-dark")] if spec.get("dark_too") else [])
        for theme, suffix in takes:
            # Three goes at most. A live agent is the variable part of every agent figure: asked
            # to stop and ask, it reaches that state most times, not every time. A take that
            # missed gets another rather than being shipped.
            for attempt in range(3):
                try:
                    made.append(record(name, spec, visible=visible, theme=theme, suffix=suffix))
                    break
                except Retryable as why:
                    say(f"  {why}")
                    if attempt == 2:
                        skipped.append((name + suffix, str(why)))
                        say("  skipped: out of retries")
                    else:
                        say(f"  retrying ({attempt + 1} of 2)")
                except Skip as why:
                    say(f"  skipped: {why}")
                    skipped.append((name + suffix, str(why)))
                    break

    srv.shutdown()
    say(f"\n{len(made)} recorded" + (f", {len(skipped)} skipped" if skipped else ""))
    for name, why in skipped:
        say(f"  {name}: {why}")


if __name__ == "__main__":
    main()
