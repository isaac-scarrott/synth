# One git worktree per active branch, created lazily

The design shows multiple branches of a workspace live simultaneously, each hosting running sessions
(agents, terminals, dev servers). A single working copy can only have one branch checked out, so
concurrent live branches require **one git worktree per active branch**. The worktree is created
lazily when a branch first gains a session (the "promote a dormant branch into a live group" action)
and torn down when the branch group is deleted. Session processes run with cwd set to their branch's
worktree. Worktrees live in a Synth-managed location, not scattered next to the repo.

Rejected a single working copy with real checkout-switching: only one branch could be live at a time
and switching would disrupt running sessions — it contradicts the design as drawn. Rejected a
worktree per *session*: sessions on the same branch normally want to share one working tree (a dev
server serving the files an agent is editing), and per-session worktrees multiply disk and fragment
the branch's working state.

Hard to reverse — it defines what a "branch group" physically is and shapes session spawning,
persistence, and teardown — so it is recorded here.
