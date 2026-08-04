"""Antigravity end to end: a row that boots, works, goes quiet, and knows its conversation.

The same lifecycle t7 holds opencode to, against the third agent — because a supervisor is only
real once the sidebar's derived facts move on their own. Antigravity carries no event stream:
every fact here arrives as one of its hooks (PreInvocation → working, Stop → idle), so a row that
merely looks alive proves the whole chain — shim, injected `.agents/hooks.json`, hook socket,
supervisor, store.

Part 1 is the screen that stands between launch and any of that: on a path `agy` has never seen
it opens on a modal trust prompt, which EVERY fresh Synth worktree hits. A row that called itself
live there would swallow the user's first comment — the paste lands in a modal and the Enter
answers the prompt — so the row must say `needsInput` and stay undeliverable until a human
answers. Part 2 answers it the way a user does and runs the real lifecycle.

It takes a real turn against a real model, so it needs a signed-in `agy` and skips without one.
"""
import sys, time; sys.path.insert(0, ".")
from lib import *

print("=== T15: the Antigravity lifecycle — live, working, idle, named ===")
require_agy_auth()
kill_all()

repo = fresh_repo(); sd = seed_state(repo)

# --- Part 1: the workspace trust prompt ------------------------------------------------------
# Revoked rather than assumed: the prompt only ever appears once per path, so a gate that waited
# for a virgin worktree would assert this on its first run and nothing after.
agy_trust(repo, trusted=False)
p, sock = launch(sd, f"{H}/t15a.log", env_extra=no_browser_env())
ctl = Ctl(sock, repo)

sid = ctl("automation.newAgent", agent="antigravity")["sessionId"]
check("1. the row is an antigravity row", (ctl.row(sid) or {}).get("kind") == "antigravity",
      (ctl.row(sid) or {}).get("kind"))

cmd = wait(lambda: agy_process(), 40) or ""
# The one thing about this agent that can be silently wrong forever: `agy` also names the
# Antigravity IDE's GUI launcher, and it comes first on a stock login PATH (t14 holds the rule
# on a staged PATH; this is the same rule against whatever this machine actually has).
check("2. the PTY runs the Antigravity CLI, not the IDE launcher",
      bool(cmd) and not in_app_bundle(cmd.split(" ")[0]), cmd.split(" ")[0])
# Hooks only fire for workspaces agy was given, and the log is the only place a permission
# prompt surfaces — both are appended by the shim, and without either the row never moves.
check("3. the shim instrumented the launch (--add-dir hooks dir, --log-file)",
      "--add-dir" in cmd and "--log-file" in cmd, cmd[cmd.find("agy"):][:120])

check("4. an untrusted workspace reports needsInput, not a green idle row",
      bool(wait(lambda: ((ctl.row(sid) or {}).get("status") == "needsInput") or None, 60, 0.5)),
      (ctl.row(sid) or {}).get("status"))
# The whole point of the status: liveness is what lets a comment be pasted in, and here it would
# be pasted into a modal.
check("5. and it is never live while the prompt stands",
      not (ctl.row(sid) or {}).get("liveAgent"), (ctl.row(sid) or {}).get("liveAgent"))

p.terminate(); time.sleep(1); kill_all()

# --- Part 2: the lifecycle, past the prompt --------------------------------------------------
agy_trust(repo)          # the keypress a user makes once per worktree
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t15b.log", env_extra=no_browser_env())
ctl = Ctl(sock, repo)
sid = ctl("automation.newAgent", agent="antigravity")["sessionId"]

# Generous, because live means the TUI reached its input box — agy spends the first seconds on a
# sign-in spinner, and text handed over before then is dropped on the floor.
check("6. the row goes live once the workspace is trusted",
      bool(wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 90)))

check("7. a comment reaches the live agent",
      ctl("automation.deliver", sessionId=sid,
          text="Reply with exactly SYNTHOK and nothing else.").get("ok", False))
check("8. the turn greens the row (PreInvocation → working)",
      bool(wait(lambda: ((ctl.row(sid) or {}).get("status") == "working") or None, 60)))
check("9. the end of the turn settles it (Stop → idle)",
      bool(wait(lambda: ((ctl.row(sid) or {}).get("status") == "idle") or None, 180, 0.5)))
conv = wait(lambda: (ctl.row(sid) or {}).get("agentSessionId"), 30)
check("10. the conversation id is captured (what resume restores)", bool(conv), conv)
check("11. it names a real conversation on disk", bool(conv) and agy_transcript(conv).exists(),
      str(agy_transcript(conv)) if conv else "")

# A row named after its agent tells you nothing at a glance, which is the whole reason the other
# two auto-name themselves. agy's own conversation summary is a protobuf blob inside a SQLite file,
# so the shim takes the transcript's opening `<USER_REQUEST>` instead — the text delivered above,
# which is what makes this assertable rather than merely "not the default".
def named():
    t = (ctl.row(sid) or {}).get("title")
    return t if t not in ("Antigravity", "", None) else None
title = wait(named, 60, 0.5)
check("12. the row names itself from the conversation", (title or "").startswith("Reply with exactly"),
      (ctl.row(sid) or {}).get("title"))

p.terminate()   # the app tears its own PTYs down; never pkill by name (it would match the user's own agy)
sys.exit(result())
