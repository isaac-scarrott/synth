# Synth

AI-first, Mac-native dev environment. Speed first (chained keyboard shortcuts must feel instant),
simple at a glance, progressive disclosure to go deeper.

`FEATURES.md` is the index of the append-only features ledger — skim it for what's locked in; full
entries (the why) live in `docs/features/<YYYY-MM-DD>.md`. When a feature is decided, proactively
append a dated entry to today's day file and add its one-line index entry to `FEATURES.md` (never
edit or delete existing entries).

## Designs

- `big-picture-design.html` — the full design; everything at a glance.
- `working.html` — the focused "working" view.

**Invariant:** `working.html` is always a strict subset of `big-picture-design.html`. The two files
are byte-identical except (a) the `<title>` and (b) big-picture carries extra session rows (browser,
simulator) that working omits. Any shell / interaction / style change must land in **both**, so
`diff working.html big-picture-design.html` only ever shows the title + those extra sessions.
