# Coding agents are a registry of supervisors, not a hard-coded Claude Code

ADR-0008 established that Claude Code is a *detected state of a terminal*, driven by Claude's own
hooks over a unix socket. It assumed one agent. Synth now hosts more than one — starting with
**OpenCode** — and the two are instrumented in fundamentally different ways. This ADR generalises
ADR-0008 rather than replacing it: everything it says about Claude Code remains true.

## The shape

`SessionKind` gains `.agent(AgentID)` in place of `.claudeCode`. Which agent a row hosts is data,
not a case: nothing in the sidebar, palette, notifications or persistence switches on a specific
agent. Two types carry the difference:

- **`AgentDescriptor`** — how an agent is named, which binary a terminal runs to become it, where
  it's installed, what its flags look like.
- **`AgentSupervisor`** — the per-session watcher CONTEXT.md already named: it consumes an agent's
  raw event firehose locally and emits only derived status facts onto the bus (ADR-0001). This is
  the seam ADR-0001 reserved for "an eventual Claude-Code supervisor", now real and plural.

**Adding a third agent is one descriptor plus one supervisor.** No other file changes.

## Why the supervisors differ

Claude Code has no programmatic surface, so Synth manufactures one: a PATH shim intercepts `claude`,
injects `--settings` carrying hook commands, and every status fact arrives as a short-lived
`synth-hook event` writing a line to `/tmp/synth-hook-<pid>.sock`.

OpenCode already publishes what Synth needs. Its process serves a typed, ordered `/event` SSE bus
where every event carries a `sessionID`, plus an HTTP API for prompting. So its supervisor is a
*subscriber*, not a callback sink: no hooks, no injected settings, no socket. The shim's only job is
to pass `--port <assigned>` so the server listens where Synth already intends to subscribe (one
server binds to exactly one worktree, and a Synth branch *is* one worktree — so it is one server per
session).

The launch shim therefore stays, but becomes agent-dispatched (`argv[0]`), and its signal vocabulary
generalises from `claude-start`/`claude-end` to `agent-start:<id>`/`agent-end:<id>`.

## Liveness is asserted by the supervisor, never by the launcher

Delivering a browser comment into an agent that has been *launched* but is not yet *reachable*
silently drops it — and for Claude Code, whose delivery is a paste followed by Enter, delivering into
the bare shell left behind by a failed resume would hand a hostile page arbitrary shell execution.
So `.agentReady` is posted by the supervisor, and only it:

- Claude Code is ready when its own `SessionStart` hook fires — that hook runs *from inside* the
  live process, so attaching is readiness.
- OpenCode is ready when its event stream connects. Its shim announces the launch a beat before the
  server binds; treating that announcement as readiness delivered comments into a dead port.

`liveAgentIDs` (the comment-delivery gate) is written by `.agentReady` alone. A persisted `.agent`
kind is still not liveness, exactly as ADR-0008 insisted.

## Consequences

- Per-agent flags, per-agent notification copy ("Claude finished" / "OpenCode finished"), and one
  create row per installed agent on every creation surface. An agent that isn't installed never
  appears.
- Both agents get the bundled browser MCP server registered per worktree, each in its own schema:
  `.mcp.json` (`mcpServers`) for Claude Code, `opencode.json` (`mcp`, `type: "local"`) for OpenCode.
  The server reads `SYNTH_WORKTREE` because OpenCode sets no `CLAUDE_PROJECT_DIR`.
- OpenCode's server is loopback-only and **unauthenticated**. `OPENCODE_SERVER_PASSWORD` would secure
  it, but OpenCode's own TUI races its credentials and dies on the resulting 401. A bare `opencode` in
  any terminal already serves an unauthenticated loopback port, so Synth does not widen the exposure —
  it only makes the port predictable rather than random.
- Text delivery to OpenCode goes through its TUI prompt API (`tui/append-prompt` + `tui/submit-prompt`),
  not `session.prompt`: the TUI is the surface the user is looking at, and it has no session at all
  until its first prompt. Those endpoints publish an event, so a 200 does not mean a TUI received it —
  delivery re-posts until the row actually starts a turn.
- A user abort in OpenCode reports as `session.error` with `error.name == "MessageAbortedError"` *and*
  settles to idle. It is a clean interrupt (OpenCode's 130/143) and must never raise an error toast.
