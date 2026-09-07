# Troubleshooting

The things that actually go wrong, what causes each one, and what to do about it.

## My agent is not in the list

Synth offers what your login shell can see. Check, in this order:

- It is switched on in **Settings ▸ Synth ▸ Agents**. An agent switched off is not offered, exactly like one that is not installed.
- Its command runs in a fresh login shell. Synth asks your login shell, not the environment it was launched from, so a PATH set inside a running terminal is not what it sees.
- If the command is an alias, it is one your login shell defines. Synth follows aliases and keeps any flags you pinned to them.

For a custom agent, a missing base is the same as a missing command: both mean the agent is not offered.

## A new branch is missing node_modules, or my .env

Expected. A git worktree contains what git tracks, and nothing it does not. Put the copying and installing in the setup script, which runs in every new worktree. See [the setup script](branches.md#the-setup-script).

## Two branches are fighting over a port

Worktrees isolate files. They do not isolate ports, databases, container names, or anything else with one name on the machine. Derive the port from the branch in your setup script rather than hard-coding one. See [two agents, one port](branches.md#two-agents-one-port).

## The agent is running but nothing I send arrives

Almost always the trust prompt. Claude Code asks you to trust a folder the first time it runs in one, and every new branch is a new folder. Until that is answered the session is not live, so a browser comment or a handed-off brief has nowhere to land. Open the session and answer it.

Antigravity has the same gate for a path it has not seen before.

## I cannot open a branch that already exists

Git allows a branch to be checked out in one place at a time, and it will refuse a second. Either go to the branch row you already have, or cut a new branch for the new line of work.

## No pull request state on any branch

That column is read with the GitHub CLI. It needs `gh` installed and signed in, and the repository needs to be on GitHub. When any of that is not true, the column shows nothing rather than an error.

## I am not getting macOS notifications

Notification Center needs a one-time permission grant, which macOS asks for once. If it was declined, it has to be re-granted in System Settings under Notifications. Cards inside Synth are unaffected either way, and Focus and Do Not Disturb are respected.

## An agent closed by itself

It exited. The row leaves the tree and lands on a card offering **Reopen**, which puts it back where it was and resumes the conversation. That card does not expire.

If it happens repeatedly to the same agent, run its command in a terminal session and watch what it says on the way out.

## I archived something and want it back

`⌘K`, then **Archived**, scoped to the project you are in. Restoring cuts the checkout again if the folder has already been reclaimed. The git branch is never deleted by archiving or by the clean-up behind it, so there is no state a branch cannot come back from.

## Simulator sessions are not offered

They are behind **Settings ▸ Experimental** and off by default. Switch them on there. A device also has to be installed on the machine for there to be a fleet to pick from.

## A downloaded update has not installed

It installs the next time you quit Synth. Nothing is waiting on you, and there is nothing to press. The **Restart to update** row in the sidebar foot only brings that install forward.

## Something is wrong that is not here

`⌘⇧F` opens one box. Type what happened and send it. It carries your version and OS and nothing else: no file contents, no paths, no terminal output.
