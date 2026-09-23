"""Routines, live: real Claude Code turns on the user's own subscription (haiku, tiny prompts).

t39 proves the machinery without ever taking a turn. This one proves the thing a person actually
relies on: a routine hands its prompt to a live agent that does the work, in the right place, while
nothing the user is holding moves — for every target, the queue, the real scheduler clock, a
catch-up across a relaunch, Test and its clean-up, and a start that fails.

Opt-in (it spends real tokens): SYNTH_LIVE_CLAUDE=1. Claude reads the real ~/.claude.json (its
login lives there), so the fixture repo is trusted in it for the run, and every project entry the
run added — the fixture, its worktrees — is removed again at the end, touching nothing else.
"""
import datetime, json, os, pathlib, sys, time, uuid
sys.path.insert(0, ".")
import lib
from lib import *

if os.environ.get("SYNTH_LIVE_CLAUDE") != "1":
    skip("set SYNTH_LIVE_CLAUDE=1 to take real Claude turns")

print("=== T40: routines, live — real turns for every target, the queue, the clock, catch-up ===")
CLAUDE_JSON = pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR") or pathlib.Path.home()) / ".claude.json"


def edit_claude_json(fn):
    """Re-read, change, write atomically — Claude writes this file too."""
    c = json.loads(CLAUDE_JSON.read_text())
    fn(c)
    tmp = CLAUDE_JSON.with_name(f".claude.json.t40-{os.getpid()}")
    tmp.write_text(json.dumps(c, indent=2))
    os.chmod(tmp, 0o600)
    os.replace(tmp, CLAUDE_JSON)


before_keys = set(json.loads(CLAUDE_JSON.read_text()).get("projects", {}))
kill_all()
repo = fresh_repo()
REPO_REAL = os.path.realpath(repo)
edit_claude_json(lambda c: c.setdefault("projects", {}).setdefault(REPO_REAL, {}).update(hasTrustDialogAccepted=True))

term = str(uuid.uuid4())
sd = seed_state(repo, sessions=[{"id": term, "kind": "terminal", "title": "dev shell", "titleIsCustom": True}])
ENV = {"SYNTH_ROUTINE_TICK_SECONDS": "5", "SYNTH_ROUTINE_SEED_SECONDS": "120"}
FLAGS = "--model haiku --permission-mode acceptEdits"
p, sock = launch(sd, f"{lib.H}/t40.log", env_extra=ENV)
ctl = Ctl(sock, repo)
ctl("automation.notifRoute", route="deck")
ctl("automation.jump", sessionId=term)


def nav():
    n = ctl("automation.nav")
    return n.get("openSessionId", "").lower(), n.get("navCursor", "").lower()


HOME = nav()
check("0. the dev shell is the open session and the cursor", HOME == (term.lower(), term.lower()), HOME)
moved = []   # every moment the pane or cursor was seen anywhere but HOME
seen_done = set()


def sample():
    n = nav()
    if n != HOME: moved.append(n)
    for c in ctl("automation.notifs").get("notifs", []):
        if c["kind"] == "done": seen_done.add(c["sessionId"].lower())


def routines():
    return {r["name"]: r for r in ctl("automation.routines").get("routines", [])}


def runs(name):
    return (routines().get(name) or {}).get("runs", [])


def create(name, prompt, **kw):
    kw.setdefault("agent", "claudeCode")
    kw.setdefault("extraFlags", FLAGS)
    kw.setdefault("schedule", {"kind": "weekly", "weekday": 1, "hour": 3, "minute": 0})
    r = ctl("automation.routineCreate", name=name, prompt=prompt, **kw)
    assert r.get("ok"), r
    return r["id"]


def session(sid, wt):
    return next((s for s in ctl.sessions(wt) if s["sessionId"].lower() == sid.lower()), None)


def finished(run_pred, secs=240):
    """Wait for a started run whose agent took its turn and settled: returns (run, session)."""
    deadline = time.time() + secs
    took = False
    while time.time() < deadline:
        sample()
        run = run_pred()
        if run and run.get("outcome") == "failed":
            return run, None
        if run and run.get("sessionId") and run.get("worktreePath"):
            s = session(run["sessionId"], run["worktreePath"])
            if s and s["status"] in ("working", "running"): took = True
            if took and s and s["status"] == "idle":
                return run, s
        time.sleep(1)
    return run_pred(), None


def notes(path):
    f = pathlib.Path(path) / "notes.txt"
    return f.read_text().split() if f.exists() else []


PROMPT = ("Append one line containing exactly the word {w} to the file notes.txt in the current "
          "directory, creating it if it doesn't exist. Use your file editing tools only, no shell. "
          "Then reply with the single word done.")

# --- 1. New each run: Run now → a real turn on a fresh branch -----------------------------------
fresh = create("Fresh note", PROMPT.format(w="fresh"), target="fresh")
ctl("automation.routineFire", id=fresh, trigger="runNow")
run, s = finished(lambda: (runs("Fresh note") or [None])[0])
check("1. Run now: the agent took the prompt and settled", bool(s), run)
wt1 = run and run.get("worktreePath")
check("1a. on a new routine/fresh-note-<stamp> branch", bool(run) and run["branch"].startswith("routine/fresh-note-"), run)
check("1b. and did the work there", bool(wt1) and notes(wt1) == ["fresh"], wt1 and notes(wt1))
check("1c. the session is unread, with the normal done card", bool(s) and s["unread"] and run["sessionId"].lower() in seen_done,
      (s, seen_done))
check("1d. the repo's trust was carried to the worktree Synth cut",
      json.loads(CLAUDE_JSON.read_text())["projects"].get(os.path.realpath(wt1 or "/x"), {}).get("hasTrustDialogAccepted") is True)
check("1e. the preamble reached the agent (run shows no failure reason)", bool(run) and run.get("reason", "") == "", run)

# --- 2. The queue: a second Run now while the first is busy waits, then runs on its own ---------
ctl("automation.routineFire", id=fresh, trigger="runNow")
time.sleep(1.5)
ctl("automation.routineFire", id=fresh, trigger="runNow")
rs = runs("Fresh note")
check("2. firing while busy queues exactly one", [r["outcome"] for r in rs[:2]] == ["queued", "started"], [r["outcome"] for r in rs[:3]])
first_q = rs[1]["id"] if len(rs) > 1 else ""
r1, s1 = finished(lambda: next((r for r in runs("Fresh note") if r["id"] == first_q), None))
check("2a. the busy run finished", bool(s1), r1)
r2, s2 = finished(lambda: (runs("Fresh note") or [None])[0] if runs("Fresh note")[0]["outcome"] != "queued" else None)
check("2b. the queued run started by itself once the first settled, and finished", bool(s2) and r2["id"] != first_q, r2)
check("2c. each on its own branch", bool(r1 and r2) and r1["branch"] != r2["branch"] and r2["branch"] != run["branch"],
      (r1 and r1["branch"], r2 and r2["branch"]))
check("2d. both did the work", bool(r1 and r2) and notes(r1["worktreePath"]) == ["fresh"] and notes(r2["worktreePath"]) == ["fresh"])

# --- 3. Same each run: continuity, and the read previous session closes -------------------------
same = create("Same note", PROMPT.format(w="same"), target="same")
ctl("automation.routineFire", id=same, trigger="runNow")
ra, sa = finished(lambda: (runs("Same note") or [None])[0])
check("3. same-each-run: first run done", bool(sa), ra)
wt3 = ra and ra["worktreePath"]
# Read it the way a person does — open it, then go back to what you were doing.
ctl("automation.jump", worktree=wt3, sessionId=ra["sessionId"]); time.sleep(1)
ctl("automation.jump", sessionId=term); time.sleep(1)
check("3a. back home before the next run", nav() == HOME, nav())
ctl("automation.routineFire", id=same, trigger="runNow")
rb, sb = finished(lambda: (lambda x: x if x and x["id"] != ra["id"] else None)((runs("Same note") or [None])[0]))
check("3b. second run done on the same branch", bool(sb) and rb["branch"] == "routine/same-note" and rb["worktreePath"] == wt3, rb)
check("3c. commits/work carried over: two lines", notes(wt3) == ["same", "same"], notes(wt3))
check("3d. the read, idle previous session was closed; one run session left",
      [x["sessionId"].lower() for x in ctl.sessions(wt3)] == [rb["sessionId"].lower()], ctl.sessions(wt3))

# --- 4. Existing branch: runs on the repo-root checkout -----------------------------------------
base = sh(f"git -C {repo} branch --show-current")
ex = create("Existing note", PROMPT.format(w="existing"), target="existing", branch=base)
ctl("automation.routineFire", id=ex, trigger="runNow")
re_, se = finished(lambda: (runs("Existing note") or [None])[0])
check("4. existing-branch run done", bool(se), re_)
check("4a. in the repo's own checkout", bool(re_) and os.path.realpath(re_["worktreePath"]) == REPO_REAL and notes(repo) == ["existing"],
      (re_ and re_["worktreePath"], notes(repo)))
check("4b. no new branch was cut for it", "routine/existing-note" not in sh(f"git -C {repo} branch"))

# --- 5. The real clock: a Daily slot a minute out fires on its own ------------------------------
t = datetime.datetime.now() + datetime.timedelta(seconds=75)
t = t.replace(second=0, microsecond=0)
if (t - datetime.datetime.now()).total_seconds() < 25: t += datetime.timedelta(minutes=1)
timed = create("Timed note", PROMPT.format(w="timed"), target="fresh",
               schedule={"kind": "daily", "hour": t.hour, "minute": t.minute})
check("5. its next slot is that minute", abs(routines()["Timed note"]["nextSlot"] - t.timestamp()) < 1,
      (routines()["Timed note"]["nextSlot"], t.timestamp()))
check("5a. nothing before the slot", runs("Timed note") == [])
rt, st = finished(lambda: (runs("Timed note") or [None])[0], secs=(t - datetime.datetime.now()).total_seconds() + 240)
check("5b. the scheduler fired it at the slot, by itself", bool(rt) and rt["trigger"] == "schedule"
      and abs(rt["slot"] - t.timestamp()) < 1 and 0 <= rt["firedAt"] - t.timestamp() < 20, rt)
check("5c. and the agent did the work", bool(st) and notes(rt["worktreePath"]) == ["timed"], rt)
check("5d. it isn't due again today", routines()["Timed note"]["nextSlot"] > t.timestamp() + 3600)

# --- 6. Test on a same-each-run routine: its own worktree, archived when its session closes -----
ctl("automation.routineFire", id=same, trigger="test")
rtst, stst = finished(lambda: (lambda x: x if x and x["trigger"] == "test" else None)((runs("Same note") or [None])[0]))
check("6. Test ran on routine/same-note-test and did the work",
      bool(stst) and rtst["branch"] == "routine/same-note-test" and notes(rtst["worktreePath"]) == ["same"], rtst)
check("6a. and never touched the routine's own branch", notes(wt3) == ["same", "same"])
ctl("automation.requestDelete", worktree=rtst["worktreePath"], sessionId=rtst["sessionId"])
tree = lambda: ctl("automation.tree")["workspaces"][0]["branches"]
check("6b. while the close can still be undone, the test worktree stays", "routine/same-note-test" in tree(), tree())
# A live session's close waits out its undo card, and a card only drains while Synth has focus —
# which a driven instance never does, so say it came back (as t3 does).
ctl("automation.notifFocus", active=True)
check("6c. once the close commits, the test worktree archives",
      bool(wait(lambda: "routine/same-note-test" not in tree(), 30)), tree())
ctl("automation.notifFocus", active=False)

# --- 7. A start that fails speaks once, and View opens the routine ------------------------------
broken = create("Broken", PROMPT.format(w="x"), target="fresh", extraFlags="--model haiku --no-such-flag")
ctl("automation.routineFire", id=broken, trigger="runNow")
rf, _ = finished(lambda: (runs("Broken") or [None])[0], secs=90)
check("7. the run records didn't start, with a reason", bool(rf) and rf["outcome"] == "failed" and rf["reason"], rf)
card = next((n for n in ctl("automation.notifs").get("notifs", []) if n["message"] == "Routine didn't start"), None)
check("7a. one sticky card", bool(card) and card["tier"] == "attention", card)
check("7b. and the sidebar dot", routines()["Broken"]["failureUnseen"] is True)
if card: ctl("automation.notifAction", sessionId=card["sessionId"])
board = ctl("automation.routineBoard")
check("7c. View opened that routine, and the dot cleared", board.get("open") and broken.lower() in board.get("view", "").lower()
      and routines()["Broken"]["failureUnseen"] is False, board)
shot = f"{lib.H}/t40-board.png"
ctl("automation.routineBoard", action="open", id=fresh); time.sleep(1.5)
ctl("automation.screenshot", path=shot, window="main"); print(f"  screenshot: {shot}")

# --- 8. Catch-up across a relaunch: a Once missed while Synth was closed runs on the next launch
once_at = datetime.datetime.now() + datetime.timedelta(seconds=90)
once_at = once_at.replace(second=0, microsecond=0) + datetime.timedelta(minutes=1)
day0 = datetime.datetime(once_at.year, once_at.month, once_at.day)
once = create("Once note", PROMPT.format(w="once"), target="fresh",
              schedule={"kind": "once", "hour": once_at.hour, "minute": once_at.minute, "date": day0.timestamp()})
check("8. the Once is due at its minute", abs(routines()["Once note"]["nextSlot"] - once_at.timestamp()) < 1)
check("8z. nothing the user held moved, in any of the above", moved == [], moved[:5])
time.sleep(6)   # the autosave cadence
p.terminate(); p.wait()
while datetime.datetime.now() < once_at + datetime.timedelta(seconds=15): time.sleep(2)
p, sock = launch(sd, f"{lib.H}/t40b.log", env_extra=ENV)
ctl = Ctl(sock, repo)
ctl("automation.notifRoute", route="deck")
ctl("automation.jump", sessionId=term)
HOME = nav(); moved.clear()
ro, so = finished(lambda: (runs("Once note") or [None])[0], secs=240)
check("8a. it caught up after the relaunch, for the slot it missed", bool(ro) and ro["trigger"] == "catchUp"
      and abs(ro["slot"] - once_at.timestamp()) < 1 and ro["firedAt"] > ro["slot"] + 10, ro)
check("8b. and the agent did the work", bool(so) and notes(ro["worktreePath"]) == ["once"], ro)
check("8c. a fired Once never fires again", routines()["Once note"]["nextSlot"] == 0)
check("8d. routines, history and marks came back", {"Fresh note", "Same note", "Existing note", "Timed note", "Broken", "Once note"}
      <= set(routines()) and len(runs("Fresh note")) >= 3)
check("8e. and the relaunch catch-up moved nothing either", moved == [], moved[:5])

p.terminate(); p.wait()
kill_all()


def cleanup(c):
    projects = c.get("projects", {})
    for k in list(projects):
        if k not in before_keys and (k.startswith(REPO_REAL) or "Synth Dev/worktrees/repo-" in k or k.startswith(os.path.realpath(lib.H))):
            del projects[k]


edit_claude_json(cleanup)
check("9. every Claude project entry the run added is gone again",
      set(json.loads(CLAUDE_JSON.read_text()).get("projects", {})) - before_keys == set())
sys.exit(result())
