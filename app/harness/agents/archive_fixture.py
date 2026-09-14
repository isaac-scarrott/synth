"""Scenario worktrees for the archive clean-up — shared by the automated gate (t9_archive.py)
and the hand-driven sandbox (app/sandbox.sh), so the two can never drift apart.

Each entry is one shape a worktree can be in when the clean-up looks at it. The rule is short:
a merged branch is archived for you, and an archived worktree's folder is deleted after the
wait (or sooner over a cap) whatever is inside it — the branch is a git ref, and a restore
re-cuts the checkout from it.
"""
import json, pathlib, subprocess, urllib.parse, uuid


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


def git(d, cmd):
    return sh(f"git -C '{d}' {cmd}")


def stable_hash(path: str) -> str:
    """GitService.stableHash — djb2 over the repo path's UTF-8, as %08x. Must match, or the
    worktrees land somewhere the app's `worktreeRoot` never looks and the finished-row pass
    leaves them all alone (it only archives Synth's own worktrees)."""
    h = 5381
    for b in path.encode():
        h = (h * 33 + b) & 0xFFFFFFFF
    return "%08x" % h


def file_url(path):
    """Synth's worktree root lives under "Application Support" — a space. An unescaped file://
    URL decodes to a path that doesn't exist, and the branch is dropped on restore as missing."""
    return "file://" + urllib.parse.quote(str(path))


# name → what the finished-row pass does with the live row. "archived" rows are merged and go
# to the Archived list on their own; "kept" rows are not merged and stay in the tree until the
# user archives them by hand. What is inside the folder plays no part.
EXPECTED = {
    "merged-clean":   "archived",
    "has-edits":      "archived — uncommitted edits go with the folder",
    "has-untracked":  "archived — untracked files go with the folder",
    "merged-gone":    "archived — on the branch alone, its folder is already gone",
    "remote-gone":    "archived, then its ref deleted — the remote dropped it",
    "ref-gone":       "archived, then dropped — its ref goes by hand",
    "not-pushed":     "kept — a commit past the merge, so not merged",
    "never-merged":   "kept — never merged",
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
    # it's what exposed the clean-up hardcoding `origin/HEAD` instead of resolving the default.
    sh(f"git -C '{origin}' symbolic-ref HEAD refs/heads/main")
    sh(f"git clone -q '{origin}' '{repo}'")
    git(repo, f"config user.email you@example.com && git -C '{repo}' config user.name You")
    (repo / "README.md").write_text("# Demo project\n\nA sandbox for testing Archive.\n")
    git(repo, "add -A")
    git(repo, "commit -qm 'initial commit'")
    git(repo, "branch -M main")
    git(repo, "push -q -u origin main")
    # What a real clone has. (A repo *without* origin/HEAD is a real shape too, and the
    # clean-up resolves it via GitService.defaultBase — but that path is not what this
    # fixture is for.)
    git(repo, "remote set-head origin -a")

    wt_root = support_dir / "worktrees" / f"demo-project-{stable_hash(str(repo))}"
    sh(f"rm -rf '{wt_root}'")
    wt_root.mkdir(parents=True)

    def merged(name):
        """Merged into main and pushed — the shape the finished-row pass archives."""
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

    # Merged, with work left in the folder. Neither is a reason to keep the folder any more —
    # archived is the whole decision — and both are the shapes that used to hold a folder for good.
    made["has-edits"] = merged("has-edits")
    (made["has-edits"] / "README.md").write_text("# Demo project\n\nEdited, not committed.\n")

    made["has-untracked"] = merged("has-untracked")
    (made["has-untracked"] / "notes.md").write_text("# scratch notes nobody committed\n")

    # A commit past the merge, on no remote. Not merged, so the pass leaves it — and once the
    # user archives it by hand, the folder still goes: the commit lives on the branch ref.
    made["not-pushed"] = merged("not-pushed")
    (made["not-pushed"] / "local.txt").write_text("local only\n")
    git(made["not-pushed"], "add -A")
    git(made["not-pushed"], "commit -qm 'never pushed anywhere'")

    # Merged and pushed like merged-clean; the gate deletes its folder once Synth is up (restore
    # drops a row whose folder is already missing, so the state can't seed one). The row then
    # sits in the sidebar with nothing on disk behind it, and the finished-row pass archives it
    # on the branch's evidence alone.
    made["merged-gone"] = merged("merged-gone")

    # Merged and pushed, then deleted on the remote — what a merged PR leaves behind. The suite
    # removes its folder, so nothing is left of it but a ref no one can reach the work through.
    made["remote-gone"] = merged("remote-gone")
    git(repo, "push -q origin --delete remote-gone")

    # Merged and pushed like the rest; the suite deletes its ref by hand once it is archived,
    # standing in for a branch removed outside Synth. What is left is a row pointing at nothing.
    made["ref-gone"] = merged("ref-gone")

    # Never merged — a parked spike. Stays in the tree until the user puts it away.
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
