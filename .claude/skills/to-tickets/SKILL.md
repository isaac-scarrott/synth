---
name: to-tickets
description: Break a plan, spec, or the current conversation into a set of tracer-bullet tickets, each declaring its blocking edges, written to a single markdown file in the repo.
disable-model-invocation: true
---

# To Tickets

Break a plan, spec, or conversation into a set of **tickets** — tracer-bullet vertical slices, each declaring the tickets that **block** it.

Tickets live in a single markdown file in the repo: `tickets/<slug>.md`, where the slug is a short kebab-case name for the effort (matching the source spec's slug if there is one, e.g. `specs/review-widget.md` → `tickets/review-widget.md`). One file per effort; all of the effort's tickets in dependency order inside it.

## Process

### 1. Gather context

Work from whatever is already in the conversation context. If the user passes a reference (a spec path such as `specs/<slug>.md`, or another document) as an argument, read its full body.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Ticket titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

Look for opportunities to prefactor the code to make the implementation easier. "Make the change easy, then make the easy change."

### 3. Draft vertical slices

Break the work into **tracer bullet** tickets.

- Each slice cuts a narrow but COMPLETE path through every layer (schema, API, UI, tests) — vertical, NOT a horizontal slice of one layer
- A completed slice is demoable or verifiable on its own
- Each slice is sized to fit in a single fresh context window
- Any prefactoring should be done first

Give each ticket its **blocking edges** — the other tickets that must complete before it can start. A ticket with no blockers can start immediately.

**Wide refactors are the exception to vertical slicing.** A **wide refactor** is one mechanical change — rename a column, retype a shared symbol — whose **blast radius** fans across the whole codebase, so a single edit breaks thousands of call sites at once and no vertical slice can land green. Don't force it into a tracer bullet; sequence it as **expand–contract**. First expand: add the new form beside the old so nothing breaks. Then migrate the call sites over in batches sized by blast radius (per package, per directory), each batch its own ticket blocked by the expand, keeping CI green batch to batch because the old form still exists. Finally contract: delete the old form once no caller remains, in a ticket blocked by every migrate batch. When even the batches can't stay green alone, keep the sequence but let them share an integration branch that all block a final integrate-and-verify ticket — green is promised only there.

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each ticket, show:

- **Title**: short descriptive name
- **Blocked by**: which other tickets (if any) must complete first
- **What it delivers**: the end-to-end behaviour this ticket makes work

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the blocking edges correct — does each ticket only depend on tickets that genuinely gate it?
- Should any tickets be merged or split further?

Iterate until the user approves the breakdown.

### 5. Write the tickets file

Write the approved tickets to `tickets/<slug>.md` using the template below — all tickets in dependency order (blockers first), each with its **Blocked by** listing the titles it depends on. Commit it if the repo is under version control. Do NOT modify the source spec beyond updating its `status` frontmatter to `in-progress` if it has one.

## File template

```markdown
# Tickets: <effort name>

<a one-line summary of what these tickets build. Link the source spec if there is one: [spec](../specs/<slug>.md)>

Work the **frontier**: any unstarted ticket whose blockers are all done. For a purely linear chain that means top to bottom. Work one ticket at a time, in a fresh session per ticket, marking Status as you go.

## <Ticket title>

**Status:** open <!-- open | in-progress | done -->

**Blocked by:** <the titles of the tickets that gate this one, or "None — can start immediately">

### What to build

<the end-to-end behaviour this ticket makes work, from the user's perspective — not a layer-by-layer implementation list>

### Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2

## <Next ticket title>

...
```

In the tickets, avoid specific file paths or code snippets — they go stale fast. Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it and note briefly that it came from a prototype. Trim to the decision-rich parts — not a working demo, just the important bits.

## Working the tickets

This skill produces the file; execution happens in later sessions. Each session: read the tickets file, pick the first frontier ticket (open, all blockers done), set its **Status** to `in-progress`, implement it end to end, tick the acceptance criteria as they're verified, set **Status** to `done`, and commit. Clear context between tickets — one ticket per session. Concurrent sessions are fine: the **Status** field is the claim, so re-read it just before starting.
