---
status: accepted (realised in the first native build)
---

# @Observable store + small typed event bus, supervisors as off-main actors

The global store is a main-actor `@Observable` object (Swift Observation framework) holding the
derived facts (tree, per-session status, selection, layout). A small hand-rolled typed event bus —
an enum of events delivered via async stream / subscription — carries facts to subscribers. Each
session's supervisor runs as an off-main actor, does its firehose processing off the main thread, and
posts derived facts that are applied to the store on the main actor.

Rejected TCA: its formal reducer/effect model buys testability and pipeline discipline, but ADR-0001
already imposes that discipline, and TCA's ceremony, dependency weight, and steeper agent-navigability
cut against the ethos. The self-test requirement (see the forthcoming command/snapshot ADR) is served
by an explicit command bus + state-snapshot surface, not by adopting TCA. Rejected a fully
actor-isolated store with a projection layer: `@Observable`-on-main already gives cheap rendering
because the firehose never reaches it, so the extra projection/sync layer and its latency aren't
justified.

Provisional: selected by the agent during a grill while the user was away. Revisit before writing
implementation code.
