"""Antigravity's whole status vocabulary: every state the other two agents report, from agy.

t15 proves the chain moves at all — a row that boots, works and goes quiet. This is the states
either side of that: the agent stopping to ask a human, and the endings that are not a clean
finish. Both were missing, and both failed silently, which is the worst way for a status to be
wrong: the sidebar said "working" while the TUI sat waiting on a question nobody was looking at.

Part 1 drives the shim's event role directly. Every status Antigravity has comes down to one
classification — an event name plus its payload becomes one word on the hook socket — so it is
assertable without a model, a token or a network. It is also where the traps live: agy reads a
PreToolUse handler's stdout as a verdict whose `decision` is required, so a handler that prints
anything at all (even `{}`) hard-denies the tool it was only meant to observe.

Part 2 takes the one live turn the classification can't stand in for: a real `ask_question`,
whose PreToolUse is the only hook agy gives for a blocked agent, and which is the state a user
meets first when they ask Antigravity anything ambiguous.
"""
import sys, os, json, socket, subprocess, threading, time; sys.path.insert(0, ".")
from lib import *

print("=== T18: every Antigravity status — question, cancel, cap, failure ===")

SHIM = f"{APP}/Contents/MacOS/synth-hook"
if not os.path.exists(SHIM):
    skip(f"no synth-hook in the bundle under test ({SHIM})")

# --- Part 1: the classification, offline ------------------------------------------------------
# A stub of the app's own hook socket: the shim connects, writes its line(s) and closes, exactly
# as it does to HookServer, so what this reads back IS what a row would have been told.
SOCK = f"{H}/t18-hook.sock"
SID = str(uuid.uuid4())
if os.path.exists(SOCK): os.unlink(SOCK)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK); srv.listen(8)
received = []

def accept_loop():
    while True:
        try: conn, _ = srv.accept()
        except OSError: return
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk: break
            data += chunk
        conn.close()
        for line in data.decode().splitlines():
            if line.strip(): received.append(json.loads(line))

threading.Thread(target=accept_loop, daemon=True).start()

def fire(event, payload):
    """Run one hook the way agy runs it, and return (signals, stdout)."""
    received.clear()
    env = dict(os.environ, SYNTH_SESSION_ID=SID, SYNTH_SOCKET_PATH=SOCK, SYNTH_HOOK_BIN=SHIM)
    r = subprocess.run([SHIM, "event", event], input=json.dumps(payload).encode(),
                       capture_output=True, env=env, timeout=20)
    time.sleep(0.2)   # the socket write is on the shim's way out
    return [m["signal"] for m in received if "signal" in m], r.stdout

def tool(name):  return {"toolCall": {"name": name, "args": {}}, "stepIdx": 3}
def stop(reason, error=""):
    return {"terminationReason": reason, "error": error, "fullyIdle": True, "executionNum": 0}

# The one hook agy gives for a stopped agent. Its PreToolUse fires for every tool, so the tool's
# own name is the whole signal: `ask_question` is Antigravity's AskUserQuestion — the loop is
# stopped dead until a human answers — and everything else is the agent working.
sig, out = fire("agy:PreToolUse", tool("ask_question"))
check("1. a question asks for the user (PreToolUse ask_question → needsInput)",
      sig == ["needsInput"], sig)
sig, _ = fire("agy:PreToolUse", tool("run_command"))
check("2. every other tool is work, not a block", sig == ["working"], sig)
sig, _ = fire("agy:PostToolUse", tool("ask_question"))
check("3. the answer landing clears it (PostToolUse → working)", sig == ["working"], sig)

# The endings. agy has no StopFailure of Claude's: one `Stop` fires for every way a loop can end
# and `terminationReason` is the only place the difference is written down.
for n, (reason, error, want) in enumerate([
        ("NO_TOOL_CALL", "", "idle"),                 # the ordinary finish
        ("USER_CANCELED", "", "idle"),                # esc — never a red row
        ("ERROR", "", "error"),
        ("NO_TOOL_CALL", "boom", "error"),            # an error carried on an ordinary reason
        ("MAX_INVOCATIONS", "", "error"),             # gave up, did not finish
        ("MAX_TOKEN_BUDGET_EXCEEDED", "", "error"),
        ("EXECUTOR_TERMINATION_REASON_ERROR", "", "error"),   # untrimmed enum spelling
], start=4):
    sig, _ = fire("agy:Stop", stop(reason, error))
    check(f"{n}. Stop {reason}{' + error' if error else ''} → {want}", sig == [want], sig)

# The rest of the loop is unambiguous work — PostInvocation especially, because it is the only
# thing that fires after a permission prompt the user approves (agy defers a long command to a
# later status step, so there may be no PostToolUse to clear the block).
for n, event in enumerate(["PreInvocation", "PostInvocation"], start=11):
    sig, _ = fire(f"agy:{event}", {"invocationNum": 1, "initialNumSteps": 3})
    check(f"{n}. {event} → working", sig == ["working"], sig)

# The trap that costs an afternoon: agy reads a PreToolUse handler's stdout as a permission
# verdict whose `decision` is required, so an observer that prints ANYTHING denies the tool.
_, out = fire("agy:PreToolUse", tool("run_command"))
check("13. an observing hook says nothing on stdout, so no tool is ever denied", out == b"", out)

# Resume rides the same payloads: every agy hook carries the conversation to restore.
received.clear()
fire("agy:Stop", dict(stop("NO_TOOL_CALL"), conversationId="c0ffee00-0000-4000-8000-000000000001"))
check("14. the conversation id rides every hook",
      any(m.get("agentSession") == "c0ffee00-0000-4000-8000-000000000001" for m in received),
      received)

srv.close()

# --- Part 2: the live question ----------------------------------------------------------------
# Everything above is the shim's half. This is the other half: that agy really does route
# `ask_question` through a PreToolUse hook, that the hooks the shim injects are the ones loaded,
# and that the row a user is looking at turns amber-to-? on its own.
require_agy_auth()
kill_all()

repo = fresh_repo(); agy_trust(repo)
sd = seed_state(repo)
p, sock = launch(sd, f"{H}/t18.log", env_extra=no_browser_env())
ctl = Ctl(sock, repo)
sid = ctl("automation.newAgent", agent="antigravity")["sessionId"]

hooks = pathlib.Path(f"/tmp/synth-agy-{p.pid}/{sid}/.agents/hooks.json")
wait(lambda: hooks.exists() or None, 60, 0.5)
wired = set(json.loads(hooks.read_text()).get("synth", {})) if hooks.exists() else set()
check("15. the injected config wires every event agy has",
      wired == {"PreInvocation", "PostInvocation", "PreToolUse", "PostToolUse", "Stop"}, sorted(wired))

check("16. the row goes live", bool(wait(lambda: (ctl.row(sid) or {}).get("liveAgent"), 90)))
ctl("automation.deliver", sessionId=sid,
    text="Use your ask_question tool right now to ask me which colour I prefer. "
         "Ask nothing else and do no other work first.")
check("17. a real ask_question stops the row for the user",
      bool(wait(lambda: ((ctl.row(sid) or {}).get("status") == "needsInput") or None, 180, 0.5)),
      (ctl.row(sid) or {}).get("status"))
# And it does not stick: answering the question is a normal turn again. Anything that moves the
# row off needsInput proves the clear — the answer's PostToolUse, or the Stop that follows it.
ctl("automation.deliver", sessionId=sid, text="blue")
check("18. answering it releases the row",
      bool(wait(lambda: ((ctl.row(sid) or {}).get("status") in ("working", "idle")) or None, 120, 0.5)),
      (ctl.row(sid) or {}).get("status"))

p.terminate()
sys.exit(result())
