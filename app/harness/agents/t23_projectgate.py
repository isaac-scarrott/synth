"""Add-project gate: a project always arrives with a branch, and a dead offer is never made.

Every branch in Synth is a git worktree, so a folder that can't host one can't be a project.
Four different folders used to be accepted anyway and produced the same thing — a project with
no branches, therefore no sessions, whose "New branch" could only ever fail — and the failure
card offered a Retry that ran the identical command and failed identically, forever.

This asserts the two halves of that fix. `automation.addProject` is the folder picker's exact
call once a folder is chosen (the modal panel itself isn't drivable), so the folders a person
actually misclicks can be handed to it: no repo at all, a fresh `git init` with no commit, a
subfolder of a real repo, and one already in the sidebar. Then the Retry cap, driven through a
create that fails deterministically: offered once, withheld the second time the same branch
fails the same way, and given back once that branch materialises.
"""
import pathlib, sys, time, uuid
sys.path.insert(0, ".")
import lib
from lib import *

print("=== T23: add project — a folder that can't host a branch isn't a project ===")
kill_all()
repo = fresh_repo()
sd = seed_state(repo)
p, sock = launch(sd, f"{lib.H}/t23.log")
ctl = Ctl(sock, repo)


def projects():
    return ctl("automation.tree").get("workspaces", [])


def cards():
    return ctl("automation.notifs").get("notifs", [])


def clear():
    for c in cards():
        ctl("automation.notifDismiss", sessionId=c["sessionId"])


def added(name):
    """The project list settling — an add crosses the repo's background git chain."""
    time.sleep(1.5)
    return next((w for w in projects() if w["workspace"] == name), None)


check("1. the fixture project is there to begin with", len(projects()) == 1,
      [w["workspace"] for w in projects()])

# --- A folder with no repository in it ----------------------------------------------------------
clear()
plain = pathlib.Path(lib.H) / "plain-folder"
(plain / "src").mkdir(parents=True, exist_ok=True)
ctl("automation.addProject", path=str(plain))
check("2. a folder with no repo does not become a project", not added("plain-folder"),
      [w["workspace"] for w in projects()])
c = next((c for c in cards() if c["kind"] == "error"), None)
check("3. it says why, naming the folder", c and c["title"] == "plain-folder", c and c["title"])
check("4. and the reason is git, not a git error string",
      c and c["message"] == "Not a git repository", c and c["message"])

# --- A repo with no commits: `git init` and nothing else ----------------------------------------
# The likelier way in than a folder with no repo at all — it's what starting a new project looks
# like. refs/heads is empty, so `worktree add -b x <path> HEAD` dies on "invalid reference: HEAD".
clear()
noc = pathlib.Path(lib.H) / "no-commits"
noc.mkdir(parents=True, exist_ok=True)
sh(f"git -C '{noc}' init -q .")
check("5. it really is a repository", (noc / ".git").exists())
ctl("automation.addProject", path=str(noc))
check("6. a repo with no commits does not become a project", not added("no-commits"),
      [w["workspace"] for w in projects()])
c = next((c for c in cards() if c["kind"] == "error"), None)
check("7. it is told apart from a non-repo", c and c["message"] == "No commits yet",
      c and c["message"])
check("8. and says what would fix it", c and "commit" in c["sub"], c and c["sub"])

# --- A subfolder of a real repo: the pick that used to silently half-work -----------------------
# Accepted before, and worse than a refusal: the row pointed at the repo root while worktreeRoot
# hashed the subpath, so one repo added at two depths became two projects with two worktree roots.
clear()
sub = repo / "app" / "Sources"
sub.mkdir(parents=True, exist_ok=True)
ctl("automation.addProject", path=str(sub))
time.sleep(1.5)
check("9. a subfolder does not become a project of its own", not any(
      w["workspace"] == "Sources" for w in projects()), [w["workspace"] for w in projects()])
check("10. it resolves to the repo it is in, which is already added", len(projects()) == 1,
      [(w["workspace"], w["path"]) for w in projects()])

# --- The same repo twice ------------------------------------------------------------------------
clear()
ctl("automation.addProject", path=str(repo))
time.sleep(1.5)
check("11. re-adding a project shows the one you have, not a second row",
      len(projects()) == 1, [(w["workspace"], w["path"]) for w in projects()])

# --- A real repo still lands, and lands with its default branch ---------------------------------
clear()
other = fresh_repo("second")
ctl("automation.addProject", path=str(other))
w = added("second")
check("12. a repo with a commit becomes a project", bool(w), [x["workspace"] for x in projects()])
check("13. and arrives with its default branch, never branchless",
      w and w["count"] == 1, w and (w["count"], w["branches"]))
# The real on-disk path, not the one that was handed in: the harness scratch dir is reached
# through a symlink (/var → /private/var), and collapsing that is the point. Two spellings of one
# repo would otherwise hash to two `worktreeRoot`s and dedupe as two different projects.
check("14. named for the repo root, symlinks resolved",
      w and w["path"] == str(pathlib.Path(other).resolve()), w and w["path"])

# --- The Retry cap ------------------------------------------------------------------------------
# Branching off a ref that doesn't exist fails in git, on the background chain, after the row is
# already up. A Retry button claims identical input could produce a different output; this one
# can't, and the second identical failure is where the app stops claiming otherwise.
clear()
ctl("automation.createWorktree", branch="doomed-base", base="no-such-ref")
err = wait(lambda: next((c for c in cards() if c["kind"] == "error"), None), 25, 0.3)
check("15. the first failure offers the call again", err and err["action"] == "Retry",
      err and err["action"])
clear()
ctl("automation.createWorktree", branch="doomed-base", base="no-such-ref")
err2 = wait(lambda: next((c for c in cards() if c["kind"] == "error"), None), 25, 0.3)
check("16. the same failure twice stops offering it", err2 and err2["action"] == "",
      err2 and err2["action"])
check("17. it still says what went wrong", bool(err2 and err2["sub"]), err2 and err2["sub"])

# A different failure on the same branch is a different question, so it gets its own offer.
clear()
ctl("automation.createWorktree", branch="doomed-base", base="also-missing")
err3 = wait(lambda: next((c for c in cards() if c["kind"] == "error"), None), 25, 0.3)
check("18. a different reason is asked afresh", err3 and err3["action"] == "Retry",
      err3 and err3["action"])

# And a branch that succeeds has earned its offer back for next time.
clear()
ctl("automation.createWorktree", branch="fine")
ok = wait(lambda: next((b for w in projects() for b in w["branches"] if b == "fine"), None), 25, 0.3)
check("19. a good create still works after all that", bool(ok))

p.terminate()
sys.exit(result())
