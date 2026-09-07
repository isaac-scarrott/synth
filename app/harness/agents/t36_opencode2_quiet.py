"""An opencode2 row's terminal carries the TUI and nothing else.

v2's server is a second process the shim starts behind the visible one, and it talks: "server
listening on …" at startup, then a "spawning process { command: … }" line every time its MCP
subsystem starts a local server. Inherited, those land on the row's PTY — on top of the TUI drawing
on the same terminal, mid-frame, unreadable and unexplainable to anyone looking at it.

Driven from the shim rather than from a Synth row: what is under test is which file descriptors
`serve` was handed, and a row's own PTY content is not something the control socket can hand back.
The MCP payload is a process that does nothing but exist for 20s — the log line is about spawning
one, not about which one, so the gate needs no MCP server of Synth's to be installed.
"""
import os, pathlib, secrets, socket, subprocess, sys, time
sys.path.insert(0, ".")
from lib import *

print("=== T36: opencode2's server does not print into the row's terminal ===")

OPENCODE2 = os.path.expanduser("~/.opencode/bin/opencode2")
if not os.access(OPENCODE2, os.X_OK):
    skip("no `opencode2` CLI at ~/.opencode/bin (only Synth's shim resolves)")

shim = f"{APP}/Contents/MacOS/synth-hook"
if not os.access(shim, os.X_OK):
    skip(f"no synth-hook in {APP}")

kill_all()

# The shim reads the agent it is being asked to be from its own name.
run_dir = pathlib.Path(H) / "t36"
run_dir.mkdir(parents=True, exist_ok=True)
named = run_dir / "opencode2"
sh(f"cp -f '{shim}' '{named}'")

# The app mints the port per session; standing in for it here means asking the kernel for a free
# one the same way, so a gate run alongside a live Synth cannot collide with a row's own server.
probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
probe.bind(("127.0.0.1", 0))
port = str(probe.getsockname()[1])
probe.close()
env = dict(os.environ)
env.update({
    "SYNTH_SESSION_ID": "36363636-3636-3636-3636-363636363636",
    "SYNTH_REAL_OPENCODE2": OPENCODE2,
    "SYNTH_OPENCODE2_PORT": port,
    "SYNTH_OPENCODE2_PASSWORD": secrets.token_hex(8),
    "SYNTH_MCP_OPENCODE": '{"mcp":{"t36-probe":{"type":"local","enabled":true,"environment":{},'
                          '"command":["node","-e","setTimeout(()=>{},20000)"]}}}',
})

out = run_dir / "row.out"
with open(out, "wb") as f:
    row = subprocess.Popen([str(named)], stdout=f, stderr=subprocess.STDOUT, env=env)

# Long enough for the TUI to paint and for the server to have started the probe process — the
# window in which every leaked line would have been written.
tui_up = wait(lambda: b"1049h" in out.read_bytes() or None, 40)
time.sleep(8)
text = out.read_bytes()
row.terminate()
sh(f"pkill -f 'opencode2 serve --port {port}'")
sh(f"pkill -f 'server http://127.0.0.1:{port}'")

check("1. the TUI takes the terminal", tui_up is not None)
check("2. no MCP process-spawn log lands on it", b"spawning process" not in text,
      text.count(b"spawning process"))
check("3. nor the server's own startup line", b"server listening" not in text)

sys.exit(result())
