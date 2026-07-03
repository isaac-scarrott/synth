# No singular "current branch"; three orthogonal row states (open, selected, live)

The original design (see FEATURES.md) spoke of "the checked-out branch" with a green "current" dot
and a white "active pill", implying one distinguished branch per workspace. The worktree model
(ADR-0004) makes every live branch checked out in its own worktree, so a singular "current branch" no
longer exists. This ADR retires that concept and replaces it with three independent row states:

- **Open (expanded):** whether a workspace or branch group is expanded. Multiple can be open at once,
  like multiple workspaces. Stored as an expanded-set.
- **Selected:** two distinct fields, not one. A transient **navigation cursor** (any row, dismissed
  on mouse-move, a pure visual ring) and a sticky **open session** (always a session, what the content
  pane renders, survives mousing around). Activating the cursor on a session sets the open session.
- **Live:** whether a session is actively running (green dot / liveness roll-up). Derived from
  supervisor status, non-exclusive — any number of sessions and branches may be live simultaneously.

The white "active pill" is **derived, not stored**: it marks the branch containing the *open session*
(not the ephemeral cursor). Rejected keeping a distinct `focusedBranch` field: it
would be a third near-synonym of selected/open and drift out of sync. Git's real HEAD is treated as an
implementation detail and is not surfaced.

This is surprising against the prior design language and shapes the store schema and every branch
indicator, so it is recorded.
