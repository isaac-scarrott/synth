# Testing Archive by hand

```sh
app/sandbox.sh            # build, seed fixtures, launch
app/sandbox.sh --reset    # delete the whole thing
```

Everything lives in `/tmp/synth-archive-sandbox`. The app runs as **Synth Sandbox** with its own
Application Support root, so your real Synth and Synth Dev can't be touched. Fixtures are rebuilt
on every launch, so a run that swept something still starts clean next time.

Clocks are compressed — grace `0s`, tick `60s`, hold `600s` — so a clean-up you'd normally wait a
week for happens while you watch. Real defaults are 7 days and 14 days.

---

## The five-minute version

1. **Hover a branch row.** The action button is an archive box, tooltip `Archive`.
2. **Click it.** The row goes immediately. A card says `Archived <name>` with an archive-box icon
   and a `⌘↩` hint. No dialog, no explanation.
3. **Press ⌘↩ within 8s.** The row comes back exactly where it was. Nothing on disk moved.
4. **Do it again and let the card drain.** Now it's archived for real.
5. **⌘K → the project → `Archived · N`.** Your row is there, reading `archived just now`. Select it
   → `Restore`. It's back in the sidebar.
6. **Archive `merged-clean` and wait ~2 minutes** (two sweeps, 60s apart). It disappears from the
   Archived list and a card says `Cleaned up merged-clean`. Its folder is now a hidden
   `.archived-merged-clean-…` sibling — still on disk for 10 minutes, then really gone.

That's the whole feature from the user's side: put it away, get it back, and it tidies itself up.

---

## What must NOT happen

This is the part worth your attention. Archive each of these, force sweeps, and confirm the folder
is **still there** after several minutes. Every one of these is real work that would be lost.

| Branch | Why it must survive |
|---|---|
| `has-untracked` | Holds a file in no commit and on no remote |
| `has-edits` | Uncommitted changes to a tracked file |
| `not-pushed` | A commit that exists on no remote |
| `mid-rebase` | A half-finished rebase — the worktree looks *clean* |
| `locked` | `git worktree lock` — a machine-readable "don't touch" |
| `has-nested` | Another repo inside it, whose commits an `rm -rf` would take too |
| `never-merged` | A parked spike. Never merged, so never reclaimable |
| `with-stash` | Has a stash — this one **should** be reclaimed (stashes live in the repo and survive the folder) |

Check them at any point:

```sh
ls "/tmp/synth-archive-sandbox/support/worktrees/"*/
```

All eight folders should still be listed. Only `merged-clean` and `with-stash` may vanish.

To see *why* something was kept — this is deliberately not in the UI:

```sh
log stream --predicate 'subsystem CONTAINS "synth" AND category == "sweeper"' --level info
```

---

## Other things to poke

**Delete still confirms.** ⌘K → a branch → `Delete worktree now` → a confirm frame with `Cancel`
preselected. This is the only path that destroys anything, and it asks from every surface. Archive
asks from none.

**Undo cards wear their subject.** Close a terminal, a Claude session, and a branch. Each card shows
that thing's own icon, not a shared undo arrow.

**Restore after a sweep.** Archive `merged-clean`, wait for `Cleaned up`, then ⌘K → `Archived` →
`Restore` within the 10-minute hold. The folder moves back and git still resolves it — the hold is a
rename, never a delete, and it deliberately doesn't prune, so no repair is needed.

**Make one dirty mid-flight.** Archive `merged-clean`, then before the sweep lands:

```sh
echo x > "/tmp/synth-archive-sandbox/support/worktrees/"*/merged-clean/oops.txt
```

It should stop being reclaimable — the conditions are re-checked immediately before the rename, not
just when the row was archived.

**Turn it off.** Settings → Archived worktrees. Archive still works; nothing is ever reclaimed. This
is the shipping default for the first release.

---

## Not covered here

The sandbox has no GitHub remote, so the merged-PR path never runs — relevance is decided by "is
this branch already in the default branch". The PR-state checks (merged vs closed vs unknown,
commits after a merge, cross-fork PRs) need a repo with a real `origin` on GitHub and `gh`
authenticated.
