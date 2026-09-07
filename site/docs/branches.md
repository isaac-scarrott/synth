# Branches and worktrees

Every branch row is a real checkout on disk. That is what lets several agents work at once, and it is also why a new branch does not have your dependencies in it.

When a branch first gains a session, Synth cuts a git worktree for it: a second checkout of the same repository, in its own folder, on its own branch. Same history, same remote, different files.

That is the whole reason several agents can work at once without fighting. Each one is editing a different copy.

## What a new branch has, and what it does not

A fresh worktree contains everything git tracks, at the commit you branched from. It does not contain anything git does not track, because there is nothing in the repository for git to copy it from.

In practice that means the new branch is missing:

- **Your dependencies.** `node_modules`, virtualenvs, build caches, anything in `.gitignore`. They are not there, and the first thing you run will say so.
- **Your local configuration.** `.env`, local certificates, anything you were handed once and never committed.
- **Build output.** Whatever the last build left behind is in the branch it was built in.

This surprises people, and it is not a Synth behaviour: it is what a git worktree is. The fix is the setup script.

## The setup script

Settings has a setup script that runs in every new worktree, once the checkout has landed. Copy the `.env` across, install dependencies, link a cache, whatever this repository needs to be workable.

```
# runs in the new worktree, with the project root as $1
cp "$1/.env" .
pnpm install --prefer-offline
```

There are two scopes. **Settings ▸ Synth ▸ New worktree defaults** holds the script every project runs, and a project's own tab holds its delta, which runs after the shared one rather than replacing it. A project can also opt out of the shared script entirely.

Beside the script is the session template: the list of sessions every new worktree opens with. The first one opens, and the rest wait until you go to them.

> If your repository's `post-checkout` hook fails, the branch is still created. Synth treats the checkout as the contract and the repository's hooks as the repository's business, so a hook that cannot find `pnpm` on a GUI launch PATH leaves you with a working branch and a line in the log rather than no branch at all.

## Two agents, one port

Worktrees isolate files. They do not isolate anything else, and the thing people hit first is ports. Two branches both running `npm run dev` on 3000 is two branches fighting, and Synth does not arbitrate that for you.

What works is making the port a function of the branch rather than a constant. The setup script knows which worktree it is in, so it can write one:

```
# a stable port per branch, rather than the same one everywhere
PORT=$(( 3000 + $(basename "$PWD" | cksum | cut -d' ' -f1) % 100 ))
echo "PORT=$PORT" >> .env
```

The same applies to anything else with one name on the machine: database names, container names, socket paths. If two branches can be live at once, and in Synth they can, then anything they share is something they can collide on.

> Databases are the case to think about before you hit it. Two agents pointed at one development database are two agents writing to each other's data, and no amount of file isolation helps. Give each branch its own, or accept that they are sharing one.

## One branch, one checkout

Git allows a branch to be checked out in one worktree at a time. Try to open the same branch twice and git refuses, and so does Synth. This is a git rule rather than a Synth one, and there is no flag that changes it.

If you want a second line of work, cut a second branch. That is what they are for.

## Archiving

Archiving puts a branch row away. The folder is untouched, the git branch is untouched, and the row is restorable from `⌘K` under **Archived**. It never asks you to confirm, because at that moment there is nothing to lose.

Synth also archives finished branches on its own, so the list you glance at stays the list of what is still going on. A branch is only archived for you once the work is provably somewhere else: merged, clean, pushed, with nothing attached and nothing running inside it, read that way twice a day apart.

Reclaiming the folder comes later and separately, after a grace period you set. Even then the last step is a rename with a hold on it rather than a delete. **Settings ▸ Archived worktrees** lists what is still on disk with the reason each folder is still there, like *PR still open* or *6 days left*.

Once the folder has gone, the branch is the last thing to go, and only under conditions that mean it holds nothing you could lose: nothing running in it, the folder already reclaimed, the work merged into the default branch, and the branch itself no longer on your remote. Then the ref is retired and the row leaves the Archived list with it. This is a `git branch -d`, which refuses to delete a branch that is not merged, and it has its own switch in Settings.

> Restoring an archived branch cuts its checkout again from the branch itself, so a reclaimed folder costs you nothing. What you cannot restore is a row whose branch has been retired, which is why retiring one waits until the work is merged and your remote has dropped it.

## Deleting a worktree

Deleting is the one action that destroys something on disk, so it is the one action that confirms. It removes the checkout folder. The git branch survives, and everything you pushed survives.

Delete through Synth rather than dragging the folder to the Trash. Git keeps its own record of where a worktree lives, and removing the folder behind git's back leaves that record pointing at nothing.
