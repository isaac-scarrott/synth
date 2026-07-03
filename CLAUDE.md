# Synth

AI-first, Mac-native dev environment. Speed first (chained keyboard shortcuts must feel instant),
simple at a glance, progressive disclosure to go deeper.

`FEATURES.md` is the append-only features ledger — read it for what's locked in and why. When a
feature is decided, proactively append a dated entry (never edit or delete existing ones).

## Designs

- `big-picture-design.html` — the full design; everything at a glance.
- `working.html` — the focused "working" view.

**Invariant:** `working.html` is always a strict subset of `big-picture-design.html`. The two files
are byte-identical except (a) the `<title>` and (b) big-picture carries extra session rows (browser,
simulator) that working omits. Any shell / interaction / style change must land in **both**, so
`diff working.html big-picture-design.html` only ever shows the title + those extra sessions.
