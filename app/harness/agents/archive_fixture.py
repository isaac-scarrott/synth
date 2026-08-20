"""Scenario worktrees for the archive sweeper — shared by the automated gate (t9_archive.py)
and the hand-driven sandbox (app/sandbox.sh), so the two can never drift apart.

Each entry is one hazard the sweeper has to get right. The happy path is one line; everything
else exists to be REFUSED, and each refusal is a data-loss bug if it regresses.
"""
import json, pathlib, subprocess, urllib.parse, uuid


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


def git(d, cmd):
    return sh(f"git -C '{d}' {cmd}")


def stable_hash(path: str) -> str:
    """GitService.stableHash — djb2 over the repo path's UTF-8, as %08x. Must match, or the
    worktrees land somewhere the app's `worktreeRoot` never looks and B0 refuses them all."""
    h = 5381
    for b in path.encode():
        h = (h * 33 + b) & 0xFFFFFFFF
    return "%08x" % h


def file_url(path):
    """Synth's worktree root lives under "Application Support" — a space. An unescaped file://
    URL decodes to a path that doesn't exist, and the branch is dropped on restore as missing."""
    return "file://" + urllib.parse.quote(str(path))


# name → what the sweeper must decide, and the ctx fragment it must say. `None` = reclaimable.
EXPECTED = {
    "merged-clean":   None,
    "with-stash":     None,
    "merged-gone":    None,
    "has-untracked":  "untracked files",
    "has-edits":      "uncommitted changes",
    "not-pushed":     "commits not pushed anywhere",
    "mid-rebase":     "half-finished",
    "locked":         "locked",
    "has-nested":     "another worktree lives inside it",
    "never-merged":   "never merged",
}


def build(sandbox_root: pathlib.Path, support_dir: pathlib.Path):
    """A repo with a real bare origin, and one worktree per scenario under Synth's own root."""
    sandbox_root.mkdir(parents=True, exist_ok=True)
    origin = sandbox_root / "origin.git"
    repo = sandbox_root / "demo-project"
    sh(f"rm -rf '{origin}' '{repo}'")

    sh(f"git init -q --bare '{origin}'")
    # A bare repo's HEAD names a branch that doesn't exist yet, so `remote set-head -a` can't
    # determine it and origin/HEAD is never created. That's a real-world shape, not a quirk —
    # it's what exposed the sweeper hardcoding `origin/HEAD` instead of resolving the default.
    sh(f"git -C '{origin}' symbolic-ref HEAD refs/heads/main")
    sh(f"git clone -q '{origin}' '{repo}'")
    git(repo, f"config user.email you@example.com && git -C '{repo}' config user.name You")
    (repo / "README.md").write_text("# Demo project\n\nA sandbox for testing Archive.\n")
    git(repo, "add -A")
    git(repo, "commit -qm 'initial commit'")
    git(repo, "branch -M main")
    git(repo, "push -q -u origin main")
    # What a real clone has. (A repo *without* origin/HEAD is a real shape too, and the
    # sweeper resolves it via GitService.defaultBase — but that path is not what this
    # fixture is for.)
    git(repo, "remote set-head origin -a")

    wt_root = support_dir / "worktrees" / f"demo-project-{stable_hash(str(repo))}"
    sh(f"rm -rf '{wt_root}'")
    wt_root.mkdir(parents=True)

    def merged(name):
        """Merged into main and pushed — the only shape that may ever be reclaimed."""
        git(repo, f"checkout -q -b {name} main")
        (repo / f"{name}.txt").write_text(name + "\n")
        git(repo, "add -A")
        git(repo, f"commit -qm 'work on {name}'")
        git(repo, f"push -q -u origin {name}")
        git(repo, "checkout -q main")
        git(repo, f"merge -q --no-ff -m 'merge {name}' {name}")
        git(repo, "push -q origin main")
        git(repo, f"worktree add -q '{wt_root / name}' {name}")
        return wt_root / name

    made = {}

    made["merged-clean"] = merged("merged-clean")

    # A stash names the branch. Stashes live in the repo and survive the folder, so this is
    # lost context, not lost work — it must NOT block.
    made["with-stash"] = merged("with-stash")
    (made["with-stash"] / "README.md").write_text("stashed edit\n")
    git(made["with-stash"], "stash push -q -m 'wip on with-stash'")

    # Untracked source: in no commit, on no remote, and invisible to a tracked-only check.
    made["has-untracked"] = merged("has-untracked")
    (made["has-untracked"] / "notes.md").write_text("# scratch notes nobody committed\n")

    made["has-edits"] = merged("has-edits")
    (made["has-edits"] / "README.md").write_text("# Demo project\n\nEdited, not committed.\n")

    made["not-pushed"] = merged("not-pushed")
    (made["not-pushed"] / "local.txt").write_text("local only\n")
    git(made["not-pushed"], "add -A")
    git(made["not-pushed"], "commit -qm 'never pushed anywhere'")

    # A half-finished operation leaves a CLEAN worktree with unreplayed patches in the git dir.
    made["mid-rebase"] = merged("mid-rebase")
    gd = git(made["mid-rebase"], "rev-parse --absolute-git-dir")
    pathlib.Path(gd, "rebase-merge").mkdir(parents=True, exist_ok=True)

    made["locked"] = merged("locked")
    git(repo, f"worktree lock '{made['locked']}'")

    # A nested repo whose commits an rm -rf of the parent would take with it.
    made["has-nested"] = merged("has-nested")
    inner = made["has-nested"] / "vendored"
    inner.mkdir()
    sh(f"git init -q '{inner}'")

    # Merged and pushed like merged-clean; the gate deletes its folder once Synth is up (restore
    # drops a row whose folder is already missing, so the state can't seed one). The row then
    # sits in the sidebar with nothing on disk behind it, and the finished-row pass archives it
    # on the branch's evidence alone.
    made["merged-gone"] = merged("merged-gone")

    # Never merged — the parked-spike case the naive "no open PR" rule would have deleted.
    git(repo, "checkout -q -b never-merged main")
    (repo / "spike.txt").write_text("an experiment worth keeping\n")
    git(repo, "add -A")
    git(repo, "commit -qm 'spike'")
    git(repo, "push -q -u origin never-merged")
    git(repo, "checkout -q main")
    git(repo, f"worktree add -q '{wt_root / 'never-merged'}' never-merged")
    made["never-merged"] = wt_root / "never-merged"

    return repo, made


def state(repo, made):
    """The tree Synth restores on launch: one project, main plus every scenario branch."""
    branches = [{
        "id": str(uuid.uuid4()), "name": "main",
        "worktreeURL": file_url(repo), "lastActivity": "now", "sessions": [],
    }]
    for name, path in made.items():
        branches.append({
            "id": str(uuid.uuid4()), "name": name,
            "worktreeURL": file_url(path), "lastActivity": "now", "sessions": [],
        })
    ws_id = str(uuid.uuid4())
    return {
        "version": 1,
        "workspaces": [{
            "id": ws_id, "name": "demo-project", "url": file_url(repo),
            "colorIndex": 0, "branches": branches,
        }],
        "expanded": [ws_id],
    }
