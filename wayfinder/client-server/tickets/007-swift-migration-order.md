---
id: 007
title: Swift app migration order
type: grilling
status: open
claimed_by:
blocked_by: [001, 004]
---

## Question

The strangler plan: in what order does the Swift app move onto the API, keeping the app shippable
at every step? Informed by the inventory's coupling map ([001](001-current-architecture-inventory.md))
and the surface ([004](004-v1-api-surface.md)):

- Which capability extracts first (likely whatever is already most server-shaped — the `mcp/`
  processes? — or the PTYs, since they force the streaming machinery)?
- What runs side-by-side during migration (old in-process path vs API path) and how long dual
  paths are tolerated given the scripts litmus.
- Where the per-branch layout persistence moves server-side in the sequence.
- The milestone slicing the brief will hand off.

## Resolution
