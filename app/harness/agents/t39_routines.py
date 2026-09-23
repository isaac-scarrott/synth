"""Routines gate: the engine behind a saved prompt handed to an agent on a schedule.

Everything goes through the routine verbs (`automation.routine*`), which call the same public API
the board — and later a synth-app `routine_create` — does. Driven runs never tick on their own, so
the scheduler is exercised with `automation.routineTick` at a pretend `now`.

No turn is ever taken. Every worktree here is new to Claude Code, so it sits at its trust prompt
and never reports itself live — which is exactly the state a queued second firing needs, and the
seed wait is shortened so that start then fails on its own ("the agent never took the text").
A routine whose extra flags Claude rejects exits at once and proves the failure card.

What the suite protects: a run never takes the pane, the cursor or a session someone is holding;
a busy routine holds one queued run, never a pile; Test never touches the target, and its worktree
archives once its session is closed; a catch-up fires once for the latest slot; a slot too old is
recorded rather than dropped; a Once is used up by the run that fires it; the rows a run creates
carry its mark; delete leaves branches; all of it survives a relaunch, and a start or a queue cut
off by a quit is settled on the way back.
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
# Antigravity's trust list is the gate's own too. `agy` has no override for where it reads it, so
# the agent here is a custom one on agy's base whose command is a stand-in: it records the working
# directory `agy` would have seen (Go's os.Getwd: $PWD when it names the folder) and logs the
# workspace line agy logs, then waits — as agy does at a trust prompt, since no list of the
# user's names the folders this gate cuts. A real agy would read the user's list, and a prompt
# delivered into its trust modal would answer it there.
AGY = pathlib.Path(lib.H) / "agy-settings.json"
AGY.unlink(missing_ok=True)
AGY_PWD = pathlib.Path(lib.H) / "agy-pwd"
sh(f"rm -rf '{AGY_PWD}'"); AGY_PWD.mkdir()
AGY_BIN = pathlib.Path(lib.H) / "agy-bin"
AGY_BIN.mkdir(exist_ok=True)
(AGY_BIN / "synth-t39-agy").write_text("""#!/bin/sh
printf '%s\\n' "$PWD" > "$T39_AGY_PWD/$(basename "$PWD")"
while [ $# -gt 0 ]; do [ "$1" = --log-file ] && log="$2"; shift; done
[ -n "$log" ] && printf 'I0000 manager.go:443] Initializing CLI store manager for workspace %s\\n' "$PWD" >> "$log"
exec sleep 600
""")
(AGY_BIN / "synth-t39-agy").chmod(0o755)
_st = json.loads((sd / "state.json").read_text())
_st["customAgents"] = [{"id": "custom-agy-gate", "name": "Gate Antigravity",
                        "binary": "synth-t39-agy", "base": "antigravity", "named": True}]
(sd / "state.json").write_text(json.dumps(_st))
ENV = {"SYNTH_ROUTINE_SEED_SECONDS": "25", "CLAUDE_CONFIG_DIR": str(CFG), "SYNTH_AGY_SETTINGS": str(AGY),
       "T39_AGY_PWD": str(AGY_PWD), "PATH": f"{AGY_BIN}:{lib.OPENCODE_PATH}:{os.environ['PATH']}"}
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


def tree_now():
    return ctl("automation.tree")["workspaces"][0]


def archived():
    return [a["branch"] for a in ctl("automation.archiveStatus").get("archived", [])]


def park(row_id):
    """Rest the sidebar cursor on `row_id` without opening anything — ↓/↑ as the keys do."""
    for _ in range(4):
        n = ctl("automation.nav")
        rows = [r.lower() for r in n.get("navRows", [])]
        cur, t = n.get("navCursor", "").lower(), row_id.lower()
        if cur == t: return True
        if t not in rows: return False
        ctl("automation.navMove", delta=rows.index(t) - (rows.index(cur) if cur in rows else 0))
    return ctl("automation.nav").get("navCursor", "").lower() == row_id.lower()


def midnight(days):
    d = datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0) + datetime.timedelta(days=days)
    return d.timestamp()


def nxt(name):
    return (routines().get(name) or {}).get("nextSlot", 0)


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
check("7b. a Once whose time has passed is refused",
      err(name="x", target="fresh", schedule={"kind": "once", "hour": 0, "minute": 0, "date": midnight(-1)})
      == "That time has already passed.")
check("7c. an hour out of range is refused", err(name="x", target="fresh", schedule={"kind": "daily", "hour": 24}) == "The hour has to be 0–23.")
check("7d. a minute out of range is refused", err(name="x", target="fresh", schedule={"kind": "daily", "minute": 60}) == "The minute has to be 0–59.")
check("7e. a weekday out of range is refused",
      err(name="x", target="fresh", schedule={"kind": "weekly", "weekday": 8}) == "The weekday has to be 1–7 (Sunday is 1).")
d0 = ctl("automation.routineCreate", name="Defaults", prompt="Say OK and stop.")
dr = routines().get("Defaults", {})
check("7f. what a caller leaves out comes from the same defaults the editor opens with",
      d0.get("ok") and dr.get("schedule") == "weekdays" and dr.get("scheduleWords") == "Weekdays 09:00"
      and dr.get("target", {}).get("kind") == "fresh" and dr.get("agent") and dr.get("base") == ""
      and f'agent: Synth.AgentID(rawValue: "{dr.get("agent")}")' in str(ctl("automation.routineBoard", action="new").get("view")), (dr, d0))
ctl("automation.routineDelete", id=d0.get("id", ""))
ctl("automation.jump", sessionId=term)

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
check("16b. the branch it cut carries the routine's mark", tree_now()["routineMarks"].get(row and row["branch"]) == "Nightly sweep",
      tree_now()["routineMarks"])
check("16c. and so does the session it spawned", sess and sess[0].get("routineMark") == "Nightly sweep", sess)
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
board = ctl("automation.routineBoard")
check("33. View opens that routine on the board", board.get("open") is True and R2.lower() in board.get("view", "").lower(), board)

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
check("35b. recorded at the look that found it, as the schedule's own (no trigger badge)",
      s and abs(s[0]["firedAt"] - sat.timestamp()) < 1 and s[0]["trigger"] == "schedule"
      and s[0]["slot"] < s[0]["firedAt"] - 86400, s)
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
# Everything after this cuts worktrees nobody should take a turn in: the repo stops being
# trusted, so new worktrees don't inherit it and every agent waits at its trust prompt.
c2 = cfg(); c2["projects"].pop(REPO_REAL, None); CFG_FILE.write_text(json.dumps(c2, indent=2))

# --- Antigravity's folder trust: the same treatment, in its own list ---------------------------
def agy_cfg():
    return json.loads(AGY.read_text())

claude_trusted = trusted_paths()
a0 = {"someOtherKey": {"x": [1, 2.5, None]}, "trustedWorkspaces": ["/elsewhere/trusted-by-hand"]}
AGY.write_text(json.dumps(a0, indent=2))
a0_bytes = AGY.read_bytes()
au = create(name="Agy untrusted", target="fresh", agent="custom-agy-gate")
check("37h1. a custom agent on Antigravity's base can be a routine's agent", au.get("ok"), au)
ctl("automation.routineFire", id=au.get("id", ""), trigger="runNow")
agu = wait(lambda: (runs("Agy untrusted") or [{}])[0].get("outcome") == "failed" and runs("Agy untrusted")[0], 60)
check("37h2. an untrusted repo's Antigravity run stalls and fails, saying so in Antigravity's words",
      agu and agu["reason"] == "repo isn't trusted in Antigravity yet, so it stopped at the trust prompt. "
      "Open Antigravity in repo once, accept the prompt, then run it again.", agu and agu["reason"])
check("37h3. and Synth wrote nothing to Antigravity's list", AGY.read_bytes() == a0_bytes, agy_cfg())

a1 = {"someOtherKey": {"x": [1, 2.5, None]}, "theme": "tokyo night",
      "trustedWorkspaces": ["/elsewhere/trusted-by-hand", REPO_REAL]}
AGY.write_text(json.dumps(a1, indent=2))
at = create(name="Agy trusted", target="fresh", agent="custom-agy-gate")["id"]
ctl("automation.routineFire", id=at, trigger="runNow")
agt = wait(lambda: (runs("Agy trusted") or [{}])[0].get("worktreePath") and runs("Agy trusted")[0], 30) or {}
wt_agy = agt.get("worktreePath", "")
seen = wait(lambda: (AGY_PWD / os.path.basename(wt_agy)).exists() and (AGY_PWD / os.path.basename(wt_agy)).read_text().strip(), 30) if wt_agy else None
a2 = agy_cfg()
added = a2.get("trustedWorkspaces", [])[len(a1["trustedWorkspaces"]):]
check("37h4. a trusted repo's new worktree is appended to Antigravity's list",
      a2.get("trustedWorkspaces", [])[:2] == a1["trustedWorkspaces"] and bool(added)
      and all(os.path.realpath(x) == os.path.realpath(wt_agy) for x in added), (a2.get("trustedWorkspaces"), wt_agy))
check("37h5. in the exact spelling the agent's working directory had", bool(seen) and seen in added, (seen, added))
check("37h6. every other key is carried through as it was",
      {k: v for k, v in a2.items() if k != "trustedWorkspaces"} == {k: v for k, v in a1.items() if k != "trustedWorkspaces"}, a2)
check("37h7. and Claude's config was left alone by an Antigravity run", trusted_paths() == claude_trusted,
      (claude_trusted, trusted_paths()))
for rid in (au.get("id", ""), at):
    ctl("automation.routineDelete", id=rid)
AGY.write_text(json.dumps(a0, indent=2))

# --- Base shown = base used ------------------------------------------------------------------------
ctl("automation.routineBoard", action="open", id=R1)
eb = wait(lambda: routines().get("Nightly sweep", {}).get("effectiveBase"), 15)
check("37i. the base the editor shows is the one the run cut from", eb == base, (eb, base))

# --- A Once is used up by the run that fires it, and only by that ---------------------------------
ro = create(name="Once later", target="fresh", schedule={"kind": "once", "hour": 10, "minute": 0, "date": midnight(1)})
ro_id = ro.get("id", "")
check("37j. a Once in the future is owed", ro.get("ok") and nxt("Once later") > time.time(), ro)
up = ctl("automation.routineUpdate", id=ro_id, schedule={"date": midnight(-1)})
check("37k. an update can't move a Once into the past", up.get("error") == "That time has already passed."
      and nxt("Once later") > time.time(), up)
up = ctl("automation.routineUpdate", id=ro_id, name="")
check("37l. nor save an empty name", up.get("error") == "A routine needs a name." and "Once later" in routines(), up)
up = ctl("automation.routineUpdate", id=ro_id, schedule={"hour": 25})
check("37m. nor an hour out of range", up.get("error") == "The hour has to be 0–23.", up)
ctl("automation.routineFire", id=ro_id, trigger="test")
check("37n. a Test leaves a Once owed", nxt("Once later") > time.time(), nxt("Once later"))
ctl("automation.routineFire", id=ro_id, trigger="runNow")
check("37o. Run now uses it up: it reads Ran and is owed nothing", nxt("Once later") == 0, nxt("Once later"))
up = ctl("automation.routineUpdate", id=ro_id, prompt="Say OK twice and stop.")
check("37p. a spent Once still takes edits that leave its time alone", up.get("ok"), up)
rm = create(name="Once missed", target="fresh", schedule={"kind": "once", "hour": 0, "minute": 5, "date": midnight(1)})
ctl("automation.routineTick", id=rm["id"], now=midnight(4))
m = runs("Once missed")
check("37q. a Once missed by days still runs on the next look", len(m) == 1 and m[0]["trigger"] == "catchUp"
      and m[0]["outcome"] in ("started", "failed") and nxt("Once missed") == 0, m)

# --- A run on an existing branch marks its session, never the branch ------------------------------
ctl("automation.jump", sessionId=term)
before = nav()
rx = create(name="On base", target="existing", branch=base)["id"]
ctl("automation.routineFire", id=rx, trigger="runNow")
xr = wait(lambda: (runs("On base") or [{}])[0].get("sessionId") and runs("On base")[0], 30)
xs = next((x for x in ctl.sessions() if xr and x["sessionId"] == xr["sessionId"]), {})
check("37r. the session it spawned carries the mark", xs.get("routineMark") == "On base", xs)
check("37s. the existing branch never does", base not in tree_now()["routineMarks"], tree_now()["routineMarks"])
check("37t. and the pane didn't move for a session on its own branch", nav() == before, (before, nav()))

# --- A run never closes a session someone is holding ----------------------------------------------
same = create(name="Same run", target="same")["id"]
ctl("automation.routineFire", id=same, trigger="runNow")
s1 = wait(lambda: (runs("Same run") or [{}])[0].get("outcome") == "failed" and runs("Same run")[0], 60) or {}
wt_same, S1 = s1.get("worktreePath"), s1.get("sessionId", "")
ctl("automation.jump", worktree=wt_same, sessionId=S1)   # read it
ctl("automation.jump", sessionId=term)
# The run's row in the tree: its session when the group is open, else the branch row that stands
# for it (tabs mode never shows session rows at all).
S1row = S1 if S1.lower() in [r.lower() for r in ctl("automation.nav").get("navRows", [])] \
    else ctl("automation.nav", worktree=wt_same).get("branchId", "")
check("37u. the cursor rests on the last run's row", park(S1row), ctl("automation.nav").get("navCursor"))
before = nav()
ctl("automation.routineFire", id=same, trigger="runNow")
wait(lambda: len(runs("Same run")) == 2 and runs("Same run")[0].get("sessionId"), 30)
check("37v. the next run leaves the session under the cursor where it is",
      any(x["sessionId"] == S1 for x in ctl.sessions(wt_same)) and nav() == before, (before, nav()))
wait(lambda: runs("Same run")[0].get("outcome") == "failed", 60)
ctl("automation.jump", sessionId=term)
ctl("automation.routineFire", id=same, trigger="runNow")
wait(lambda: len(runs("Same run")) == 3 and runs("Same run")[0].get("sessionId"), 30)
check("37w. (control) with nobody holding it, a settled session does go",
      not any(x["sessionId"] == S1 for x in ctl.sessions(wt_same)), ctl.sessions(wt_same))

# --- A new Test never takes a last Test someone is holding ----------------------------------------
hold = create(name="Holder", target="fresh")["id"]
ctl("automation.routineFire", id=hold, trigger="test")
t1 = wait(lambda: (runs("Holder") or [{}])[0].get("sessionId") and runs("Holder")[0], 30) or {}
T1wt, T1 = t1.get("worktreePath"), t1.get("sessionId", "")
T1row = ctl("automation.nav", worktree=T1wt).get("branchId", "")
ctl("automation.jump", sessionId=term)
check("37x. the cursor rests on the last Test's row", park(T1row), ctl("automation.nav").get("navCursor"))
before = nav()
ctl("automation.routineFire", id=hold, trigger="test")
t2 = wait(lambda: len(runs("Holder")) == 2 and runs("Holder")[0].get("sessionId") and runs("Holder")[0], 30) or {}
check("37y. the held Test stays; the new one is cut beside it under a dated name",
      "routine/holder-test" in tree_now()["branches"] and t2.get("branch", "").startswith("routine/holder-test-")
      and t2.get("worktreePath"), (tree_now()["branches"], t2.get("branch")))
check("37z. and the cursor and the pane stayed put", nav() == before, (before, nav()))
ctl("automation.jump", worktree=T1wt, sessionId=T1)
before = nav()
check("37za. the last Test's session is the open one", before[0] == T1.lower(), before)
ctl("automation.routineFire", id=hold, trigger="test")
t3 = wait(lambda: len(runs("Holder")) == 3 and runs("Holder")[0].get("sessionId") and runs("Holder")[0], 30) or {}
check("37zb. an open last Test stays open, and the new one lands beside it",
      nav() == before and "routine/holder-test" in tree_now()["branches"]
      and t3.get("branch", "").startswith("routine/holder-test-") and t3.get("branch") != t2.get("branch"),
      (before, nav(), t3.get("branch")))

# --- A Test's worktree archives once its session is closed ----------------------------------------
ctl("automation.requestDelete", worktree=T1wt, sessionId=T1)
ctl("automation.notifDrain")
check("37zc. closing the Test's last session archives its worktree",
      bool(wait(lambda: "routine/holder-test" not in tree_now()["branches"] and "routine/holder-test" in archived(), 10)),
      (tree_now()["branches"], archived()))
for rid in (ro_id, rm["id"], rx, same, hold):
    ctl("automation.routineDelete", id=rid)

# --- Delete: the routine and its queue go; its branches and the busy run stay -------------------
fresh_branch = runs("Nightly sweep")[-1]["branch"]
ctl("automation.routineDelete", id=R1)
check("37. delete removes the routine and its queued run", "Nightly sweep" not in routines())
check("38. its branches stay", fresh_branch in git_branches()
      and fresh_branch in ctl("automation.tree")["workspaces"][0]["branches"], fresh_branch)
check("38b. with the mark it put on them", tree_now()["routineMarks"].get(fresh_branch) == "Nightly sweep", tree_now()["routineMarks"])
check("39. the run it had going carries on", len(ctl.sessions(wt1)) == 1, ctl.sessions(wt1))

# The headless session is a real terminal: opened, the view it booted in moves into the pane.
sid = ctl.sessions(wt1)[0]["sessionId"]
ctl("automation.jump", worktree=wt1, sessionId=sid)
time.sleep(2)
shot2 = f"{lib.H}/t39-opened.png"
ctl("automation.screenshot", path=shot2, window="main")
print(f"  screenshot: {shot2}")
check("39b. opening the run's session shows it", nav()[0] == sid.lower(), nav())

# A quit mid-start, with a run waiting behind it: one waiting on a fresh slot, one on a slot
# already older than its window by the time Synth is back.
rq = create(name="Relaunch queue", target="fresh")["id"]
rs2 = create(name="Relaunch stale", target="fresh")["id"]
for rid, slot in ((rq, time.time() - 60), (rs2, time.time() - 3 * 86400)):
    ctl("automation.routineFire", id=rid, trigger="runNow")
    ctl("automation.routineFire", id=rid, trigger="schedule", slot=slot)
check("39c. each has a start in flight and one run queued behind it",
      all([x["outcome"] for x in runs(n)] == ["queued", "started"] and runs(n)[1]["pending"]
          for n in ("Relaunch queue", "Relaunch stale")),
      {n: [(x["outcome"], x["pending"]) for x in runs(n)] for n in ("Relaunch queue", "Relaunch stale")})
time.sleep(5)   # the autosave cadence
kept = routines()
p.terminate(); p.wait()

p, sock = launch(sd, f"{lib.H}/t39b.log", env_extra=ENV)
ctl = Ctl(sock, repo)
back = routines()
check("40. routines survive a relaunch",
      sorted(back) == sorted(kept) == ["Catch up", "Relaunch queue", "Relaunch stale", "Weekday stale"], sorted(back))
check("41. with their runs, outcomes and slots",
      all([(x["id"], x["outcome"], x["slot"]) for x in back[n]["runs"]]
          == [(x["id"], x["outcome"], x["slot"]) for x in kept[n]["runs"]] for n in ("Catch up", "Weekday stale")),
      {n: [x["outcome"] for x in back[n]["runs"]] for n in back})
# "Catch up" was opened by its card's View (33), which is what marks a failure seen.
check("42. and the seen dot stays seen", back.get("Catch up", {}).get("failureUnseen") is False)
check("43. the marks rode the rows through the relaunch", tree_now()["routineMarks"].get(fresh_branch) == "Nightly sweep",
      tree_now()["routineMarks"])
cut = [x for x in back["Relaunch queue"]["runs"] if x["outcome"] == "failed"]
check("44. a start cut off by the quit is history: it didn't start, and says why, with no dot",
      len(cut) == 1 and cut[0]["reason"] == "Synth quit before the agent took the text."
      and back["Relaunch queue"]["failureUnseen"] is False
      and not any(n["message"] == "Routine didn't start" for n in ctl("automation.notifs").get("notifs", [])),
      back["Relaunch queue"]["runs"])
rq_runs = wait(lambda: runs("Relaunch queue")[0]["trigger"] == "catchUp" and runs("Relaunch queue"), 20) or []
check("45. the waiting run whose slot is still fresh fires as a catch-up",
      len(rq_runs) == 2 and rq_runs[0]["outcome"] == "started" and abs(rq_runs[0]["slot"] - kept["Relaunch queue"]["runs"][0]["slot"]) < 1,
      [(x["trigger"], x["outcome"]) for x in runs("Relaunch queue")])
rs_runs = runs("Relaunch stale")
check("46. the one whose slot went stale is recorded as skipped",
      len(rs_runs) == 2 and rs_runs[0]["outcome"] == "skipped" and rs_runs[0]["skipReason"] == "missedTooOld"
      and rs_runs[0]["trigger"] == "schedule" and rs_runs[1]["reason"] == "Synth quit before the agent took the text.",
      [(x["trigger"], x["outcome"], x["reason"]) for x in rs_runs])

p.terminate()
kill_all()
sys.exit(result())
