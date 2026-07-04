# State is persisted to a JSON snapshot and reconstructed on launch

Synth is a place you live in all day, so the tree you built — workspaces, their worktree/branch
rows, your sessions — must survive a quit. It now does: the durable tree is snapshotted to a JSON
file under Application Support and rebuilt on the next launch. Live processes do **not** survive;
restore is *reconstruction*, not process hand-off (the cmux native terminal, which Synth's hook and
renderer designs already track, converges on exactly this model).

**Two layers, and only one of them is durable.** The state split from ADR-0001 maps cleanly onto
what can be persisted. The tree (workspaces → branches → sessions) and the low-frequency facts that
key off it (expansion, custom labels, colour) are durable; the high-frequency and process-bound facts
(live `SessionStatus`, `unread`, keyboard selection, the PTY itself) are not — they are recomputed or
started fresh. So the snapshot carries the first set and deliberately omits the second. Restored
sessions come back **dormant**: `.idle`, no process; opening one lazily spawns a shell in its worktree
(`TerminalManager` already creates views on demand, so no launch-time process storm).

**Storage: a versioned JSON snapshot, not UserDefaults or a database.** `UserDefaults` already holds
the scalar prefs (theme, sidebar width); a nested tree belongs in a real file. `PersistenceStore`
writes `~/Library/Application Support/Synth/state.json` atomically, rotating the prior file to
`state-previous.json`, gated by a schema `version`. A truncated or format-shifted primary falls back
to the backup, a bad backup to a clean start — a bad file can never wedge launch. The DTOs
(`PersistedState`/`Workspace`/`Branch`/`Session`) are plain `Codable` structs kept **separate from the
`@Observable` runtime models**, so the on-disk format is explicit and runtime-only fields can't leak to
disk by accident. Model ids became stable (`let id: UUID`, restored from disk) so persisted expansion
and selection keep pointing at the same rows.

**Saving: a timer plus a terminate flush, not per-mutation calls.** Rather than instrument every
mutation site (and inevitably miss one), a 4-second autosave `Task` snapshots the tree and writes only
when the bytes changed (the encoder sorts keys, so an unchanged tree encodes identically and is
skipped). `applicationWillTerminate` forces a final flush for the normal-quit case. This is cmux's
timer-over-instrumentation model; the cost of a hard-crash losing the last few seconds is accepted.

**Reconciliation is Synth's job, because worktrees are Synth's concept (ADR-0007).** cmux doesn't
manage worktrees, so it has nothing to reconcile; Synth does. On load, a workspace or branch folder
that is *confirmed deleted* is dropped — the user removed it outside Synth. Confirmed-deleted means the
parent directory exists but the folder itself doesn't; a folder that's merely unreachable (unmounted
external/network volume, missing ancestor) is **kept**, so a transient absence at launch never silently
and permanently erases rows. It's cheap (no git call per row); a folder that still exists but is no
longer a tracked worktree is also harmless to keep, since a shell can still run there. The reconciled
tree is what gets re-saved, so pruning is durable.

**Claude sessions resume their conversation; plain terminals don't.** A restored terminal just gets a
fresh shell — there is nothing to restore, and no local live-process layer (tmux/daemon) was
introduced to fake one. A Claude session is different because the conversation lives on disk under
Claude Code's own control. Synth's launch shim (ADR-0008) *already* mints Claude's `--session-id`; we
now capture that id — Claude echoes it on every hook payload, so `synth-hook` forwards it over the
existing socket and the store records it on the session (`claudeSessionID`). A restored Claude row
launches `claude --resume <id>` as its initial input instead of `claude`, and the shim skips minting a
fresh `--session-id` when `--resume`/`--continue` is present (the two are mutually exclusive). The
whole path rides infrastructure that already existed; a stale/missing id degrades to Claude's own
"no conversation found", never a crash. Verified end to end: a restored Claude row opens straight into
Claude Code's resume UI with the captured id.

**Deliberately not done: surviving live local processes.** Backing terminals with `tmux`/`dtach` so a
running shell (and its scrollback) outlives a restart is a genuine architecture change to the spawn
path, and cmux confirms the local model is "respawn, don't hand off." It's out of scope here and would
get its own ADR. Also unsolved: multiple concurrent Synth instances share one `state.json` and would
race — today's usage is one instance, and the atomic write bounds the damage to last-writer-wins.
