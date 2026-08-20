"""Archive + background clean-up gate.

Builds a sandbox repo with a real `origin` (a bare clone on disk, so `--not --remotes` and
`origin/HEAD` mean something) and one worktree per hazard, then drives a real Synth over the
control socket with every clock compressed to zero.

The point of this suite is the NEGATIVE cases. A sweeper that deletes a merged, clean, fully
pushed worktree is easy; one that refuses to delete the seven folders below is the whole
feature, and each of those refusals is a data-loss bug if it regresses.
"""
import json, os, pathlib, subprocess, sys, time, urllib.parse, uuid

import lib
from lib import check, result, sh, wait, kill_all, launch, Ctl, support_dir

H = pathlib.Path(lib.H)
APP_SUPPORT = support_dir()


import archive_fixture as fx
from archive_fixture import file_url, git, stable_hash


def build_sandbox():
    """The shared scenario set, keyed by this suite's names."""
    repo, made = fx.build(H / "sandbox", APP_SUPPORT)
    return repo, made


def seed(repo, made):
    sd = H / "state"
    sh(f"rm -rf '{sd}'")
    sd.mkdir(parents=True)
    (sd / "state.json").write_text(json.dumps(fx.state(repo, made)))
    return sd


def status_map(ctl):
    rows = ctl("automation.archiveStatus").get("archived", [])
    return {r["branch"]: r for r in rows}


def tree_branches(ctl):
    """Every branch row the sidebar draws, across workspaces."""
    return [b for ws in ctl("automation.tree").get("workspaces", []) for b in ws["branches"]]


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


def main():
    kill_all()
    repo, made = build_sandbox()
    state = seed(repo, made)

    env_clocks = {
        "SYNTH_ARCHIVE_GRACE_SECONDS": "0",     # no waiting a week
        "SYNTH_ARCHIVE_EVAL_GAP_SECONDS": "0",  # but the two-evaluation rule still applies
        "SYNTH_ARCHIVE_TICK_SECONDS": "3600",   # only forced ticks, so the test drives the clock
        "SYNTH_ARCHIVE_HOLD_SECONDS": "999999",  # nothing reaped until we ask
    }
    os.environ.update(env_clocks)

    log = "/tmp/t9_archive.log"
    p, sock = launch(state, log, extra_args=[
        "-synth-archive-sweep", "<true/>",
        "-synth-archive-grace-days", "<integer>7</integer>",
        "-synth-archive-dry-run", "<false/>",
    ])
    ctl = Ctl(sock, repo)
    try:
        # --- the finished-row pass ------------------------------------------------------
        # A merged, clean, pushed row nobody archived is archived for them — the sweeper used
        # to evaluate archived rows only, so such a folder stayed on disk for good. Same
        # two-reading rule as a hold: the first tick banks a reading, the second acts. And the
        # same refusals: a row with anything unrecoverable in its folder stays in the tree.
        check("every scenario row starts in the tree",
              all(name in tree_branches(ctl) for name in made), str(tree_branches(ctl)))
        # A folder that goes mid-session — by hand, or another tool's cleanup — leaves its row
        # live with nothing behind it until the next launch drops it. (At launch, restore
        # already leaves such a row out, which is why this is done here and not in the fixture.)
        sh(f"rm -rf '{made['merged-gone']}'")
        git(repo, "worktree prune")
        ctl("automation.archiveSweep")
        time.sleep(6)
        check("one clean reading archives nothing",
              all(name in tree_branches(ctl) for name in made), str(tree_branches(ctl)))
        ctl("automation.archiveSweep")
        finished = {"merged-clean", "with-stash", "merged-gone"}
        auto = wait(lambda: finished <= set(status_map(ctl)), secs=20)
        check("merged + clean + pushed rows are archived for the user", bool(auto),
              str(sorted(status_map(ctl))))
        check("the folder-less merged row is archived on the branch's evidence alone",
              "merged-gone" in status_map(ctl), str(sorted(status_map(ctl))))
        check("archived-for-you rows leave the tree",
              not finished & set(tree_branches(ctl)), str(tree_branches(ctl)))
        kept_live = [n for n in made if n not in finished and n not in tree_branches(ctl)]
        check("every row with something to lose stays in the tree", not kept_live, str(kept_live))

        # --- undo semantics -------------------------------------------------------------
        # archivedAt is stamped on COMMIT, not on the gesture: the 8s window must change
        # nothing. If this regresses, undo puts a row back that the archive filter then hides,
        # and the row is unreachable except through ⌘K. On a row the pass above can't take,
        # so nothing but the gesture is what moves it.
        check("the row starts in the tree", "has-untracked" in tree_branches(ctl))
        first = ctl("automation.archiveBranch", branch="has-untracked")
        check("archiveBranch verb finds the row", first.get("ok") is True, str(first))
        immediately = status_map(ctl)
        check("archive is not committed during the undo window",
              "has-untracked" not in immediately, f"saw {list(immediately)}")

        # Let the window elapse. Headless, the drain is held (the card would still be there
        # for a returning user), so say so explicitly rather than sleeping forever.
        ctl("automation.notifDrain")
        landed = wait(lambda: "has-untracked" in status_map(ctl), secs=20)
        check("archive lands once the undo window drains", bool(landed))

        # The commit puts the row back in `branches` so the Archived list can reach it. It must
        # not put it back on screen: the sidebar drew straight from `branches`, so archiving a
        # row made it vanish for the length of the undo window and then reappear.
        check("the archived row stays out of the tree once committed",
              "has-untracked" not in tree_branches(ctl), str(tree_branches(ctl)))

        for name in made:
            if name not in finished | {"has-untracked"}:
                ctl("automation.archiveBranch", branch=name)
                ctl("automation.notifDrain")
        wait(lambda: len(status_map(ctl)) == len(made), secs=25)
        rows = status_map(ctl)
        check("every archived row is listed", len(rows) == len(made),
              f"{len(rows)}/{len(made)}: {sorted(rows)}")
        left = [b for b in tree_branches(ctl) if b in made]
        check("archiving every row empties the tree", not left, f"still drawn: {left}")

        # --- the two-evaluation rule ----------------------------------------------------
        ctl("automation.archiveSweep")
        time.sleep(6)
        after_one = status_map(ctl)
        check("first sweep holds nothing (needs a second opinion)",
              all(r["held"] == "false" for r in after_one.values()),
              str({k: v["held"] for k, v in after_one.items() if v["held"] == "true"}))

        # --- the sweep itself -----------------------------------------------------------
        ctl("automation.archiveSweep")
        time.sleep(8)
        rows = status_map(ctl)

        check("merged + clean + pushed worktree is reclaimed",
              rows.get("merged-clean", {}).get("held") == "true",
              rows.get("merged-clean", {}).get("status", "missing"))

        # A stash must not block: it survives the folder, and blocking would make one
        # forgotten stash permanently unsweepable.
        check("a stash does not block the sweep",
              rows.get("with-stash", {}).get("held") == "true",
              rows.get("with-stash", {}).get("status", "missing"))

        # Everything below is a refusal. Each is a data-loss bug if it flips.
        expected_kept = {
            "has-untracked": "untracked",
            "has-edits":     "uncommitted",
            "not-pushed":    "unpushed",
            "mid-rebase":    "inProgress",
            "locked":        "locked",
            "has-nested":    "nested",
            # Never merged: survives, and for the right reason — not "merged".
            "never-merged":  ("noPR", "prUnknown"),
        }
        for name, want in expected_kept.items():
            row = rows.get(name, {})
            want = want if isinstance(want, tuple) else (want,)
            check(f"kept: {name}",
                  row.get("held") == "false" and row.get("reason") in want,
                  f"held={row.get('held')} reason={row.get('reason', 'missing')!r}")

        # The list itself says only WHEN — archiving is one simple idea to the user, and the
        # reasons above are housekeeping that never reaches the UI.
        check("archived rows read as a plain age",
              all(r["status"].startswith("archived ") for r in rows.values()),
              str({k: v["status"] for k, v in rows.items()})[:200])

        # --- restore round-trip ---------------------------------------------------------
        # The hold is a rename, so restore is a rename back — and because the hold never
        # prunes, git still knows about the worktree and no repair is needed.
        held_path = made["merged-clean"]
        check("held folder really left its original path", not held_path.exists())
        siblings = list(held_path.parent.glob(".archived-merged-clean-*"))
        check("held folder sits aside with a timestamp", len(siblings) == 1, str(siblings))

        restored = ctl("automation.archiveRestore", branch="merged-clean")
        check("restore reports success", restored.get("ok") is True, str(restored))
        check("restore puts the row back in the tree",
              "merged-clean" in tree_branches(ctl), str(tree_branches(ctl)))
        check("restored folder is back at its original path", held_path.exists())
        check("git still resolves the restored worktree",
              git(held_path, "rev-parse --is-inside-work-tree") == "true")
        porcelain = git(repo, "worktree list --porcelain")
        entry = next((blk for blk in porcelain.split("\n\n") if str(held_path) in blk), "")
        check("restored worktree is registered again", bool(entry), porcelain[:200])
        check("restored worktree is not prunable", "prunable" not in entry, entry)

        # --- the New-branch picker offers archived rows ----------------------------------
        # An archived row is out of the tree but its name is still taken, so a picker that
        # filtered on every row — not just the live ones — made the branch unreachable by
        # either route: absent from the sidebar, and absent from the one frame that adds it.
        frame = new_branch_frame(ctl, "has-untracked")
        # The picker reads git off the main thread, so the frame opens with the fallback row
        # alone and fills when the branch list lands. Re-ask rather than assert on the first.
        wait(lambda: "has-untracked" in ctl("automation.palette").get("items", []), secs=20)
        frame = ctl("automation.paletteQuery", query="has-untracked")
        check("the New-branch picker offers an archived branch",
              "has-untracked" in frame.get("items", []),
              f"crumb={frame.get('crumb')!r} items={frame.get('items')} {frame.get('missing', '')}")
        check("the archived row is offered as a restore, not a second create",
              frame.get("items", []).count("has-untracked") == 1
              and not frame.get("note"),
              f"items={frame.get('items')} note={frame.get('note')!r}")
        items = frame.get("items", [])
        if "has-untracked" in items:
            enter_row(ctl, "has-untracked")
            check("picking it puts the row back in the tree",
                  bool(wait(lambda: "has-untracked" in tree_branches(ctl), secs=15)),
                  str(tree_branches(ctl)))
            check("and takes it out of the Archived list",
                  "has-untracked" not in status_map(ctl), str(sorted(status_map(ctl))))

        # --- the reaper -----------------------------------------------------------------
        # It reads nothing but the epoch in the folder name, so no predicate bug can reach it.
        stale = held_path.parent / f".archived-reapme-{int(time.time())}-deadbeef"
        stale.mkdir()
        (stale / "x").write_text("x")
        ctl("automation.archiveSweep")   # a tick reaps first
        time.sleep(4)
        check("reaper does not delete a folder whose hold is live", stale.exists())

        os.environ["SYNTH_ARCHIVE_HOLD_SECONDS"] = "0"
        kill_all()
        p, sock = launch(state, log + ".2", extra_args=[
            "-synth-archive-sweep", "<true/>", "-synth-archive-dry-run", "<false/>",
        ])
        ctl = Ctl(sock, repo)
        gone = wait(lambda: not stale.exists(), secs=30)
        check("reaper deletes a folder whose hold has expired", bool(gone),
              "still present" if stale.exists() else "")

        # --- restore after the folder is gone for good -----------------------------------
        # The same launch reaped with-stash's held folder. Its row is still archived, and
        # restore is the only route to it — so restore has to cut the checkout again from the
        # branch rather than decline. A restore that gave up here left the branch with no way
        # back at all: hidden from the tree, and its name taken in the picker.
        recut = made["with-stash"]
        reaped = wait(lambda: not recut.exists()
                      and not list(recut.parent.glob(".archived-with-stash-*")), secs=30)
        check("the reaper took with-stash's folder", bool(reaped),
              str(list(recut.parent.glob("*with-stash*"))))
        check("the reaped row is still archived", "with-stash" in status_map(ctl),
              str(sorted(status_map(ctl))))

        again = ctl("automation.archiveRestore", branch="with-stash")
        check("restore reports success with no folder to move back",
              again.get("ok") is True, str(again))
        check("the row comes back into the tree",
              bool(wait(lambda: "with-stash" in tree_branches(ctl), secs=30)),
              str(tree_branches(ctl)))
        check("the checkout is cut again at its old path",
              bool(wait(lambda: recut.exists(), secs=30)),
              str(list(recut.parent.iterdir())[:12]))
        check("the re-cut worktree is a real checkout of the branch",
              git(recut, "rev-parse --abbrev-ref HEAD") == "with-stash",
              git(recut, "rev-parse --abbrev-ref HEAD"))
        porcelain = git(repo, "worktree list --porcelain")
        entry = next((blk for blk in porcelain.split("\n\n") if str(recut) in blk), "")
        check("the re-cut worktree is registered", bool(entry), porcelain[:200])

        # The same restore, with the reaper's half-done state built by hand instead of waited
        # for. The reaper deletes a held folder and prunes the repo afterwards, so for a moment
        # `worktree list` names a path with nothing at it — and a restore that read the list
        # alone called that a checkout, marked the row ready, and cut nothing. Landing in that
        # window is a race the check above loses only sometimes; deleting the folder and
        # leaving git's registration standing is the same state, every run.
        sh(f"rm -rf '{recut}'")
        stale_entry = next((blk for blk in git(repo, "worktree list --porcelain").split("\n\n")
                            if str(recut) in blk), "")
        check("git still holds a registration for the folder that just went",
              "prunable" in stale_entry, stale_entry)
        ctl("automation.archiveBranch", branch="with-stash")
        ctl("automation.notifDrain")
        wait(lambda: "with-stash" in status_map(ctl), secs=20)
        over_stale = ctl("automation.archiveRestore", branch="with-stash")
        check("restore reports success over a registration git hasn't pruned",
              over_stale.get("ok") is True, str(over_stale))
        check("and cuts the checkout again rather than trusting the registration",
              bool(wait(lambda: recut.exists(), secs=30)),
              str(list(recut.parent.iterdir())[:12]))
        check("which is a real checkout of the branch",
              git(recut, "rev-parse --abbrev-ref HEAD") == "with-stash",
              git(recut, "rev-parse --abbrev-ref HEAD"))
        entry = next((blk for blk in git(repo, "worktree list --porcelain").split("\n\n")
                      if str(recut) in blk), "")
        check("and is registered, with nothing stale left behind",
              bool(entry) and "prunable" not in entry, entry)

    finally:
        kill_all()
        sh(f"git -C '{repo}' worktree unlock '{made['locked']}' 2>/dev/null")
    return result()


if __name__ == "__main__":
    sys.exit(main())
