"""Scratch terminal gate (⌘⇧T): a real shell that leaves no trace, and the two rules that cost
something to keep.

The feature's whole claim is a negative one — it runs a shell in the branch's worktree and yet is
*not* a Session: no row, no status, no roll-up, nothing persisted. So the assertions that matter
most are absences, and `automation.nav` / `automation.sessions` are where an accidental row would
show up. `automation.scratch` is the only seam that can see the thing itself.

The other two rules both trade convenience for safety, and both are only provable against a shell
that is genuinely busy — so this suite runs a real foreground job through the real zsh preexec
reporter rather than faking the state:

  • Dismissing kills it, so nothing is ever left running that the sidebar doesn't show. Which is
    exactly why closing it mid-job confirms first (ADR-0013) and names what it ends.
  • Esc closes only at an idle prompt. With a job in the foreground Esc belongs to the shell, or
    it isn't a fully fledged terminal — you couldn't leave insert mode in vim.
"""
import sys, time, uuid
sys.path.insert(0, ".")
import lib
from lib import *

print("=== T12: the scratch terminal — a shell that leaves no trace ===")
kill_all()
repo = fresh_repo()
sd = seed_state(repo, sessions=[
    {"id": str(uuid.uuid4()), "kind": "terminal", "title": "dev server", "titleIsCustom": True},
])
p, sock = launch(sd, f"{lib.H}/t12.log")
ctl = Ctl(sock, repo)

ESC, RETURN = 53, 36


def scr(**kw):
    return ctl("automation.scratch", **kw)


def key(code, mods=(), chars=""):
    ctl("automation.key", keyCode=code, mods=list(mods), chars=chars)
    time.sleep(0.4)


def rows():
    return ctl("automation.nav").get("rows", [])


def session_titles():
    return [s["title"] for s in ctl("automation.sessions").get("sessions", [])]


baseline_rows = len(rows())
check("0. nothing is up before it is summoned", scr().get("open") is False)

# --- It exists, in the branch you were standing in ----------------------------------------------
key(17, ("cmd", "shift"), "t")   # ⌘⇧T
s = scr()
check("1. ⌘⇧T summons a scratch terminal", s.get("open") is True)
check("2. it names the branch it runs in", bool(s.get("branch")), s.get("branch"))
check("3. it starts idle — a fresh shell at a prompt", s.get("busy") is False)

# --- It is not a Session ------------------------------------------------------------------------
# The absence is the feature. A row here would mean it had become the thing it exists not to be.
check("4. no sidebar row appears for it", len(rows()) == baseline_rows,
      f"{len(rows())} vs {baseline_rows}")
check("5. and it is in no branch's session list", "scratch" not in session_titles(),
      str(session_titles()))

# --- ⌘⇧T is a pure toggle -----------------------------------------------------------------------
key(17, ("cmd", "shift"), "t")
check("6. ⌘⇧T again dismisses it", scr().get("open") is False)

# --- Esc at an idle prompt closes; every summon is a fresh shell ---------------------------------
key(17, ("cmd", "shift"), "t")
key(ESC)
check("7. Esc at an idle prompt closes it", scr().get("open") is False)

# --- A real foreground job, through the real zsh reporter ---------------------------------------
scr(action="open")
time.sleep(0.6)
scr(action="run", text="sleep 30")
busy = wait(lambda: scr().get("busy") is True, 15, 0.3)
check("8. a foreground job marks it busy", busy is not None)
check("9. and it knows what that job is", scr().get("command") == "sleep 30", scr().get("command"))
# Still no row, even now that something is genuinely running inside it.
check("10. a running job still raises no row", len(rows()) == baseline_rows)

# --- Esc belongs to the shell while a job holds the foreground -----------------------------------
key(ESC)
check("11. Esc while busy does NOT close it — the shell gets it", scr().get("open") is True)
check("12. and it is still running", scr().get("busy") is True)

# --- Closing while busy confirms, and names what it ends (ADR-0013) ------------------------------
key(17, ("cmd", "shift"), "t")
check("13. ⌘⇧T while busy opens the confirm instead of killing", scr().get("confirmOpen") is True)
check("14. and nothing died while it asks", scr().get("open") is True and scr().get("busy") is True)
key(ESC)
check("15. Esc cancels the confirm, leaving the job alone",
      scr().get("confirmOpen") is False and scr().get("busy") is True)
key(13, ("cmd",), "w")   # ⌘W — the same Close, from the other binding
check("16. ⌘W while busy confirms too", scr().get("confirmOpen") is True)
key(RETURN)
check("17. ⏎ confirms, and it goes", scr().get("open") is False)

# --- Killed on dismiss: nothing survives to come back to ----------------------------------------
scr(action="open")
time.sleep(0.6)
scr(action="run", text="export SYNTH_SCRATCH_MARKER=1")
time.sleep(1.5)
scr(action="close")
time.sleep(0.8)
scr(action="open")
time.sleep(1.5)
check("18. every summon is a fresh shell, not the last one resumed",
      scr().get("busy") is False and scr().get("command") == "")

# --- `exit` ends the shell, and the overlay follows it down -------------------------------------
scr(action="run", text="exit")
check("19. `exit` closes it for real", wait(lambda: scr().get("open") is False, 10, 0.3) is not None)

# --- It is discoverable: ⌘? row and ⌘K action ---------------------------------------------------
key(44, ("cmd",), "?")
sheet = ctl("automation.shortcuts")
check("20. ⌘? opens the sheet", sheet.get("open") is True)
check("21. and it lists the binding",
      any("Scratch terminal" in r for r in sheet.get("rows", [])),
      str([r for r in sheet.get("rows", []) if "erminal" in r]))
key(ESC)
check("22. Esc closes the sheet", ctl("automation.shortcuts").get("open") is False)
key(40, ("cmd",), "k")
pal = ctl("automation.palette")
check("23. ⌘K offers it as an action", "Scratch terminal" in pal.get("items", []),
      str(pal.get("items"))[:200])
key(40, ("cmd",), "k")

# --- It is a global surface, so Settings does not gate it ----------------------------------------
# ⌘T/⌘N/⌘W are gated on Settings because they act on a tree you can't see. ⌘⇧T adds no row, so it
# behaves like ⌘K / ⌘? / ⌘⇧F, which all work there too. Pinned because it reads like an omission.
ctl("automation.key", keyCode=43, mods=["cmd"], chars=",")   # ⌘, into Settings
time.sleep(0.5)
key(17, ("cmd", "shift"), "t")
check("24. Settings does not gate it — it is a surface, not a tree action",
      scr().get("open") is True)
key(17, ("cmd", "shift"), "t")
ctl("automation.key", keyCode=53, mods=[], chars="")         # Esc out of Settings
time.sleep(0.5)

# --- Quitting mid-job says so ---------------------------------------------------------------------
# The scratch terminal is in no branch, so `busySessions` cannot see it: without a clause of its
# own, quit would have reported "This closes every session" while killing a running command, and
# Restart would have skipped its confirm entirely.
scr(action="open")
time.sleep(0.6)
scr(action="run", text="sleep 30")
wait(lambda: scr().get("busy") is True, 15, 0.3)
q = ctl("automation.quitPrompt")
check("25. the quit confirm names the job it would kill",
      "sleep 30" in q.get("informative", ""), q.get("informative"))
scr(action="confirm")
time.sleep(0.5)
q = ctl("automation.quitPrompt")
check("26. and says nothing about it once there is nothing running",
      "scratch" not in q.get("informative", "").lower(), q.get("informative"))

# --- The app is unharmed by all of that ----------------------------------------------------------
check("27. the tree is intact afterwards", len(rows()) == baseline_rows)
check("28. and nothing is left standing", scr().get("open") is False)

p.terminate()
sys.exit(result())
