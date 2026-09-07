"""OpenCode 2: ctrl+c stops the turn, and a question lights the row.

Two things v2 got wrong that v1 already had right, both of them invisible until you drive a real
one (docs/features/2026-09-07.md):

  - `app.exit` ships bound to `ctrl+c`, so the gesture every agent user reaches for mid-turn quits
    the agent outright — exit 0, no confirmation, the row parked on a Reopen card. v1's supervisor
    rebinds it through `OPENCODE_TUI_CONFIG`; v2 deleted that variable, so the binding is claimed
    in `cli.json` itself and this proves both halves: the file the app writes, and a real TUI
    launched under it surviving the keystroke.
  - `form.created` — v2's question surface — nests its session id (`data.form.sessionID`) where
    every other session-scoped event puts it at the top of `data`. Matched on the flat shape it
    carries no id at all, so every question opencode2 asked went unreported and the row never
    showed a `?`. Raised here over the row's own API rather than by waiting for a model to choose
    to ask one: what is under test is the event's shape, not a model's judgement.
"""
import base64, json as _j, os, pathlib, pty, secrets, socket, sys, threading, time, urllib.request
sys.path.insert(0, ".")
from lib import *

print("=== T37: OpenCode 2 — ctrl+c interrupts, a form lights the row ===")

OPENCODE2 = os.path.expanduser("~/.opencode/bin/opencode2")
if not os.access(OPENCODE2, os.X_OK):
    skip("no `opencode2` CLI at ~/.opencode/bin (only Synth's shim resolves)")
shim = f"{APP}/Contents/MacOS/synth-hook"
if not os.access(shim, os.X_OK):
    skip(f"no synth-hook in {APP}")

CLI_JSON = pathlib.Path(
    os.environ.get("XDG_CONFIG_HOME") or (pathlib.Path.home() / ".config")) / "opencode/cli.json"

# What the file held before Synth ever ran: check 4 is that all of it comes back out again.
before_keys = set(_j.loads(CLI_JSON.read_text())) if CLI_JSON.exists() else set()

kill_all()
repo = fresh_repo()
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t37.log")
ctl = Ctl(sock, repo)


def api(method, path, port, pw, body=None):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=_j.dumps(body).encode() if body is not None else None, method=method)
    req.add_header("Authorization", "Basic " + base64.b64encode(f"opencode:{pw}".encode()).decode())
    if body is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read().decode()
        return _j.loads(raw) if raw else None


def env_var(pid, name):
    for tok in (sh(f"ps eww -p {pid}") or "").split():
        if tok.startswith(name + "="):
            return tok.split("=", 1)[1]
    return None


# ---------------------------------------------------- 1. the app claims the two bindings
sid = ctl("automation.newAgent", agent="opencode2")["sessionId"]
check("1. goes live", bool(wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 60)))

binds = wait(lambda: (_j.loads(CLI_JSON.read_text()).get("keybinds") if CLI_JSON.exists() else None), 20)
check("2. ctrl+c is no longer bound to app.exit",
      bool(binds) and "ctrl+c" not in (binds.get("app.exit") or ""), binds and binds.get("app.exit"))
check("3. it interrupts the turn instead",
      bool(binds) and "ctrl+c" in (binds.get("session.interrupt") or ""),
      binds and binds.get("session.interrupt"))
cli = set(_j.loads(CLI_JSON.read_text()))
check("4. every other key the user's cli.json held survives the write",
      before_keys <= cli, sorted(before_keys - cli))

# ---------------------------------------------------- 2. a form lights the row
cmd = sh("ps -eo command= | grep 'opencode2 --server' | grep -v grep") or ""
port = cmd.split("--server http://127.0.0.1:")[1].split()[0] if "--server http://127.0.0.1:" in cmd else None
serve_pids = {int(l.split()[0]) for l in
              (sh("ps -eo pid=,command= | grep 'opencode2 serve --port' | grep -v grep") or "").splitlines()
              if l.strip()}
pw = next((env_var(q, "OPENCODE_PASSWORD") for q in serve_pids if env_var(q, "OPENCODE_PASSWORD")), None)
check("5. the row's own server is reachable", bool(port and pw), port)

# A long prompt, only to put the row mid-turn: a question always interrupts work in flight, and
# Synth drops a `needsInput` that arrives at a settled row (Store's own race guard).
ctl("automation.deliver", sessionId=sid,
    text="Count slowly from 1 to 400, one number per line, a sentence about each.")
check("6. the row reports working", bool(wait(
    lambda: ((ctl.row(sid) or {}).get("status") == "working") or None, 90, 0.3)))
conv = wait(lambda: (ctl.row(sid) or {}).get("agentSessionId"), 30)

if port and pw and conv:
    api("POST", f"/api/session/{conv}/form", port, pw,
        {"title": "Which one?", "fields": [{"key": "pick", "type": "string", "title": "Pick"}]})
check("7. a form lights the row's needs-input mark", bool(wait(
    lambda: ((ctl.row(sid) or {}).get("status") == "needsInput") or None, 30, 0.2)),
    (ctl.row(sid) or {}).get("status"))

if port and pw and conv:
    api("POST", f"/api/session/{conv}/interrupt", port, pw, {})
p.terminate()
time.sleep(1)
kill_all()

# ---------------------------------------------------- 3. a real TUI survives the keystroke
# Driven from the shim, not a Synth row: what is under test is whether the TUI process lives
# through a ^C written to its own pty, and a row's pty is not something the control socket reaches.
run_dir = pathlib.Path(H) / "t37"
run_dir.mkdir(parents=True, exist_ok=True)
named = run_dir / "opencode2"
sh(f"cp -f '{shim}' '{named}'")

probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
probe.bind(("127.0.0.1", 0)); tui_port = str(probe.getsockname()[1]); probe.close()
env = dict(os.environ)
env.update({
    "SYNTH_SESSION_ID": "37373737-3737-3737-3737-373737373737",
    "SYNTH_REAL_OPENCODE2": OPENCODE2,
    "SYNTH_OPENCODE2_PORT": tui_port,
    "SYNTH_OPENCODE2_PASSWORD": secrets.token_hex(8),
    "SYNTH_OPENCODE2_LOG": str(run_dir / "serve.log"),
})

pid, fd = pty.fork()
if pid == 0:
    os.chdir(str(repo))
    os.execve(str(named), [str(named)], env)

screen = bytearray()
def reader():
    while True:
        try: d = os.read(fd, 65536)
        except OSError: return
        if not d: return
        screen.extend(d)
threading.Thread(target=reader, daemon=True).start()

up = wait(lambda: (b"1049h" in bytes(screen)) or None, 60)
check("8. the TUI takes the terminal", up is not None)

def settled(seconds):
    """Alive after `seconds`, or None if it exited on its own — which is a different failure
    from the one under test, and has to be told apart from it rather than crashing the write."""
    for _ in range(seconds * 5):
        if os.waitpid(pid, os.WNOHANG)[0] != 0:
            return None
        time.sleep(0.2)
    return True

check("9. the row stays up on its own, before any keystroke", settled(4) is not None,
      (run_dir / "serve.log").read_text()[-400:] if (run_dir / "serve.log").exists() else "")
try:
    os.write(fd, b"\x03")
except OSError as e:
    check("10. ctrl+c does not quit the agent", False, f"pty already closed: {e}")
else:
    check("10. ctrl+c does not quit the agent", settled(8) is not None)
try: os.kill(pid, 9)
except Exception: pass
sh(f"pkill -f 'opencode2 serve --port {tui_port}'")
sh(f"pkill -f 'server http://127.0.0.1:{tui_port}'")

sys.exit(result())
