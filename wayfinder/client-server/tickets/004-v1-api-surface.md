---
id: 004
title: v1 API surface
type: grilling
status: open
claimed_by:
blocked_by: [001]
---

## Question

Which operations does the server expose day 1? Raw material is the inventory's operation list
([001](001-current-architecture-inventory.md)); the grilling sorts it into:

- **Session-level** (shared truth): create/attach/write/resize/kill sessions, branch & worktree
  operations, whatever browser/simulator sessions turn out to need.
- **View-level** (per-client data the server stores but doesn't interpret): per-branch layouts,
  anything else the desktop persists.
- **Deferred**: operations that stay app-internal for now and why that doesn't break the scripts
  litmus.

Also settle: what do notifications/approvals look like as API events (the fog note about the
future Teams flow hangs on this being an event, not app UI)?

## Resolution
