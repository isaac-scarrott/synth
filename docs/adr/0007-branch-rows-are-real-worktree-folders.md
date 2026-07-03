# Every branch row maps to a real worktree folder; removal is UI-only

Refines ADR-0004 (worktree per active branch) now that worktrees are physically created. Every
branch row in the tree is backed by a real checkout folder on disk — the repo root for the branch
checked out there (usually main), a Synth-created git worktree for everything else. There are no
"dormant" rows pointing at nothing: what you see in the sidebar is what exists on disk, and every
session's cwd is its row's folder.

Creation is **eager and user-chosen**, not lazy-on-first-session as ADR-0004 sketched. Adding a
workspace opens a multi-select picker of the repo's branches: branches that already have a worktree
are pre-checked and reused; checking one without runs `git worktree add` on Add. Later additions go
through "Create worktree" (kebab or ⌘K), which checks out an existing branch or cuts a new one off a
chosen base. Lazy creation was rejected because it reintroduces rows that lie about the disk, and
because the user explicitly wants to curate which branches are visible rather than seeing all of
them.

Synth-created worktrees live under the app's own data directory —
`~/Library/Application Support/Synth/worktrees/<repo>-<stable-path-hash>/<sanitised-branch>` — not
inside or beside the repo. The stable hash keeps same-named repos apart and must not change across
launches (worktrees are found again by `git worktree list`, but the planned path for *new* ones must
be reproducible). The location is a sensible default now, intended to become configurable.

Removing a workspace or branch row is **UI-only**: sessions are terminated, but the worktree, the
branch, and everything on disk stay untouched (ADR-0004's teardown is deferred until a real delete
action exists). The action is labelled "Remove", never "Delete", to keep the promise visible.
Sessions are the exception — deleting a session genuinely ends its process.
