"""Archive + background clean-up gate.

Builds a sandbox repo with a real `origin` (a bare clone on disk, so `origin/HEAD` means
something) and one worktree per shape, then drives a real Synth over the control socket with
the wait compressed to zero.

The rule under test is short. A merged branch is archived for you; an archived worktree's
folder is deleted after the wait, or sooner once the archive is over a cap, whatever is inside
it; a restore after that re-cuts the checkout from the branch; and a merged branch the remote
has dropped ends with its ref. What is NOT here is any reading of the folder's contents — the
suite archives a dirty worktree and one with an unpushed commit and asserts both folders go,
because that was the change.
"""
import json, os, pathlib, sys, time

import lib
from lib import check, result, sh, wait, kill_all, launch, Ctl, support_dir

H = pathlib.Path(lib.H)
APP_SUPPORT = support_dir()


import archive_fixture as fx
from archive_fixture import git


def seed(repo, made):
    sd = H / "state"
    sh(f"rm -rf '{sd}'")
    sd.mkdir(parents=True)
    (sd / "state.json").write_text(json.dumps(fx.state(repo, made)))
    return sd


def sweep_until(ctl, done, ticks=8, secs=10):
    """Drive forced ticks until `done`.

    One `archiveSweep` is a request, not a tick: `sweepInFlight` coalesces a second away while
    the first is still running, and with the clock compressed the suite asks far faster than a
    real one ever would. Asserting on a fixed number of calls made these checks depend on how
    long a tick happened to take.
    """
    for _ in range(ticks):
        ctl("automation.archiveSweep")
        for _ in range(secs):
            time.sleep(1)
            if done(): return True
    return done()


def status_map(ctl):
    rows = ctl("automation.archiveStatus").get("archived", [])
    return {r["branch"]: r for r in rows}


def on_disk(ctl, name):
    return status_map(ctl).get(name, {}).get("onDisk")


def tree_branches(ctl):
    """Every branch row the sidebar draws, across workspaces."""
    return [b for ws in ctl("automation.tree").get("workspaces", []) for b in ws["branches"]]


def archive_by_hand(ctl, name):
    """The gesture, and the undo window elapsing. Headless, the drain is held (the card would
    still be there for a returning user), so say so explicitly rather than sleeping forever."""
    ctl("automation.archiveBranch", branch=name)
    ctl("automation.notifDrain")
    return wait(lambda: name in status_map(ctl), secs=20)


def enter_row(ctl, label):
    """Move the cursor onto `label` and press it, having checked it is the row under the cursor.

    Move and Enter are two round trips, and the rows can change between them — this palette
    fills its branch list off the main thread, so a frame re-sorts under a cursor that was
    aimed at the old order. Pressing anyway runs whatever moved into that slot, and most rows
    close the palette on the way out, so the miss surfaces three checks later as a picker that
    dropped a row rather than as a navigation that went astray. Read the frame back and only
    commit once the cursor is where it was aimed."""
    for _ in range(6):
        fr = ctl("automation.palette")
        items = fr.get("items") or []
        if label not in items: return fr
        delta = items.index(label) - (fr.get("activeIndex") or 0)
        if delta: ctl("automation.paletteMove", delta=delta)
        landed = ctl("automation.palette")
        on = (landed.get("items") or [])
        if on and on[landed.get("activeIndex") or 0] == label:
            ctl("automation.paletteEnter")
            return ctl("automation.palette")
    return dict(fr, items=[], missing=f"cursor never settled on {label}")


def new_branch_frame(ctl, query):
    """⌘K's New-branch picker, filtered to `query`, with the cursor on the first row.

    Navigated by cursor over the socket rather than by typing: once the palette is open its
    field owns first responder, so a keystroke this machine delivers lands in the query and
    silently re-filters — a navigation miss would read as the picker dropping the row. The
    root leads with whatever context the store is in, so walk to the project when the verb
    isn't already on offer instead of assuming which root opened."""
    fr, trail = ctl("automation.paletteOpen"), []
    for _ in range(3):
        items = fr.get("items", [])
        trail.append(items)
        if "New branch" in items:
            enter_row(ctl, "New branch")
            return ctl("automation.paletteQuery", query=query)
        step = next((s for s in ("demo-project", "Projects") if s in items), None)
        if step is None: return dict(fr, items=[], missing="New branch", offered=trail)
        enter_row(ctl, step)
        fr = ctl("automation.paletteQuery")
    return dict(fr, items=[], missing="New branch", offered=trail)


def worktree_entry(repo, path):
    porcelain = git(repo, "worktree list --porcelain")
    return next((blk for blk in porcelain.split("\n\n") if str(path) in blk), "")


def main():
    kill_all()
    repo, made = fx.build(H / "sandbox", APP_SUPPORT)
    state = seed(repo, made)

    os.environ.update({
        "SYNTH_ARCHIVE_GRACE_SECONDS": "0",     # no waiting a week
        "SYNTH_ARCHIVE_TICK_SECONDS": "3600",   # only forced ticks, so the test drives the clock
    })

    log = "/tmp/t9_archive.log"
    p, sock = launch(state, log, extra_args=[
        "-synth-archive-sweep", "<true/>",
        "-synth-archive-grace-days", "<integer>7</integer>",
        "-synth-archive-max-count", "<integer>0</integer>",
        "-synth-archive-max-gb", "<integer>0</integer>",
    ])
    ctl = Ctl(sock, repo)
    try:
        # --- the finished-row pass ------------------------------------------------------
        check("every scenario row starts in the tree",
              all(name in tree_branches(ctl) for name in made), str(tree_branches(ctl)))
        # A folder that goes mid-session — by hand, or another tool's cleanup — leaves its row
        # live with nothing behind it until the next launch drops it. (At launch, restore
        # already leaves such a row out, which is why this is done here and not in the fixture.)
        sh(f"rm -rf '{made['merged-gone']}'")
        sh(f"rm -rf '{made['remote-gone']}'")
        git(repo, "worktree prune")

        finished = {"merged-clean", "has-edits", "has-untracked", "merged-gone", "ref-gone"}
        # Rows that end during this suite: their branch goes, so they go. Every later count of
        # the Archived list has to leave room for them.
        retired = {"remote-gone", "ref-gone"}
        kept = {"not-pushed", "never-merged"}

        # One tick, not a loop: the pass archives every merged row in a single pass, and the
        # folders must NOT go on the same tick — archived rows are judged before live rows are
        # archived, which is what gives the user a tick's worth of Archived list to object to.
        ctl("automation.archiveSweep")
        auto = wait(lambda: finished <= set(status_map(ctl)), secs=30)
        check("merged rows are archived for the user, whatever is in the folder", bool(auto),
              str(sorted(status_map(ctl))))
        same_tick = {n: on_disk(ctl, n) for n in ("merged-clean", "has-edits", "has-untracked")}
        check("a row archived this tick keeps its folder until the next one",
              set(same_tick.values()) == {"true"}, str(same_tick))
        check("the folder-less merged row is archived on the branch's evidence alone",
              "merged-gone" in status_map(ctl), str(sorted(status_map(ctl))))
        check("archived-for-you rows leave the tree",
              not finished & set(tree_branches(ctl)), str(tree_branches(ctl)))
        check("unmerged rows stay in the tree", kept <= set(tree_branches(ctl)),
              str(tree_branches(ctl)))

        # --- the clean-up ---------------------------------------------------------------
        # The wait is zero, so every archived folder is due on the next tick. Uncommitted edits
        # and untracked files are not a reason to keep one: archived is the whole decision.
        cleanable = {"merged-clean", "has-edits", "has-untracked"}
        gone = sweep_until(ctl, lambda: all(on_disk(ctl, n) == "false" for n in cleanable))
        check("archived folders are deleted once the wait has run", bool(gone),
              str({n: on_disk(ctl, n) for n in cleanable}))
        check("the dirty worktree's folder really went", not made["has-edits"].exists())
        check("git no longer lists the cleaned worktree",
              not worktree_entry(repo, made["merged-clean"]),
              worktree_entry(repo, made["merged-clean"]))
        check("cleaned rows stay in the Archived list, restorable",
              cleanable <= set(status_map(ctl)), str(sorted(status_map(ctl))))
        check("a cleaned row reads as such",
              all(status_map(ctl)[n]["countdown"] == "" for n in cleanable),
              str({n: status_map(ctl)[n]["countdown"] for n in cleanable}))
        check("the list itself says only when",
              all(r["status"].startswith("archived ") for r in status_map(ctl).values()),
              str({k: v["status"] for k, v in status_map(ctl).items()})[:200])

        # --- retiring the ref -----------------------------------------------------------
        # The far end of the archive path: a row archived and cleaned up used to leave its
        # branch behind for good. The ref goes only when the remote has already dropped it —
        # and because a row whose branch has gone can no longer be restored, the row goes too.
        ended = sweep_until(ctl, lambda: "remote-gone" not in status_map(ctl)
                            and "remote-gone" not in tree_branches(ctl))
        check("a merged branch the remote has dropped is retired", bool(ended),
              f"archived={'remote-gone' in status_map(ctl)} tree={'remote-gone' in tree_branches(ctl)}")
        check("and its ref is really deleted",
              not git(repo, "branch --list remote-gone").strip(),
              git(repo, "branch --list remote-gone"))
        # The negative, and the reason the remote is the gate rather than "merged" alone: same
        # shape in every other respect, but origin still lists it.
        check("a merged branch the remote still lists keeps its ref",
              git(repo, "branch --list merged-gone").strip().endswith("merged-gone"),
              git(repo, "branch --list merged-gone"))
        check("and keeps its row in the Archived list",
              "merged-gone" in status_map(ctl), str(sorted(status_map(ctl))))

        # The other ending: a branch removed outside Synth entirely. There is no ref to delete,
        # and a row that can no longer be restored is not a row.
        check("the orphan-to-be starts archived", "ref-gone" in status_map(ctl))
        wait(lambda: on_disk(ctl, "ref-gone") == "false", secs=30)
        git(repo, "worktree prune")
        git(repo, "branch -D ref-gone")
        check("the branch really went", not git(repo, "branch --list ref-gone").strip(),
              git(repo, "branch --list ref-gone"))
        dropped = sweep_until(ctl, lambda: "ref-gone" not in status_map(ctl))
        check("a row whose branch is already gone is dropped", bool(dropped),
              str(sorted(status_map(ctl))))

        # --- undo semantics -------------------------------------------------------------
        # archivedAt is stamped on COMMIT, not on the gesture: the 8s window must change
        # nothing. If this regresses, undo puts a row back that the archive filter then hides,
        # and the row is unreachable except through ⌘K. On a row the pass above can't take,
        # so nothing but the gesture is what moves it.
        check("the row starts in the tree", "not-pushed" in tree_branches(ctl))
        first = ctl("automation.archiveBranch", branch="not-pushed")
        check("archiveBranch verb finds the row", first.get("ok") is True, str(first))
        immediately = status_map(ctl)
        check("archive is not committed during the undo window",
              "not-pushed" not in immediately, f"saw {list(immediately)}")
        ctl("automation.notifDrain")
        landed = wait(lambda: "not-pushed" in status_map(ctl), secs=20)
        check("archive lands once the undo window drains", bool(landed))
        # The commit puts the row back in `branches` so the Archived list can reach it. It must
        # not put it back on screen: the sidebar drew straight from `branches`, so archiving a
        # row made it vanish for the length of the undo window and then reappear.
        check("the archived row stays out of the tree once committed",
              "not-pushed" not in tree_branches(ctl), str(tree_branches(ctl)))

        # --- an unpushed commit survives its folder --------------------------------------
        # The folder goes like any other archived folder. The commit does not go with it: it
        # is on the branch ref, and the ref is only ever retired once the remote has it.
        gone = sweep_until(ctl, lambda: on_disk(ctl, "not-pushed") == "false")
        check("an archived worktree with an unpushed commit still loses its folder", bool(gone),
              str(status_map(ctl).get("not-pushed")))
        check("its branch ref survives",
              git(repo, "branch --list not-pushed").strip().endswith("not-pushed"),
              git(repo, "branch --list not-pushed"))
        check("and the unpushed commit is still on it",
              git(repo, "log -1 --format=%s not-pushed") == "never pushed anywhere",
              git(repo, "log -1 --format=%s not-pushed"))

        # --- restore after the folder is gone -------------------------------------------
        # Restore is the only route back to an archived row — hidden from the tree, its name
        # taken in the picker — so it has to cut the checkout again rather than decline.
        recut = made["not-pushed"]
        again = ctl("automation.archiveRestore", branch="not-pushed")
        check("restore reports success with no folder to move back",
              again.get("ok") is True, str(again))
        check("the row comes back into the tree",
              bool(wait(lambda: "not-pushed" in tree_branches(ctl), secs=30)),
              str(tree_branches(ctl)))
        check("the checkout is cut again at its old path",
              bool(wait(lambda: recut.exists(), secs=30)),
              str(list(recut.parent.iterdir())[:12]))
        check("the re-cut worktree is a real checkout of the branch",
              git(recut, "rev-parse --abbrev-ref HEAD") == "not-pushed",
              git(recut, "rev-parse --abbrev-ref HEAD"))
        check("with the unpushed commit checked out",
              (recut / "local.txt").exists(), str(list(recut.iterdir())[:12]))
        entry = worktree_entry(repo, recut)
        check("the re-cut worktree is registered, with nothing stale left behind",
              bool(entry) and "prunable" not in entry, entry)

        # --- the New-branch picker offers archived rows ----------------------------------
        # An archived row is out of the tree but its name is still taken, so a picker that
        # filtered on every row — not just the live ones — made the branch unreachable by
        # either route: absent from the sidebar, and absent from the one frame that adds it.
        check("the spike is archived by hand", bool(archive_by_hand(ctl, "never-merged")))
        frame = new_branch_frame(ctl, "never-merged")
        # The picker reads git off the main thread, so the frame opens with the fallback row
        # alone and fills when the branch list lands. Re-ask rather than assert on the first.
        wait(lambda: "never-merged" in ctl("automation.palette").get("items", []), secs=20)
        frame = ctl("automation.paletteQuery", query="never-merged")
        check("the New-branch picker offers an archived branch",
              "never-merged" in frame.get("items", []),
              f"crumb={frame.get('crumb')!r} items={frame.get('items')} {frame.get('missing', '')}")
        check("the archived row is offered as a restore, not a second create",
              frame.get("items", []).count("never-merged") == 1
              and not frame.get("note"),
              f"items={frame.get('items')} note={frame.get('note')!r}")
        if "never-merged" in frame.get("items", []):
            enter_row(ctl, "never-merged")
            check("picking it puts the row back in the tree",
                  bool(wait(lambda: "never-merged" in tree_branches(ctl), secs=15)),
                  str(tree_branches(ctl)))
            check("and takes it out of the Archived list",
                  "never-merged" not in status_map(ctl), str(sorted(status_map(ctl))))

        # --- the caps -------------------------------------------------------------------
        # A wait nothing will run out, and a count cap of one: the older of two archived
        # folders goes before its wait, the newer keeps counting down. Relaunched, because
        # the cap is a preference and the wait an environment clock.
        os.environ["SYNTH_ARCHIVE_GRACE_SECONDS"] = "999999"
        kill_all()
        p, sock = launch(state, log + ".2", extra_args=[
            "-synth-archive-sweep", "<true/>",
            "-synth-archive-max-count", "<integer>1</integer>",
            "-synth-archive-max-gb", "<integer>0</integer>",
        ])
        ctl = Ctl(sock, repo)
        wait(lambda: "not-pushed" in tree_branches(ctl), secs=30)
        check("the older row is archived first", bool(archive_by_hand(ctl, "not-pushed")))
        time.sleep(1.5)   # so the two archivedAt stamps order unambiguously
        check("then the newer", bool(archive_by_hand(ctl, "never-merged")))
        before = {n: on_disk(ctl, n) for n in ("not-pushed", "never-merged")}
        check("both keep their folders inside the wait", set(before.values()) == {"true"}, str(before))
        capped = sweep_until(ctl, lambda: on_disk(ctl, "not-pushed") == "false", ticks=3)
        check("over the count cap, the oldest folder goes before its wait", bool(capped),
              str(status_map(ctl).get("not-pushed")))
        check("the newest stays, counting down", on_disk(ctl, "never-merged") == "true",
              str(status_map(ctl).get("never-merged")))
        left = status_map(ctl).get("never-merged", {}).get("countdown", "")
        check("and says how long it has", left.endswith("days left"), repr(left))

    finally:
        kill_all()
    return result()


if __name__ == "__main__":
    sys.exit(main())
