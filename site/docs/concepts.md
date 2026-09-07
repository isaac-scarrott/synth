# How Synth is organised

Synth organises work as a tree: a project, its branches, and the sessions running inside each branch. Three nouns, and each of them means something specific.

Everything in the sidebar is one of three things.

```
Project        one git repository
└─ Branch      a git branch, checked out in its own folder
   └─ Session  a live thing running inside that branch
```

The tree is the whole model. There is nothing above a project and nothing below a session.

## Project

A project is exactly one git repository. Never more than one, and never a subfolder of one. Adding a project points Synth at a repository path.

Projects do not nest and they do not span repositories. Work that crosses two repositories is two projects, and Synth will not pretend otherwise.

## Branch

A branch is a git branch in that repository, discovered automatically. Sessions run inside a branch.

What makes a Synth branch different from a git branch is that it is *checked out*. Each one has its own folder on disk with its own copy of the files, so several branches can be open, and running, at the same time. That folder is a git worktree, and [Branches and worktrees](branches.md) is about what lives in it.

There is no single branch you are "on". Synth does not surface git's HEAD, and any number of branches can have work running in them at once.

## Session

A session is one live thing inside a branch: an agent, a terminal, a browser, a simulator, or an inspect. Each carries a status, which is what the sidebar reads. [Sessions](sessions.md) covers the kinds.

A session is not a tab. A tab is a way of showing a session, and Synth can show sessions as sidebar rows or as tabs. The session is the thing; the row and the tab are both handles on it.

## Words your agent uses differently

Synth hosts agents it did not write, and every one of them already uses these words. They do not all mean the same thing by them, and the differences are not small.

| Word | In Synth | In the agent you are running |
|---|---|---|
| **Branch** | A git branch, checked out in its own folder. The parent of your sessions. | Claude Code says **worktree** for the folder and keeps "branch" for the git ref alone. Antigravity's `/branch` is an alias for `/fork`, which copies a conversation and touches no files at all. |
| **Session** | Anything running in a pane: an agent, a terminal, a browser, a simulator, an inspect. | All three mean a conversation with the model. You can start and clear several of those inside one Synth session without the row changing. |
| **Agent** | Which coding agent a session is running. Claude Code, OpenCode, OpenCode 2, Antigravity, or one you named yourself. | A configuration inside that program. OpenCode's agents are Build and Plan; Antigravity's are personas you switch with `/agents`; Claude Code uses the word for subagents and teammates as well. All of those live inside one Synth agent. |
| **Project** | One git repository. | Claude Code scopes to whichever directory you launched in. Antigravity's `--project` groups its own chat history and has nothing to do with a repository. |

**Synth's words describe what is on your disk and in your sidebar. Your agent's words describe what is in its conversation.** That resolves all four. Where a page here means the agent's sense of a word, it says so and names the agent.

> One word is the same in both, deliberately. **Needs input** means a session has stopped and cannot go on until you answer it, which is exactly what Claude Code means by it. Synth reports the same state for every agent it hosts, whether or not that agent has a name for it.

## What things are called when they end

Four verbs, and they are not synonyms. Each one is about how much you lose.

|  |  |
|---|---|
| **Close** | Ends a session. The row goes and the process dies. Nothing leaves the filesystem. |
| **Archive** | Puts a branch row away. The folder is untouched and the row comes back from `⌘K`, for as long as the branch exists. |
| **Remove** | Drops a project row from the sidebar. The repository stays cloned and the folders stay on disk. |
| **Delete** | Destroys a worktree folder on disk. The git branch survives it. This is the only one that confirms. |

Deleting names the folder precisely because the branch outlives it. Everything else is reversible, which is why nothing else asks you twice.
