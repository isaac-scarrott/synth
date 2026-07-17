---
id: 008
title: Package the implementation handoff brief
type: task
status: closed
claimed_by: isaac
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

**The destination — the brief is written and the design + bindings are locked.** The whole map is
now closed: the mouse-only design (001–005, built in 009–015 behind the 006 milestone) and the
keyboard layer (007) are settled in `working.html`, mirrored in `big-picture-design.html`, the
`diff working.html big-picture-design.html` invariant green (only `<title>` + big-picture's extra
browser/simulator demo session rows — verified).

**Handoff brief:** [handoff.md](../assets/008-handoff-brief/handoff.md). Framed for the
**`port-working-html`** skill: source-of-truth is `working.html` (each behaviour cited by stable
symbol + approximate line), and it carries the seams that skill needs to run —

- the settled behaviour in full: glossary, the layout-tree spine (§3) + its invariants (one active
  pane, no empty pane, 360×240 floor, no close guard), per-pane chrome & drop-zones (§4), mouse
  gestures (§5), unsplit/close/reflow (§6), sidebar echo (§7), focus model (§8), per-branch
  persistence & sticky full-screen (§9), zoom/resize (§10), and the **full keybinding table** (§11);
- a **slice list** (§12) mapping 1:1 to the resolved tickets — spine (A/009) first as it blocks all,
  then B–H fan out — each naming its `working.html` anchors + likely native files;
- the **ADRs** the native work needs (§13): extends 0010 persistence, touches 0009/0011/0003/0013,
  and a recommended **new ADR** for the per-branch binary pane tree + sticky full-screen (a genuinely
  new architectural primitive).

**Ledger:** feature entry appended to `docs/features/2026-07-17.md` + one-line index in `FEATURES.md`
(per CLAUDE.md).

The native SwiftUI implementation is the **next effort** (out of scope, per the map). The
006 → 007 → 008 spine is complete; **no tickets remain — the way to the destination is clear.**
