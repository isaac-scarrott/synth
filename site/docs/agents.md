# Agents

Synth hosts coding agents it did not write. Whichever ones you have installed are the ones it offers, and changing which one you use changes nothing else.

Synth ships with support for four agents and a way to name your own.

|  |  |
|---|---|
| **Claude Code** | `claude` |
| **OpenCode** | `opencode` |
| **OpenCode 2** | `opencode2` |
| **Antigravity** | `agy`, the command-line agent |
| **Your own** | Any command you name |

You do not point Synth at any of them. It looks at what your login shell can see, which means version managers and every install prefix are covered, and an agent that is not installed is simply not offered. Install a new one and it appears; remove one and it stops being offered.

> Antigravity here means `agy`, the command-line agent, not the Antigravity IDE. The IDE installs a launcher of the same name; Synth resolves the symlink and rejects a candidate inside an application bundle, so it does not mistake one for the other.

## Naming your own

**Settings ▸ Synth ▸ Agents** takes a command, a name, and a base.

The base is the built-in whose behaviour drives yours. Status, resume, paste and tool registration all differ per agent and cannot be typed into a field, so a custom agent borrows a built-in's handling. Synth runs your command with `--version` and recognises the base for you where it can.

The command can be a shell alias. An alias is something only an interactive shell can see, so Synth asks your login shell for its aliases along with its PATH, follows chains, and keeps any flags you pinned as the leading arguments of the launch.

An agent with no command, or no base, is not offered at all, exactly like one that is not installed. Switching an agent off in Settings drops it from every **New** surface and never touches a session already running it.

## What Synth changes about your agent

Synth runs your agent, so it is worth knowing exactly what it does and does not touch. The short version: it adds things at launch, and it does not rewrite your files.

### Tools, at launch

Synth's [bundled MCP servers](tools.md) are handed to each agent the way that agent expects to receive them, on the command that starts it. Nothing is written into your repository to do this. Older builds wrote an `.mcp.json`, an `opencode.json` or an `.agents/mcp_config.json` into every managed worktree; those are gone, and worktrees an older build wrote into are cleaned up on launch while the file is provably still Synth's.

The cost of doing it at launch is that an agent you start some other way does not get the tools. A `claude -p` in a Synth terminal is not the same as an agent session.

### Status

Synth reads each agent the way that agent can be read: Claude Code and Antigravity through their hook systems, OpenCode by subscribing to its own event stream. Your own hooks are merged with Synth's rather than replaced.

### Colours

Synth installs a theme for Claude Code and for both OpenCode versions so that a light Synth does not leave you reading a dark agent, and re-themes them when you change appearance. These are defaults, not locks: your own project-level theme still wins where the agent says it should. Antigravity has no theme setting Synth can reach, and its default scheme draws from the terminal palette Synth already tunes, so Synth writes nothing for it.

### One keybinding

Both OpenCode versions bind `⌃C` to quitting the whole program. Inside Synth it interrupts the turn instead, which is what the same key does in every other agent, and quitting stays on `⌃D`. Synth only claims that binding where it is still the agent's own default, so a key you have rebound yourself is left alone.

## Resuming

Closing Synth does not end a conversation. Sessions come back dormant when you relaunch, and opening one resumes the conversation it was holding.

If an agent exits on its own, the row leaves the tree and lands on a card offering **Reopen**, which puts it back where it stood and resumes it. That card never expires, because an agent quitting is not something you did and might happen while you are elsewhere.

## Agents run on your machine

An agent in Synth runs directly on your Mac, as you, with your files and your network. There is no sandbox and no container. It is the same access the agent has when you run it in a terminal yourself.

What Synth adds is the worktree: an agent works in its branch's own checkout, so it is not editing the copy you are looking at. That is isolation between branches, and it is not isolation between the agent and the rest of your machine.

Whatever permission model your agent has is still the one in force. Synth does not weaken it, does not answer its prompts for you, and does not add a second one. The only thing Synth itself gates is [an agent asking to create a branch](tools.md#synth-app), which always asks.

> If you run your agent with its own approvals turned off, that is what runs inside Synth too. Synth reports what the agent is doing; it does not decide what it is allowed to do.

## First run in a new branch

Claude Code asks you to trust a folder the first time it runs in one, and every new worktree is a new folder. Until you answer, the session is not live, and a comment sent to it will not arrive. Antigravity has the same gate for a path it has not seen. Synth reads that record and never writes it, because pre-accepting trust on your behalf is not Synth's decision to make.
