# Configuration

Settings, what a project can override, and the answer to the question that comes up most: is this a Synth setting or my agent's own configuration?

`⌘,` opens Settings in the content pane, over the tree, so you can see what you are changing. There is a tab for **Synth** and a tab for each project.

**Appearance** is the first section: light or dark, and whether sessions show under their branch in the sidebar or as a tab strip above the panes. That second one is a choice of where, never an on or off.

## Which file is this?

Synth runs your agent, your shell and your terminal, all of which have configuration of their own. That makes one question worth answering before any other.

| If you want to change | It lives in |
|---|---|
| Which agents are offered, and the flags they launch with | Synth Settings |
| What a new branch runs, and the sessions it opens with | Synth Settings |
| Appearance, notification sounds, which bundled tools are on | Synth Settings |
| How your agent behaves: its permissions, its instructions, its own subagents | Your agent's own configuration, unchanged |
| What your shell does on startup | Your shell's own rc files, unchanged |

The line is that **Synth configures Synth**. It does not have a second copy of your agent's settings, and it does not edit the ones you have.

## What Synth writes, and where

Nothing Synth writes goes in your repository. Everything it keeps is in its own Application Support folder, apart from three files it adds beside your agents' own:

- A theme for Claude Code and one for OpenCode, so a light Synth does not leave you with a dark agent. Both are new files under the agent's own themes directory, and both are defaults that your own configuration still overrides.
- One OpenCode keybinding, which is what makes `⌃C` interrupt a turn rather than quit the agent. Synth only claims it where it is still OpenCode's own default, so a key you have rebound is left alone.

Synth's own tools are handed to each agent on the command line that launches it, so there is no configuration file in your worktree for them either. See [what Synth changes about your agent](agents.md#what-synth-changes-about-your-agent).

## A project layers on the default

Project settings are a delta, not a replacement. The shared setup script runs and then the project's runs; the shared agent flags and the project's are concatenated into one launch line, shown as you will actually get it. Leaving a project's field empty means pure inheritance, and **Clear** strips the delta and puts you back on the shared value.

A project can decline the shared setup script outright, which is the case for a repository whose needs are nothing like the rest.

## Integrations

**Settings ▸ Synth ▸ Integrations** is what your agents are allowed to reach through Synth, named for what the agent gets rather than for the machinery that carries it.

|  |  |
|---|---|
| **Browser** | Lets an agent drive and inspect browser sessions. |
| **Worktrees** | Lets an agent create worktrees and hand work off to them. This is the one that always asks you first. |
| **Simulator sessions** | Runs an iOS simulator as a session, its live screen in a pane, tappable by you and drivable by an agent. Needs a full Xcode. |

Switching one off removes it from every agent's launch. It does not affect any MCP server you have configured yourself, which Synth neither reads nor writes.

## New worktree defaults

The setup script and the session template both live here, and both are covered in [Branches and worktrees](branches.md#the-setup-script). Neither ships with a value: a default setup script would be a guess about someone else's repository, and default agent flags should be flags you typed.

## Archived worktrees

The clean-up switch, the grace period, the disk budgets, and a per-project list of what is still on disk with the reason each folder is still there. Covered in [Archiving](branches.md#archiving).

## About

The version you are on, whether a build is waiting, and one switch for anonymous analytics.

Analytics are on by default and turning them off takes effect immediately. There is no account and no identifier tying a report to you. It counts events like a session being created; it never carries file contents, prompts, paths, terminal output, environment or clipboard. The in-app feedback box on `⌘⇧F` attaches only your version and OS alongside what you typed.
