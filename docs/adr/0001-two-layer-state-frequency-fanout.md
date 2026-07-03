# Two-layer state: event bus (local, high-frequency) vs global store (observed, low-frequency)

Synth is event-driven and terminal-heavy, so the obvious "single global store, all events mutate it,
UI reacts" design would flood the store with the PTY firehose (bytes, cursor moves, scrollback —
hundreds of events/sec/session) and die on diffing cost. We instead split state into two layers keyed
on **frequency and fan-out**.

- **Event bus** carries raw, high-frequency events to *exactly the one local owner* that consumes
  them (PTY bytes → that session's ghostty surface). This traffic never touches the global store.
- **Global store** holds only low-frequency **derived facts** that ≥2 independent views need, or that
  must outlive any single view: tree structure, per-session derived status, selection, layout,
  restoration data.
- Each session's **supervisor** is the designated transducer between the layers — it watches the
  firehose locally and emits only the occasional derived status fact onto the bus, which is what
  mutates the store.

The rule for "does this belong in the global store?": *would a second, unrelated view need to react
to this, or must it survive this view being destroyed?* No to both → local listener, off the store.

This is hard to reverse (it shapes every session, the supervisor contract, and the store schema) and
deliberately rejects the simpler single-store default for a specific performance reason, so it is
recorded here.
