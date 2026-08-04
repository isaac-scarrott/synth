"""An agent switched off in Settings ▸ Synth ▸ Agent defaults: never offered, never started.

The switch is a machine fact, not part of the durable tree — it rides UserDefaults
(`synth-agents-enabled`, keyed by AgentID), so this gate sets it through the argument domain
and never touches the developer's own preferences.

Two halves, because "off" has to hold on both sides of a spawn:

Part 1 is the offer. Every "New …" surface reads the enabled set, so a machine that only runs
Claude Code must not be shown OpenCode anywhere. Asserted on two surfaces that build their
items from different call sites (the ⌘K root's context actions and a branch frame's session
creates), and with every agent off, where the answer is no agent rows at all — a state the
feature explicitly allows. Part 1 ends on the caller with no user in front of it: an MCP
handoff with nothing left to receive it has to come back as an error, not as an empty worktree
and a brief nobody reads.

Part 2 is the spawn. A template entry for a switched-off agent is SKIPPED, not deleted: the
worktree opens without it, "the one that opens" moves to the first entry that survives, and the
entry is still in the template afterwards, waiting for the switch to come back on.
"""
import sys, os, json, time, uuid; sys.path.insert(0, ".")
from lib import *

print("=== T19: an agent switched off is never offered and never started ===")


def agents_off(*ids):
    """Launch args that switch agents off. NSArgumentDomain parses a plist fragment, so the
    preference arrives exactly as UserDefaults holds it — no write to a real domain, nothing
    to clean up, and a run can never leave the developer's Synth with agents turned off."""
    body = "".join(f"<key>{i}</key><false/>" for i in ids)
    return ["-synth-agents-enabled", f"<dict>{body}</dict>"]


def palette(ctl):
    """The ⌘K root, opened over the control socket rather than by a synthesized ⌘K.

    Every check here reads rows out of a palette frame, so the frame has to be the one this gate
    asked for. A posted key event can't promise that twice over: it resolves against whichever
    window `NSApp.windows` hands back first, and a headless instance is never frontmost. Worse,
    once the palette IS open its search field owns first responder, so any keystroke this machine
    delivers lands in the query and re-filters the rows — a stray `h` turns the root into
    ['Archive', 'Scratch terminal', 'New branch', 'Keyboard shortcuts'], which reads exactly like
    the feature dropping the agent rows. `automation.paletteOpen` opens a fresh root with an empty
    query and answers with the frame in the same round trip, leaving no interval for either to
    drift."""
    return ctl("automation.paletteOpen")


def drill(ctl, label):
    """Arrow onto `label` and press return, and come back with the frame that opened. Cursor-only:
    typing the label would race whatever else reaches the field. Each step clears the query first
    — `palette`'s guard, applied to a palette that is already open — and needs no settle, because
    the palette pushes its next frame on the main actor before the verb answers."""
    fr = ctl("automation.paletteQuery")
    items = fr.get("items", [])
    if label not in items: return dict(fr, items=[], missing=label, offered=items)
    i = items.index(label)
    if i: ctl("automation.paletteMove", delta=i)
    ctl("automation.paletteEnter")
    return ctl("automation.paletteQuery")


def branch_frame(ctl, workspace, branch):
    """The branch's own frame, whichever root this instance opened on.

    The root leads with the context the store is already in, so which rows sit at the top is not
    the gate's to choose: a cursor parked on the project opens a root offering that project, one
    parked nowhere opens the nav groups. Both reach the branch — walk whichever is in front of us
    rather than assuming, and report the trail when neither does, so a navigation miss can never
    read as the feature dropping a row."""
    fr, trail = palette(ctl), []
    for _ in range(3):
        items = fr.get("items", [])
        trail.append(items)
        if branch in items: return drill(ctl, branch)
        step = next((s for s in ("Branches", workspace, "Projects") if s in items), None)
        if step is None: return dict(fr, items=[], missing=branch, offered=trail)
        fr = drill(ctl, step)
    return dict(fr, items=[], missing=branch, offered=trail)


def rows(frame):
    """A frame's rows plus the sentence to print if the check on them fails.

    Rows only count when the frame is the frame under test: one that never opened, or one whose
    query has filtered it, cannot answer "which sessions does Synth offer here?" — so it yields no
    rows and says which of the two happened, rather than failing as though the feature were wrong."""
    if frame.get("missing"):
        return [], f"never reached {frame['missing']!r} — the frame before it offered {frame['offered']}"
    if not frame.get("open"):
        return [], f"the palette is not open — {frame}"
    if frame.get("query"):
        return [], (f"the palette was filtered by {frame['query']!r}, so these are not the frame's "
                    f"own rows — {frame.get('items')}")
    return frame.get("items", []), f"{frame.get('crumb') or 'root'}: {frame.get('items')}"


AGENT_ROWS = ("New Claude Code", "New OpenCode", "New Antigravity")

# --- Part 1: the offer ------------------------------------------------------------------------
kill_all()
repo = fresh_repo()
sd = seed_state(repo)

p, sock = launch(sd, f"{H}/t19a.log")
ctl = Ctl(sock, repo)
items, why = rows(palette(ctl))
check("1. with nothing switched off, ⌘K offers every installed agent",
      "New Claude Code" in items and "New OpenCode" in items, why)
p.terminate(); time.sleep(1)

p, sock = launch(sd, f"{H}/t19b.log", extra_args=agents_off("opencode"))
ctl = Ctl(sock, repo)
items, why = rows(palette(ctl))
check("2. opencode off: ⌘K drops it and keeps the rest",
      "New OpenCode" not in items and "New Claude Code" in items, why)
# A second surface, built from a different call site: the branch's own frame.
bitems, bwhy = rows(branch_frame(ctl, os.path.basename(repo), sh(f"git -C {repo} branch --show-current")))
check("3. the branch frame's session creates drop it too",
      "New OpenCode" not in bitems and "New Claude Code" in bitems, bwhy)
p.terminate(); time.sleep(1)

p, sock = launch(sd, f"{H}/t19c.log",
                 extra_args=agents_off("claudeCode", "opencode", "antigravity"))
ctl = Ctl(sock, repo)
items, why = rows(palette(ctl))
check("4. every agent off is allowed: no agent rows, terminal and browser stay",
      not any(a in items for a in AGENT_ROWS)
      and "New terminal" in items and "New browser" in items, why)

# The one caller with no user in front of it. A handoff is a brief written for someone to
# receive; with nobody left to receive it, the MCP call must fail rather than approve into an
# empty worktree and drop the brief on the floor.
r = ctl("app.worktreeCreate", branch="feat/handoff-nowhere", handoff="pick this up: finish the parser")
check("5. an MCP handoff create is refused, not silently emptied",
      r.get("ok") is False and "switched off" in r.get("error", ""), r)
check("6. and it created nothing",
      "feat/handoff-nowhere" not in sh(f"git -C {repo} branch --format='%(refname:short)'"), None)
p.terminate(); time.sleep(1)

# --- Part 2: the spawn ------------------------------------------------------------------------
# A template whose first two entries can't run here: one names an agent this machine hasn't got
# (what a state.json carried over from a machine that had one looks like — enabled has to mean
# enabled AND installed, or the worktree opens a dead row marked "working" that no switch in
# Settings can turn off), the other names the switched-off one. Both are wish list entries, not
# sessions: skipped on the way out, left in the template.
tpl = [
    {"id": str(uuid.uuid4()), "kind": "someoneElsesAgent", "name": "not on this machine"},
    {"id": str(uuid.uuid4()), "kind": "opencode", "name": "opencode"},
    {"id": str(uuid.uuid4()), "kind": "claudeCode", "name": "claude"},
    {"id": str(uuid.uuid4()), "kind": "terminal", "name": "dev server"},
]
sd = seed_state(repo, template=tpl)
# `claude --help` exits in a beat: this gate is about which rows exist and which one opens,
# not about a live turn, and a gate should not leave an interactive agent running.
state = json.loads((sd / "state.json").read_text())
state["globalAgentFlags"] = {"claudeCode": "--help"}
(sd / "state.json").write_text(json.dumps(state))

p, sock = launch(sd, f"{H}/t19d.log", extra_args=agents_off("opencode"))
ctl = Ctl(sock, repo)
r = ctl("automation.createWorktree", branch="feat/skips-the-off-one")
wt = r.get("worktreePath")
rows = wait(lambda: ctl.sessions(worktree=wt) or None, 60) or []
kinds = [x["kind"] for x in rows]
check("7. the switched-off entry spawns no session", "opencode" not in kinds, kinds)
check("8. neither does one for an agent this machine hasn't got",
      "someoneElsesAgent" not in kinds, kinds)
check("9. every other entry still does, in template order", kinds == ["claudeCode", "terminal"], kinds)
opener = ctl("automation.nav", worktree=wt).get("openSessionId")
check("10. 'the one that opens' moves to the first entry that survived",
      bool(rows) and opener == rows[0]["sessionId"] and rows[0]["kind"] == "claudeCode",
      [opener, rows[0] if rows else None])

# Skipped, not deleted — flipping opencode back on has to restore the row without retyping it.
saved = json.loads((sd / "state.json").read_text()).get("globalSessionTemplate", [])
check("11. the skipped entries are still in the template",
      [e["kind"] for e in saved] == ["someoneElsesAgent", "opencode", "claudeCode", "terminal"],
      [e["kind"] for e in saved])

p.terminate()
sys.exit(result())
