"""Where a close leaves you: the neighbour in the same branch, and nowhere else.

The rule this pins replaces the MRU view stack (016), which popped to the last session you had
*viewed* — across a branch or workspace boundary if that is where it lived. Recency lives nowhere
on screen, so two identical-looking closes landed in different repos depending on browsing done
ten minutes earlier. Now a close hands off to a row you can already see:

  - the session below it in its own branch, else the one above,
  - and when the branch has nothing left, the empty pane — never a jump out of the branch,
  - with the cursor following the same rule, so a second ⌘W can never find a whole branch to
    archive where a session used to be.

The trap the fixture is built around: `side/one` is viewed FIRST and never closed, so it is the
top of any MRU stack throughout. Every check below would pass a stack-popping build if the
sessions were all in one branch — the second branch is the whole point.

Driven through `automation.requestDelete`, the exact call `d`, ⌘W, the kebab and ⌘K all make.
"""
import sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
from lib import *  # noqa: F403
import lib

print("=== T22: a close hands off to its neighbour, inside its own branch ===")
kill_all()
repo = fresh_repo()


def term(title):
    return {"id": str(uuid.uuid4()), "kind": "terminal", "title": title, "titleIsCustom": True}


main = [term("alpha"), term("bravo"), term("charlie")]
side = [term("solo"), term("solo-two")]
sd = seed_state(repo, sessions=main, extra_branches=[{"name": "side", "sessions": side}])
p, sock = launch(sd, f"{lib.H}/t22.log")
ctl = Ctl(sock, repo)
sidewt = os.path.join(lib.WT_ROOT, f"{repo.name}-side")


def nav(worktree=None):
    return ctl("automation.nav", worktree=worktree)


# Seeded ids are not the ids the app runs with, so resolve by title once it is up.
ids = {r["title"]: r["sessionId"] for r in nav().get("rows", []) + nav(sidewt).get("rows", [])}
check("0. all five seeded rows came up", len(ids) == 5, str(sorted(ids)))


def open_id():
    return nav().get("openSessionId", "")


def cursor():
    return nav().get("navCursor", "")


def close(title, worktree=None):
    ctl("automation.requestDelete", sessionId=ids[title], worktree=worktree)
    time.sleep(0.5)


# ---------------------------------------------------------------- 0. the MRU trap is armed
ctl("automation.jump", sessionId=ids["solo"], worktree=sidewt)
time.sleep(0.4)
check("1. solo (other branch) opens — the top of any view stack from here on",
      open_id() == ids["solo"], open_id())

ctl("automation.jump", sessionId=ids["bravo"])
time.sleep(0.4)
check("2. bravo is open", open_id() == ids["bravo"], open_id())

# ------------------------------------------------- 1. closing a row you aren't viewing is inert
close("alpha")
check("3. closing a NON-open row leaves the view where it was",
      open_id() == ids["bravo"], open_id())
check("4. …and leaves the cursor where it was", cursor() == ids["bravo"], cursor())

# ------------------------------------------------- 2. the open row hands off to the one below it
close("bravo")
check("5. closing the open row opens the session BELOW it in the same branch",
      open_id() == ids["charlie"], open_id())
check("6. the cursor follows the successor", cursor() == ids["charlie"], cursor())
check("7. it did not pop to the last-viewed session in the other branch",
      open_id() != ids["solo"], open_id())

# ------------------------------------------------- 3. the last one in a branch stops at empty
branch_id = nav().get("branchId", "")
close("charlie")
check("8. closing the last session in a branch leaves the pane empty", open_id() == "", open_id())
check("9. it did NOT cross into the other branch to avoid the empty pane",
      open_id() != ids["solo"], open_id())
check("10. the cursor rests on the branch row", cursor() == branch_id,
      f"{cursor()} vs branch {branch_id}")
check("11. the layout really is empty",
      ctl("automation.layout").get("panes") == 0, str(ctl("automation.layout").get("panes")))
check("12. solo is still alive in the other branch — nothing else was touched",
      any(r["sessionId"] == ids["solo"] for r in nav(sidewt).get("rows", [])))

# ------------------------------------------------- 4. above, when there is nothing below
ctl("automation.jump", sessionId=ids["solo-two"], worktree=sidewt)
time.sleep(0.4)
check("13. solo-two, the last row in its branch, is open",
      nav(sidewt).get("openSessionId") == ids["solo-two"], nav(sidewt).get("openSessionId", ""))
close("solo-two", worktree=sidewt)
check("14. with nothing below it, the close falls to the row ABOVE",
      nav(sidewt).get("openSessionId") == ids["solo"], nav(sidewt).get("openSessionId", ""))

p.terminate()
sys.exit(result())
