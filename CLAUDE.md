# Synth

AI-first, Mac-native dev environment. Speed first (chained keyboard shortcuts must feel instant),
simple at a glance, progressive disclosure to go deeper.

`FEATURES.md` is the index of the append-only features ledger — skim it for what's locked in; full
entries (the why) live in `docs/features/<YYYY-MM-DD>.md`. When a feature is decided, proactively
append a dated entry to today's day file and add its one-line index entry to `FEATURES.md` (never
edit or delete existing entries).

## Design

- `design.html` — the single HTML design mock, source of truth for the native app under `app/`.
  It only shows session kinds the app actually supports. (It replaced the former
  `working.html` / `big-picture-design.html` pair — older design history lives under those paths.)
