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
        # --- undo semantics -------------------------------------------------------------
        # archivedAt is stamped on COMMIT, not on the gesture: the 8s window must change
        # nothing. If this regresses, undo puts a row back that the archive filter then hides,
        # and the row is unreachable except through ⌘K.
        first = ctl("automation.archiveBranch", branch="merged-clean")
        check("archiveBranch verb finds the row", first.get("ok") is True, str(first))
        immediately = status_map(ctl)
        check("archive is not committed during the undo window",
              "merged-clean" not in immediately, f"saw {list(immediately)}")

        # Let the window elapse. Headless, the drain is held (the card would still be there
        # for a returning user), so say so explicitly rather than sleeping forever.
        ctl("automation.notifDrain")
        landed = wait(lambda: "merged-clean" in status_map(ctl), secs=20)
        check("archive lands once the undo window drains", bool(landed))

        for name in made:
            if name != "merged-clean":
                ctl("automation.archiveBranch", branch=name)
                ctl("automation.notifDrain")
        wait(lambda: len(status_map(ctl)) == len(made), secs=25)
        rows = status_map(ctl)
        check("every archived row is listed", len(rows) == len(made),
              f"{len(rows)}/{len(made)}: {sorted(rows)}")

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
        check("restored folder is back at its original path", held_path.exists())
        check("git still resolves the restored worktree",
              git(held_path, "rev-parse --is-inside-work-tree") == "true")
        porcelain = git(repo, "worktree list --porcelain")
        entry = next((blk for blk in porcelain.split("\n\n") if str(held_path) in blk), "")
        check("restored worktree is registered again", bool(entry), porcelain[:200])
        check("restored worktree is not prunable", "prunable" not in entry, entry)

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

    finally:
        kill_all()
        sh(f"git -C '{repo}' worktree unlock '{made['locked']}' 2>/dev/null")
    return result()


if __name__ == "__main__":
    sys.exit(main())
