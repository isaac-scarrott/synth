---
id: 008
title: Package the implementation handoff brief
type: task
status: open
claimed_by:
blocked_by: [007]
---

## Question

The destination. With the mouse design + keybindings settled in `working.html`, write the handoff
brief that another agent implements the native app from — do not implement the native app here.

- Capture the settled behaviour, topology, chrome, sidebar grouping, focus model, persistence rules,
  and full keybinding table, pointing at the exact `working.html` regions as the source of truth.
- Follow Synth's handoff conventions: this is what the **`port-working-html`** skill consumes — frame
  the brief so that skill (fan-out sub-agents in worktrees → integrate → drive the app) can run it.
- Append the feature to the ledger: full entry under `docs/features/<YYYY-MM-DD>.md` + one-line index
  in `FEATURES.md` (per CLAUDE.md), and note any ADR the native work will need.

Resolved when the brief is written and the design + bindings are locked. Native implementation is the
next effort, out of scope here.

## Resolution
