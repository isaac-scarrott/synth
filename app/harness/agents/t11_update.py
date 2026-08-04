"""Update gate: a waiting build says nothing, waits to be found, and Restart still asks first.

This suite used to prove the update card spoke. It now proves the opposite, because the card is
gone: an update is housekeeping, and housekeeping does not interrupt. A staged build raises no
toast when it lands, no toast a day later, and nothing in Notification Center — not even under the
route that sends every other attention card there. The whole first half of the gate is that
silence, asserted as an absence rather than inferred from one.

Silence alone would also describe a build the app forgot about, so the rest is the two pull
surfaces that replaced the card. The sidebar's `Restart to update` foot button is the one this
suite can see headlessly: it joins the keyboard nav run directly above Settings while a build
waits and leaves it again when none does, which is `automation.nav`'s `navRows` — the ordered
row-id list the cursor walks. (Settings → About is the other surface; it is pixels, so
`updateStatus` stands in for the fact it renders.)

Sparkle is not in the loop. `automation.updateStage` runs the same store path the real
`willInstallUpdateOnQuit` runs, with an installer that records the ask instead of relaunching —
otherwise proving Restart works would mean killing the instance under test.

Reaching Restart is now a keyboard drive, not a card click: no verb activates a foot button, so
this posts ⌘0 to take the keyboard back off the terminal, walks the cursor to the bottom of the
nav run and one back up onto the update foot, and presses ↵ — the exact keys a user has. Landing
the cursor is asserted before it is used, so a drive that never arrived reads as its own failure
rather than as a broken Restart.
"""
import sys, time, uuid
sys.path.insert(0, ".")
import lib
from lib import *

print("=== T11: a waiting build — silent, findable, and Restart still asks first ===")
kill_all()
repo = fresh_repo()
sd = seed_state(repo, sessions=[
    {"id": str(uuid.uuid4()), "kind": "terminal", "title": "dev server", "titleIsCustom": True},
])
p, sock = launch(sd, f"{lib.H}/t11.log")
ctl = Ctl(sock, repo)

# The two cursor targets that are not tree rows, addressed by the ids the app pins them to.
SETTINGS_FOOT = "00000000-0000-0000-0000-0000000F0071"
UPDATE_FOOT   = "00000000-0000-0000-0000-0000000F0072"


def cards():
    return ctl("automation.notifs").get("notifs", [])


def nc():
    return ctl("automation.notifs").get("nc", [])


def nav_rows():
    return ctl("automation.nav").get("navRows", [])


def clear():
    for c in cards():
        ctl("automation.notifDismiss", sessionId=c["sessionId"])


def key(code, mods=(), chars=""):
    ctl("automation.key", keyCode=code, mods=list(mods), chars=chars)
    time.sleep(0.15)   # posted events land on the app's own queue, one main-loop turn later


def cursor_to_update_foot():
    """Walk the keyboard cursor onto the update foot, the way a hand would.

    ⌘0 first: a terminal pane holds first responder, and bare j/k are the shell's until the
    sidebar takes the keyboard back. Then j past the end — movement clamps on the last row, the
    Settings foot — and one k up, which is where the update foot has to be if it is there at all.
    """
    key(29, ("cmd",), "0")
    for _ in range(len(nav_rows()) + 1):
        key(38, (), "j")
    key(40, (), "k")
    return wait(lambda: ctl("automation.nav").get("navCursor") == UPDATE_FOOT, 5, 0.2)


def busy_count():
    return len([s for s in ctl.sessions() if s["status"] in ("running", "working")])


check("0. deck route pinned", ctl("automation.notifRoute", route="deck").get("ok"))
clear()
# Read while nothing is staged, and hold it: this is the nav run 5 is a claim about, and there is
# no way back to "no build waiting" once one has been installed.
idle_rows = nav_rows()
nc_before = len(nc())

# --- A staged build says nothing at all ----------------------------------------------------------
ctl("automation.updateStage", version="9.9.9")
time.sleep(3)   # long enough that a card would be standing — an absence needs the chance to fail
check("1. a build landing raises no card at all", cards() == [],
      str([c["message"] for c in cards()]))

# Every other attention card escalates to Notification Center when Synth isn't frontmost. Pinning
# that route must still produce nothing: an update is not news, on any surface.
ctl("automation.notifRoute", route="nc")
ctl("automation.updateStage", version="9.9.9")
time.sleep(3)
check("2. and nothing reaches Notification Center, even under the route that sends other cards there",
      len(nc()) == nc_before and not any("9.9.9" in v for e in nc() for v in e.values())
      and cards() == [],
      f"nc={nc()} deck={[c['message'] for c in cards()]}")
ctl("automation.notifRoute", route="deck")

# --- Silent, but not forgotten -------------------------------------------------------------------
st = ctl("automation.updateStatus")
check("3. the build is still known, and named", st.get("pending") is True and st.get("version") == "9.9.9",
      f'pending={st.get("pending")} version={st.get("version")!r}')

# --- The foot button is the surface: it joins the keyboard run while a build waits ---------------
rows = nav_rows()
check("4. the update foot joins the nav run, directly above Settings and last but one",
      rows[-2:] == [UPDATE_FOOT, SETTINGS_FOOT] and rows.count(UPDATE_FOOT) == 1,
      str(rows[-3:]))
check("5. with no build waiting the run ends at Settings, with no update foot in it",
      idle_rows[-1:] == [SETTINGS_FOOT] and UPDATE_FOOT not in idle_rows,
      str(idle_rows[-2:]))

# --- Restart asks first, but only when there is something to lose -------------------------------
# An agent session starts mid-turn, which is exactly what a restart would kill. One busy session,
# so the note's subject is the sentence quoted below rather than a plural of it.
ctl("automation.newClaude")
wait(lambda: busy_count() == 1, 30, 0.3)
check("6. the keyboard reaches the update foot", bool(cursor_to_update_foot()),
      ctl("automation.nav").get("navCursor"))
key(36, (), "\r")   # ↵ activates the row under the cursor
pal = wait(lambda: ctl("automation.palette").get("open") and ctl("automation.palette"), 10, 0.2)
check("7. Restart with a live turn in flight asks first",
      pal and pal["crumb"] == "Restart Synth?", pal and pal.get("crumb"))
check("8. the restart is the red one — it ends things",
      pal and pal["danger"] == [True, False], pal and pal.get("danger"))
check("9. Cancel is preselected, so a stray ↵ costs nothing",
      pal and pal["items"][pal["activeIndex"]] == "Cancel",
      pal and (pal.get("items"), pal.get("activeIndex")))
# The reason has to end with the way out, or the dialog reads as "restart or miss the update".
check("10. it names what is at stake, and the way out",
      pal and pal["note"] == "1 session is busy — restarting ends what they are doing. "
                             "Leave it and the update installs itself the next time you quit.",
      pal and pal.get("note"))
check("11. asking has not installed anything",
      ctl("automation.updateStatus").get("installRequested") is False)

# Nothing was spent to open this dialog — there is no card any more — so cancelling has only one
# thing left to get wrong: losing the build itself.
ctl("automation.paletteEnter")   # Cancel
check("12. cancelling leaves the build waiting",
      ctl("automation.updateStatus").get("pending") is True)

# --- With nothing to lose, Restart just restarts -------------------------------------------------
# Cancel pops back to the palette's root frame, which owns the keyboard — Esc hands it back before
# the next drive.
key(53)
wait(lambda: ctl("automation.palette").get("open") is False, 5, 0.2)
for s in ctl.sessions():
    if s["kind"] != "terminal":
        ctl("automation.requestDelete", sessionId=s["sessionId"])
ctl("automation.notifDrain")
wait(lambda: busy_count() == 0, 30, 0.3)
clear()
cursor_to_update_foot()
key(36, (), "\r")
check("13. with nothing busy, Restart goes straight to the install",
      wait(lambda: ctl("automation.updateStatus").get("installRequested") is True, 10, 0.2) is not None)
# Nothing is left claiming a build is waiting — About falls back to "Up to date", and a force-quit
# flag left standing by a stub installer would have disarmed the next real ⌘Q.
check("14. the fact goes with it, so nothing is still offering a build",
      ctl("automation.updateStatus").get("pending") is False)
check("15. and the foot button leaves the nav run with it",
      wait(lambda: UPDATE_FOOT not in nav_rows(), 5, 0.2) is not None, str(nav_rows()[-2:]))

p.terminate()
sys.exit(result())
