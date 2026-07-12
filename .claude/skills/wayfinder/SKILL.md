---
name: wayfinder
description: Plan a huge chunk of work — more than one agent session can hold — as a shared map of investigation tickets stored as markdown files in the repo, and resolve them one at a time until the way to the destination is clear.
disable-model-invocation: true
---

A loose idea has arrived — too big for one agent session, and wrapped in fog: the way from here to the **destination** isn't visible yet. Wayfinding is about finding that way, not charging at the destination. This skill charts the way as a **shared map** of markdown files in the repo, then works its tickets one at a time until the route is clear.

The destination varies per effort, and naming it is the first act of charting — it shapes every ticket. It might be a spec to hand off and iterate on, a decision to lock before planning starts, or a change made in place like a data-structure migration. The map is domain-agnostic — engineering work, course content, whatever fits the shape.

## Plan, don't do

Wayfinder is **planning** by default: each ticket resolves a decision, and the map is done when the way is clear — nothing left to decide before someone goes and does the thing. The pull to just do the work is usually the signal you've reached the edge of the map and it's time to hand off. An effort can override this in its **Notes** — carrying execution into the map itself — but absent that, produce decisions, not deliverables.

## Refer by name

Every map and ticket is a markdown file, and every file has a **name** — its title. In everything the human reads — narration, the map's Decisions-so-far — refer to it by that name, never by a bare id or filename. A wall of `012, 013, 014` is illegible; names read at a glance. The id and file path don't vanish — a name wraps its link — but they ride *inside* the name, never stand in for it.

## Where the map lives

Everything lives under a `wayfinder/` directory at the repo root:

```
wayfinder/
├── map.md              # the map — the canonical artifact
├── tickets/
│   ├── 001-<slug>.md   # one file per ticket
│   ├── 002-<slug>.md
│   └── ...
└── assets/             # artifacts created while resolving tickets
    └── 001-<slug>/     # one directory per ticket that produces assets
```

Ticket ids are zero-padded sequential integers (`001`, `002`, ...), assigned at creation and never reused. To allocate a new id, list `tickets/` and take the highest id plus one. All cross-references are relative markdown links: `[Choose the storage engine](tickets/003-choose-storage-engine.md)`.

Commit map and ticket changes as you go if the repo is under version control — the git history doubles as the audit trail, and concurrent sessions reconcile through normal merges.

## The map body

The map is `wayfinder/map.md` — the whole effort at low resolution, loaded once per session. Open tickets are **not** listed in the body — they are found by scanning `tickets/` (see [Finding the frontier](#finding-the-frontier)).

```markdown
# <Map title>

## Destination

<what reaching the end of this map looks like — the spec, decision, or change this effort is finding its way to. One or two lines; every session orients to it before choosing a ticket.>

## Notes

<domain; glossary of terms this effort has pinned down; standing preferences for this effort>

## Decisions so far

<!-- the index — one line per closed ticket: enough to judge relevance, then follow the link for the detail the ticket holds -->

- [<closed ticket title>](tickets/<id>-<slug>.md) — <one-line gist of the answer>

## Not yet specified

<!-- see "Fog of war": in-scope fog you can't ticket yet; graduates as the frontier advances -->

## Out of scope

<!-- see "Out of scope": work ruled beyond the destination; closed, never graduates -->
```

## Tickets

Each ticket is one file in `wayfinder/tickets/`. Its body is the question, sized to one 100K token agent session. State lives in YAML frontmatter:

```markdown
---
id: 003
title: Choose the storage engine
type: grilling            # research | prototype | grilling | task
status: open              # open | closed
claimed_by:               # empty = unclaimed; otherwise a name, e.g. isaac
blocked_by: [001, 002]    # ticket ids that must be closed first; empty list if none
---

## Question

<the decision or investigation this ticket resolves>

## Resolution

<!-- empty until resolved — see "Work through the map" -->
```

A session **claims** a ticket by setting `claimed_by` to the dev driving the map, **first**, before any work, so concurrent sessions skip it. That field *is* the claim: an open ticket with an empty `claimed_by` is unclaimed.

A ticket is **unblocked** when every ticket in its `blocked_by` list has `status: closed`. The answer isn't part of the question — it's recorded in the `## Resolution` section on resolution (see [Work through the map](#work-through-the-map)). Assets created while resolving a ticket go in `wayfinder/assets/<id>-<slug>/` and are linked from the ticket, not pasted in.

### Finding the frontier

The **frontier** is the set of open, unblocked, unclaimed tickets — the edge of the known. To find it, read the frontmatter of every file in `tickets/` and filter:

1. `status: open`
2. `claimed_by` empty
3. every id in `blocked_by` belongs to a ticket with `status: closed`

Order by id. This scan is cheap — frontmatter only, never full bodies.

## Ticket Types

Every ticket is either **HITL** — human in the loop, worked *with* a human who speaks for themselves — or **AFK**, driven by the agent alone. A HITL ticket only resolves through that live exchange; the agent never stands in for the human's side of it (a questioning session that answers its own questions has broken this).

- **Research** (AFK): Reading documentation, third-party APIs, or local resources like knowledge bases. Creates a markdown summary in the ticket's assets directory. Use when knowledge outside the current working directory is required.
- **Prototype** (HITL): Raise the fidelity of the discussion by making a cheap, rough, concrete artifact to react to (see [Prototyping](#prototyping)). Links the prototype as an asset. Use when "how should it look" or "how should it behave" is the key question.
- **Grilling** (HITL): Structured questioning, one question at a time (see [Questioning](#questioning)). The default case.
- **Task** (HITL or AFK): Manual work that must happen before a *decision* can be made — nothing to decide, prototype, or research, but the discussion is blocked until it's done. Signing up for a service so its API can be judged, provisioning access, moving data so its shape can be seen. This is the one type that *does* rather than decides — and it earns its place by unblocking a decision, not by delivering the destination. The agent drives it alone where it can (AFK); otherwise it hands the human a precise checklist (HITL). Resolved when the work is done; the resolution records what was done and any resulting facts (credentials location, new URLs, row counts) later tickets depend on.

## Questioning

The engine behind grilling tickets and destination-setting. The point is to extract what's in the human's head, not to fill silence with your own guesses.

- **One question per message.** Never a batch. The answer to each question shapes the next; batching wastes both.
- **Concrete over abstract.** "When a booking fails mid-payment, what does the customer see?" beats "what are your error-handling requirements?". Where it sharpens the question, offer 2–4 candidate answers to react to — reacting is easier than generating.
- **Never answer for the human.** If a question is HITL, it resolves through their answer. Don't infer it, don't move on without it, don't soften it into something you can answer yourself.
- **Chase the fuzzy words.** When an answer contains an undefined noun ("the sync job", "premium users") or a hedge ("probably", "usually"), the next question pins it down.
- **Model the domain as you go.** Keep a running glossary of the entities, states, and relationships the answers reveal — what things are called, what states they can be in, what owns what, where the boundaries sit. Disagreements about words are usually disagreements about the model; surface them as questions. Pin down invariants ("can an order ever have zero line items?") and edge cases at the boundaries. The settled glossary lives in the map's **Notes** so every later session speaks the same language.
- **Say what you heard.** Every few exchanges, play back your current understanding in a couple of lines and let the human correct it before building on it.
- **Stop when the decision is made**, not when the topic is exhausted. The ticket's question defines done.

When charting (step 2 of [Chart the map](#chart-the-map)), question **breadth-first**: fan out across the whole space rather than deep on any one thread, surfacing open decisions rather than resolving them.

## Prototyping

For prototype tickets: make the cheapest concrete thing the human can react to, then have the reaction conversation using [Questioning](#questioning).

- Pick the lowest-fidelity form that answers the question: a markdown outline, a sample of the data shape, a stubbed interface or type signatures, a single throwaway HTML page, a hardcoded happy path. If a sketch would settle it, don't write code.
- Timebox it. A prototype that takes the whole session to build leaves no session to discuss it. Rough is the point — polish signals the wrong contract.
- Prototypes are **disposable evidence**, never the deliverable. Save them under `wayfinder/assets/<id>-<slug>/`, link from the ticket, and treat the *decision* the reaction produced as the output.

## Fog of war

The map is *deliberately* incomplete: don't chart what you can't yet see. Beyond the live tickets lies the **fog of war** — the dim view of decisions and investigations you can tell are coming but can't yet pin down, because they hang on questions still open. Resolving a ticket clears the fog ahead of it, graduating whatever's now specifiable into fresh tickets — one at a time, until the way to the destination is clear and no tickets remain.

The map's **Not yet specified** section is where that dim view is written down: the suspected question, the area to revisit later. It's the undiscovered frontier *toward* the destination — everything here is in scope, just not sharp enough to ticket. Write as loosely or as fully as the view allows; it doubles as a signpost for collaborators reading where the effort is headed.

**Fog or ticket?** The test is whether you can state the question precisely now — *not* whether you can answer it now.

- **Ticket when** the question is already sharp — even if it's blocked and you can't act on it yet.
- **Not yet specified when** you can't yet phrase it that sharply. Don't pre-slice the fog into ticket-sized pieces: it's coarser than a ticket, and one patch may graduate into several tickets, or none, once the frontier reaches it.

**Not yet specified** excludes what's already decided (Decisions so far), what's already a live ticket, and what's out of scope (the next section).

## Out of scope

Fog only ever gathers *toward* the destination. The destination fixes the scope, so work beyond it is **out of scope** — it isn't fog, and it doesn't belong in **Not yet specified**. It gets its own **Out of scope** section on the map: work you've consciously ruled out of *this* effort. Scope, not sharpness, lands it here.

Out-of-scope work never graduates — the frontier stops at the destination — so it returns only if the destination is redrawn, and then as a fresh effort, not a resumption.

Ruling something out of scope is a scoping act, not a step on the route. When a ticket that already exists turns out to sit past the destination — mis-scoped in while charting, or exposed by a resolution — **close it** (set `status: closed`; a closed ticket is unambiguously off the frontier) and leave one line in the **Out of scope** section: the gist plus why it's out of scope, linking the closed ticket. It stays out of **Decisions so far**, which records the route actually walked — a scope boundary isn't a step on it.

## Invocation

Two modes. Either way, **never resolve more than one ticket per session.**

### Chart the map

User invokes with a loose idea.

1. **Name the destination.** Run a [Questioning](#questioning) session to pin down what this map is finding its way to — the spec, decision, or change. The destination fixes the scope, so it's settled first.
2. **Map the frontier.** Question again, **breadth-first** this time: fan out across the whole space rather than deep on any one thread, surfacing the open decisions and the first steps takeable now. **If this surfaces no fog** — the way to the destination is already clear, the whole journey small enough for one session — you don't need a map. Stop and ask the user how they'd like to proceed.
3. **Create the map** at `wayfinder/map.md`: Destination and Notes filled in, Decisions-so-far empty, the fog sketched into **Not yet specified**.
4. **Create the tickets you can specify now** as files in `wayfinder/tickets/` — then wire `blocked_by` edges in a **second pass** (tickets need ids before they can reference each other). Wiring sorts them into the frontier and the blocked; everything you can't yet specify stays in the fog — the **Not yet specified** section.
5. Stop — charting the map is one session's work; do not also resolve tickets.

### Work through the map

User invokes with a map (a path to `map.md`, or just the repo if there's only one map). A ticket is **optional** — without one, you pick the next decision, not the user.

1. Load the **map** — the low-res view, not every ticket body.
2. Choose the ticket. If the user named one, use it. Otherwise scan the frontier (see [Finding the frontier](#finding-the-frontier)) and take the first ticket in id order. **Claim it**: set `claimed_by` before any work.
3. Resolve it — **zoom as needed**: read the full body of any related or closed ticket on demand; apply the approach the ticket's `type` names ([Questioning](#questioning) for grilling, [Prototyping](#prototyping) for prototypes) and honour whatever the map's `## Notes` says. If in doubt, default to [Questioning](#questioning).
4. Record the resolution: write the answer into the ticket's `## Resolution` section, set `status: closed`, and **append a context pointer** to the map's Decisions-so-far.
5. Add newly-surfaced tickets (create-then-wire); graduate any fog the answer has made specifiable, clearing each graduated patch from **Not yet specified** so it lives only as its new ticket. If the answer reveals a ticket — this one or another — sits beyond the destination, **rule it out of scope** rather than resolving it on the route. If the decision invalidates other parts of the map, update or delete those tickets.

The user may run unblocked tickets in parallel, so expect other sessions to be editing `wayfinder/` concurrently — re-read a ticket's frontmatter just before claiming it.
