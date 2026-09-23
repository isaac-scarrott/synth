"""Routines gate: the engine behind a saved prompt handed to an agent on a schedule.

Everything goes through the routine verbs (`automation.routine*`), which call the same public API
the board — and later a synth-app `routine_create` — does. Driven runs never tick on their own, so
the scheduler is exercised with `automation.routineTick` at a pretend `now`.

No turn is ever taken. Every worktree here is new to Claude Code, so it sits at its trust prompt
and never reports itself live — which is exactly the state a queued second firing needs, and the
seed wait is shortened so that start then fails on its own ("the agent never took the text").
A routine whose extra flags Claude rejects exits at once and proves the failure card.

What the suite protects: a run never takes the pane or the cursor; a busy routine holds one queued
run, never a pile; Test never touches the target; a catch-up fires once for the latest slot; a slot
too old is recorded rather than dropped; delete leaves branches; all of it survives a relaunch.
"""
import datetime, sys, time, uuid
sys.path.insert(0, ".")
import lib
from lib import *

print("=== T39: routines — fire, queue, test, catch-up, skip, delete, persistence ===")
kill_all()
repo = fresh_repo()
# A remote that can't be reached: every cut fetches first, and must still start.
sh(f"git -C {repo} remote add origin /nonexistent/synth-t39.git")
base = sh(f"git -C {repo} branch --show-current")
term = str(uuid.uuid4())
sd = seed_state(repo, sessions=[
    {"id": term, "kind": "terminal", "title": "dev shell", "titleIsCustom": True},
])
# Claude's config is the gate's own: Synth reads and writes the trust entries in it, and the
# Claude it spawns reads it — the user's ~/.claude.json is never touched. Onboarding is marked
# done so a spawned Claude reaches its trust decision rather than the theme picker.
import json, os, pathlib, hashlib
CFG = pathlib.Path(lib.H) / "claude-config"
sh(f"rm -rf '{CFG}'"); CFG.mkdir(parents=True)
CFG_FILE = CFG / ".claude.json"
try:
    real = json.loads((pathlib.Path.home() / ".claude.json").read_text())
except (OSError, ValueError):
    real = {}
seed_cfg = {k: real[k] for k in ("hasCompletedOnboarding", "lastOnboardingVersion", "theme") if k in real}
seed_cfg.update(fullscreenUpsellSeenCount=99, fullscreenDownsellSeenCount=99, projects={})
CFG_FILE.write_text(json.dumps(seed_cfg, indent=2))
REPO_REAL = os.path.realpath(repo)
ENV = {"SYNTH_ROUTINE_SEED_SECONDS": "25", "CLAUDE_CONFIG_DIR": str(CFG)}
p, sock = launch(sd, f"{lib.H}/t39.log", env_extra=ENV)
ctl = Ctl(sock, repo)
ctl("automation.notifRoute", route="deck")
ctl("automation.jump", sessionId=term)


def routines():
    return {r["name"]: r for r in ctl("automation.routines").get("routines", [])}


def runs(name):
    return (routines().get(name) or {}).get("runs", [])


def create(**kw):
    kw.setdefault("prompt", "Say OK and stop.")
    kw.setdefault("agent", "claudeCode")
    kw.setdefault("schedule", {"kind": "daily", "hour": 9, "minute": 0})
    return ctl("automation.routineCreate", **kw)


def nav():
    n = ctl("automation.nav")
    return n.get("openSessionId", "").lower(), n.get("navCursor", "").lower()


def git_branches():
    return sh(f"git -C {repo} branch --format='%(refname:short)'").split("\n")


# --- The API refuses what can't become a routine -------------------------------------------------
def err(**kw):
    r = create(**kw)
    return None if r.get("ok") else r.get("error")

check("1. a name is required", err(name=" ", target="fresh") == "A routine needs a name.")
check("2. a prompt is required", err(name="x", prompt="  ", target="fresh") == "A routine needs a prompt.")
check("3. an existing branch has to exist",
      err(name="x", target="existing", branch="nope") == "nope isn't a branch in repo.")
check("4. Once needs a date", err(name="x", target="fresh", schedule={"kind": "once"}) == "A Once routine needs a date.")
check("5. the project has to be in Synth",
      err(name="x", target="fresh", workspaceId=str(uuid.uuid4())) == "That project isn't in Synth.")
check("6. the agent has to be available", err(name="x", target="fresh", agent="bogus") == "That agent isn't available.")
check("7. nothing half-made was kept", routines() == {}, list(routines()))

# --- Run now: a fresh branch and a new session, and the pane never moves -------------------------
before = nav()
check("8. the dev shell is the open session", before[0] == term, before)
r1 = create(name="Nightly sweep", target="fresh")
check("9. a valid draft becomes a routine", r1.get("ok"), r1)
R1 = r1.get("id")
ctl("automation.routineFire", id=R1, trigger="runNow")
run = (runs("Nightly sweep") or [{}])[0]
check("10. Run now records a started run at once", run.get("outcome") == "started" and run.get("trigger") == "runNow", run)
check("11. on a new routine/<slug>-<stamp> branch", run.get("branch", "").startswith("routine/nightly-sweep-20"), run.get("branch"))
check("12. busy from the moment it fires", run.get("busy") is True and run.get("pending") is True, run)
row = wait(lambda: (runs("Nightly sweep")[-1] if runs("Nightly sweep") else {}).get("sessionId") and runs("Nightly sweep")[-1], 30)
check("13. the branch is cut and a session spawned in it", bool(row and row.get("worktreePath")), row)
wt1 = row and row["worktreePath"]
sess = ctl.sessions(wt1) if wt1 else []
check("14. one Claude Code session, named after the routine",
      len(sess) == 1 and sess[0]["kind"] == "claudeCode" and sess[0]["title"] == "Nightly sweep", sess)
check("15. the fetch failed and the run says it started from the local base",
      row and row.get("reason") == f"Fetch failed, so it started from your local {base}.", row and row.get("reason"))
check("16. the open session and the cursor never moved", nav() == before, (before, nav()))
check("17. no card for a start", [c for c in ctl("automation.notifs").get("notifs", [])] == [],
      ctl("automation.notifs").get("notifs"))
shot = f"{lib.H}/t39-run.png"
ctl("automation.screenshot", path=shot, window="main")
print(f"  screenshot: {shot}")

# --- A busy routine holds one queued run, carrying the latest slot ------------------------------
ctl("automation.routineFire", id=R1, trigger="runNow")
ctl("automation.routineFire", id=R1, trigger="schedule", slot=time.time())
queued = [x for x in runs("Nightly sweep") if x["outcome"] == "queued"]
check("18. firing twice while busy queues exactly one", len(queued) == 1, [x["outcome"] for x in runs("Nightly sweep")])
check("19. and it carries the latest firing", queued and queued[0]["trigger"] == "schedule", queued)

# --- Test: a throwaway -test worktree, whatever the target, never queued ------------------------
ctl("automation.routineFire", id=R1, trigger="test")
t = next((x for x in runs("Nightly sweep") if x["trigger"] == "test"), {})
check("20. Test runs even while a run is busy", t.get("outcome") == "started", t)
check("21. on routine/<slug>-test", t.get("branch") == "routine/nightly-sweep-test", t.get("branch"))
check("22. its worktree lands", bool(wait(lambda: next((x for x in runs("Nightly sweep") if x["trigger"] == "test"), {}).get("sessionId"), 30)))
ctl("automation.routineFire", id=R1, trigger="test")
tests = lambda: [x for x in runs("Nightly sweep") if x["trigger"] == "test"]
check("23. a second Test starts its own run", bool(wait(lambda: len(tests()) == 2 and tests()[0].get("sessionId"), 30)), tests())
retired = [b for b in git_branches() if b.startswith("routine/nightly-sweep-test-")]
replaced = tests()[1] if len(tests()) == 2 else {}
check("23b. the Test it replaced says so, without a card",
      replaced.get("outcome") == "failed" and replaced.get("reason", "").startswith("A newer Test replaced it")
      and not any(n["message"] == "Routine didn't start" for n in ctl("automation.notifs").get("notifs", [])), replaced)
check("24. the last Test's branch was put aside, not lost", len(retired) == 1 and "routine/nightly-sweep-test" in git_branches(),
      git_branches())
tree = ctl("automation.tree")["workspaces"][0]["branches"]
check("25. and its row archived — one live -test row", tree.count("routine/nightly-sweep-test") == 1 and not any(
      b.startswith("routine/nightly-sweep-test-") for b in tree), tree)
check("26. the pane still hasn't moved", nav() == before, (before, nav()))

# --- Catch-up: the latest missed slot fires once, as a catch-up ---------------------------------
now = datetime.datetime.now()
two_ago = now - datetime.timedelta(hours=2)
r2 = create(name="Catch up", target="fresh", extraFlags="--synth-t39-bogus-flag",
            schedule={"kind": "daily", "hour": two_ago.hour, "minute": two_ago.minute})
R2 = r2["id"]
later = time.time() + 86400
ctl("automation.routineTick", id=R2, now=later)
ctl("automation.routineTick", id=R2, now=later + 60)
c = runs("Catch up")
check("27. one catch-up for the missed slot, however many ticks see it", len(c) == 1 and c[0]["trigger"] == "catchUp",
      [(x["trigger"], x["outcome"]) for x in c])
check("28. it records the slot it was for, not when it fired", c and c[0]["slot"] and abs(c[0]["slot"] - c[0]["firedAt"]) > 3600, c and (c[0]["slot"], c[0]["firedAt"]))

# Claude refuses the extra flag and exits: the one outcome that speaks up.
f = wait(lambda: (runs("Catch up") or [{}])[0].get("outcome") == "failed" and runs("Catch up")[0], 60)
check("29. an agent that quits before taking the text fails the run", bool(f), runs("Catch up"))
check("30. with a reason in words", f and "before it took the text" in f.get("reason", ""), f and f.get("reason"))
check("31. and the routine carries the unseen dot", routines()["Catch up"]["failureUnseen"] is True)
card = next((n for n in ctl("automation.notifs").get("notifs", []) if n["message"] == "Routine didn't start"), None)
check("32. one sticky card says it didn't start", card and card["tier"] == "attention" and card["drains"] == "false"
      and card["title"] == "Catch up" and card["sub"] == f["reason"] and card["action"] == "View", card)
if card:
    ctl("automation.notifAction", sessionId=card["sessionId"])
check("33. View asks for that routine", ctl("automation.routines").get("pendingRoutineOpen") == R2)

# --- A slot older than the window is recorded, not fired -----------------------------------------
# Weekdays at 00:05, looked at on a Saturday night: the latest slot is Friday's, two days back.
sat = now + datetime.timedelta(days=7 + (5 - now.weekday()) % 7)
sat = sat.replace(hour=23, minute=0, second=0, microsecond=0)
r3 = create(name="Weekday stale", target="fresh", schedule={"kind": "weekdays", "hour": 0, "minute": 5})
R3 = r3["id"]
ctl("automation.routineTick", id=R3, now=sat.timestamp())
s = runs("Weekday stale")
check("34. a stale slot is skipped, once", len(s) == 1 and s[0]["outcome"] == "skipped", s)
check("35. with the closed reason", s and s[0]["skipReason"] == "missedTooOld"
      and s[0]["reason"] == "Synth was closed, and the slot was more than a day old by the time it opened.", s)
ctl("automation.routineTick", id=R3, now=sat.timestamp() + 60)
check("36. and never again", len(runs("Weekday stale")) == 1)

# --- Claude's folder trust: inherited from a trusted repo, never invented ---------------------
def cfg():
    return json.loads(CFG_FILE.read_text())

def trusted_paths():
    return sorted(k for k, v in cfg().get("projects", {}).items() if v.get("hasTrustDialogAccepted") is True)

check("37a. the repo isn't trusted, and nothing Synth cut has been", trusted_paths() == [], trusted_paths())
ru = create(name="Untrusted run", target="fresh")["id"]
ctl("automation.routineFire", id=ru, trigger="runNow")
u = wait(lambda: (runs("Untrusted run") or [{}])[0].get("outcome") == "failed" and runs("Untrusted run")[0], 60)
check("37b. an untrusted repo's run stalls and fails", bool(u), runs("Untrusted run"))
check("37c. saying the project isn't trusted in Claude Code, and what to do",
      u and u["reason"].startswith("repo isn't trusted in Claude Code yet") and "accept the prompt" in u["reason"],
      u and u["reason"])
check("37d. and Synth trusted nothing", trusted_paths() == [], trusted_paths())

c0 = cfg()
c0.setdefault("projects", {})[REPO_REAL] = {"hasTrustDialogAccepted": True, "allowedTools": ["Bash(ls)"]}
c0["synthGateSentinel"] = {"nested": [1, 2.5, "three", None, False], "n": 1790000000000}
CFG_FILE.write_text(json.dumps(c0, indent=2))
rt = create(name="Trusted run", target="fresh")["id"]
ctl("automation.routineFire", id=rt, trigger="runNow")
tr = wait(lambda: (runs("Trusted run") or [{}])[0].get("sessionId") and runs("Trusted run")[0], 30)
wt_real = tr and os.path.realpath(tr["worktreePath"])
c1 = cfg()
check("37e. a trusted repo's new worktree inherits the trust",
      tr and c1["projects"].get(wt_real, {}).get("hasTrustDialogAccepted") is True, tr and c1["projects"].get(wt_real))
check("37f. with that one key and nothing invented beside it",
      tr and set(c1["projects"].get(wt_real, {})) <= {"hasTrustDialogAccepted", "allowedTools", "mcpContextUris",
          "mcpServers", "enabledMcpjsonServers", "disabledMcpjsonServers", "hasClaudeMdExternalIncludesApproved",
          "hasClaudeMdExternalIncludesWarningShown", "projectOnboardingSeenCount", "lastSessionId", "history",
          "hasCompletedProjectOnboarding", "exampleFiles", "exampleFilesGeneratedAt"},
      tr and sorted(c1["projects"].get(wt_real, {})))
check("37g. every other key is carried through as it was",
      c1.get("synthGateSentinel") == c0["synthGateSentinel"]
      and c1["projects"][REPO_REAL]["allowedTools"] == ["Bash(ls)"]
      and all(c1.get(k) == v for k, v in seed_cfg.items() if k != "projects"),
      {k: c1.get(k) for k in ("synthGateSentinel",)})
check("37h. and only the repo and the worktree Synth cut are trusted", trusted_paths() == sorted([REPO_REAL, wt_real]),
      trusted_paths())
for rid in (ru, rt):
    ctl("automation.routineDelete", id=rid)

# --- Delete: the routine and its queue go; its branches and the busy run stay -------------------
fresh_branch = runs("Nightly sweep")[-1]["branch"]
ctl("automation.routineDelete", id=R1)
check("37. delete removes the routine and its queued run", "Nightly sweep" not in routines())
check("38. its branches stay", fresh_branch in git_branches()
      and fresh_branch in ctl("automation.tree")["workspaces"][0]["branches"], fresh_branch)
check("39. the run it had going carries on", len(ctl.sessions(wt1)) == 1, ctl.sessions(wt1))

# The headless session is a real terminal: opened, the view it booted in moves into the pane.
sid = ctl.sessions(wt1)[0]["sessionId"]
ctl("automation.jump", worktree=wt1, sessionId=sid)
time.sleep(2)
shot2 = f"{lib.H}/t39-opened.png"
ctl("automation.screenshot", path=shot2, window="main")
print(f"  screenshot: {shot2}")
check("39b. opening the run's session shows it", nav()[0] == sid.lower(), nav())

time.sleep(5)   # the autosave cadence
kept = routines()
p.terminate(); p.wait()

p, sock = launch(sd, f"{lib.H}/t39b.log", env_extra=ENV)
ctl = Ctl(sock, repo)
back = routines()
check("40. routines survive a relaunch", sorted(back) == sorted(kept) == ["Catch up", "Weekday stale"], sorted(back))
check("41. with their runs, outcomes and slots",
      all([(x["id"], x["outcome"], x["slot"]) for x in back[n]["runs"]]
          == [(x["id"], x["outcome"], x["slot"]) for x in kept[n]["runs"]] for n in back),
      {n: [x["outcome"] for x in back[n]["runs"]] for n in back})
check("42. and the unseen dot", back.get("Catch up", {}).get("failureUnseen") is True)

p.terminate()
kill_all()
sys.exit(result())
