# Testing Archive by hand

```sh
app/sandbox.sh            # build, seed fixtures, launch
app/sandbox.sh --reset    # delete the whole thing
```

Everything lives in `/tmp/synth-archive-sandbox`. The app runs as **Synth Sandbox** with its own
Application Support root, so your real Synth and Synth Dev can't be touched. Fixtures are rebuilt
on every launch, so a run that cleaned something up still starts clean next time.

Clocks are compressed — wait `0s`, tick `60s` — so a clean-up you'd normally wait a week for
happens while you watch. The real default wait is 7 days.

---

## The rule

A merged branch is archived for you. An archived worktree's folder is deleted after the wait, or
sooner once the archive is over its count or disk cap — oldest first. Nothing inside the folder
changes that. The branch is a git ref, so a restore after the folder has gone cuts the checkout
again; and a merged branch the remote has already dropped ends with its ref, and its row goes
with it.

---

## The five-minute version

1. **Hover a branch row.** The action button is an archive box, tooltip `Archive`.
2. **Click it.** The row goes immediately. A card says `Archived <name>` with an archive-box icon
   and a `⌘↩` hint. No dialog, no explanation.
3. **Press ⌘↩ within 8s.** The row comes back exactly where it was. Nothing on disk moved.
4. **Do it again and let the card drain.** Now it's archived for real.
5. **⌘K → the project → `Archived · N`.** Your row is there, reading `archived just now ·
   next clean-up`. Select it → `Restore`. It's back in the sidebar.
6. **Wait a minute.** The merged rows (`merged-clean`, `has-edits`, `has-untracked`,
   `merged-gone`, `ref-gone`, `remote-gone`) leave the tree on their own — no card. A minute
   later their folders go and one card says `Cleaned up N archived worktrees`. `remote-gone`
   also loses its ref and leaves the Archived list.

That's the whole feature from the user's side: put it away, get it back, and it tidies itself up.

---

## What the scenarios are for

| Branch | What happens |
|---|---|
| `merged-clean` | Archived for you, folder deleted next tick |
| `has-edits` | The same — uncommitted edits go with the folder |
| `has-untracked` | The same — untracked files go with the folder |
| `merged-gone` | Its folder is already missing; archived on the branch alone, ref kept (origin still has it) |
| `remote-gone` | Archived, then its ref deleted — the remote dropped it — and the row goes |
| `ref-gone` | Archived; delete its ref by hand and the row is dropped on the next tick |
| `not-pushed` | Stays in the tree: a commit past the merge means not merged. Archive it by hand and the folder goes — the commit is on the branch, and Restore re-cuts it |
| `never-merged` | Stays in the tree until you archive it |

Check the folders at any point:

```sh
ls "/tmp/synth-archive-sandbox/support/worktrees/"*/
```

To see what each tick did:

```sh
log stream --predicate 'subsystem CONTAINS "synth" AND category == "sweeper"' --level info
```

---

## Other things to poke

**Delete still confirms.** ⌘K → a branch → `Delete worktree now` → a confirm frame with `Cancel`
preselected. This is the only path that destroys anything on your say-so, and it asks from every
surface. Archive asks from none.

**Restore after a clean-up.** Archive `not-pushed`, wait for `Cleaned up`, then ⌘K → `Archived` →
`Restore`. The row waits pending for a moment while the checkout is cut again, and `local.txt` —
the unpushed commit — is there.

**The caps.** Settings → Archived worktrees → `Most worktrees archived` → 10. Archive eleven and
the oldest goes on the next tick whatever its countdown said; the ratio under the list says where
you stand.

**Turn it off.** Settings → Archived worktrees. Archive still works; nothing is archived for you
and nothing is ever deleted.

---

## Not covered here

The sandbox has no GitHub remote, so "merged" is decided by "is this branch already in the default
branch". A squash-merged PR — where the branch is an ancestor of nothing — is read off GitHub's PR
state instead, which needs a repo with a real `origin` on GitHub and `gh` authenticated.
