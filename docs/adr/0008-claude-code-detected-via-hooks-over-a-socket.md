# Claude Code is a *detected* state of a terminal, driven by Claude's own hooks over a unix socket

A Synth session is a terminal. "Claude Code" is not a separate kind you pick at creation — it's what
a terminal *becomes* when `claude` runs inside it, and it reverts when `claude` exits. So the kind and
the liveness indicator (working / needs-input / idle / error) must be **derived from a live signal**,
exactly like every other session status fact (ADR-0001). The signal is Claude Code's own hooks.

**Why hooks, not process inspection.** Polling the PTY's child processes for a `claude` process can
tell you it's *running*, but nothing about what it's *doing* — and the indicator is the whole point.
Claude's hook events map 1:1 onto our `SessionStatus`: `UserPromptSubmit`→working, `Stop`→idle,
`PermissionRequest` (and, under `--dangerously-skip-permissions`, `PreToolUse` on
`AskUserQuestion`/`ExitPlanMode`)→needs-input, `StopFailure`→error, `SessionStart`/`SessionEnd`→
attach/detach. Process inspection can't produce that, so it isn't used.

**Getting hooks in without the user configuring anything: a PATH shim.** Synth prepends a shim dir to
each PTY's `PATH` with a `claude` symlink to the `synth-hook` binary. When the user (or the "New
Claude Code" launcher) runs `claude`, the shim's *launch* role execs the real binary with an injected
`--session-id` and an inline `--settings` carrying our hooks, then gets out of the way. This beats
writing `.claude/settings.json` into each worktree: it works in **any** cwd, leaves zero on-disk
footprint, and fires exactly when `claude` starts. Non-interactive invocations (`claude -p`,
subcommands) pass through untouched. A user's own `--settings`/`settings.json` hooks are preserved by
deep-merging (hook arrays concatenate so both fire; user scalar keys win) — Claude keeps only one
`--settings` and its precedence changed across CLI versions, so replacing would silently drop theirs.
`preferredNotifChannel: notifications_disabled` stops Claude's own notifications double-firing.

**Transport: a unix domain socket, not HTTP.** Synth binds `/tmp/synth-hook-<pid>.sock`; each hook is
a short-lived `synth-hook event <Event>` that reads Claude's event JSON on stdin and writes one signal
line to the socket. A socket injects per-session as cleanly as a port would, with no port allocation,
collision, or loopback-auth surface. The socket server turns each line into a `SessionEvent` on the
bus — the same low-frequency seam ADR-0001 reserved for "an eventual Claude-Code supervisor," now
realised. `SubagentStop` is deliberately ignored (it must not notify like the parent `Stop`).

**Correlation is by injected env, not cwd.** The PTY is spawned with `SYNTH_SESSION_ID` (the row's
id), `SYNTH_SOCKET_PATH`, `SYNTH_HOOK_BIN` and `SYNTH_REAL_CLAUDE`; Claude and its hooks inherit them,
so a signal maps to exactly one row even when several terminals share a worktree. cwd alone is
ambiguous and isn't used for attribution.

This shape (shim → real claude + injected settings → hooks → socket → bus → store) is borrowed from
cmux, a native-macOS terminal app that runs the same design in production. Detection degrades to a
no-op when `synth-hook` or a real `claude` can't be found — the terminal just runs normally.
