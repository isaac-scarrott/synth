# Synth

AI-first, Mac-native dev environment. Speed first (chained keyboard shortcuts must feel instant),
simple at a glance, progressive disclosure to go deeper.

`FEATURES.md` is the index of the append-only features ledger — skim it for what's locked in; full
entries (the why) live in `docs/features/<YYYY-MM-DD>.md`. When a feature is decided, proactively
append a dated entry to today's day file and add its one-line index entry to `FEATURES.md` (never
edit or delete existing entries).

## Failures

`Fault` (`app/Sources/Synth/Fault.swift`) is the only seam a caught failure goes through. It logs
locally on every channel, counts the failure in PostHog, and — for the two loud severities — says
it on screen through the notification deck the app already has. Never add a second toast system,
and never call `PostHogSDK` or `Analytics.capture` outside `Analytics.swift`.

- `Fault.note` — breadcrumb. `Fault.report` — counted, silent. `Fault.surface(say:)` — counted and
  said. All three are callable from any thread, including libghostty's C callbacks.
- **Non-PII is enforced by the type, not by review.** `details:` takes `[Detail]`, which has no
  free-string case. `evidence:` is a String that reaches the user's card and the local log only —
  `wireProps` cannot see it. If you could interpolate it, it stays on this machine.
- Severity picks the surface and nothing else. If the user did not just press something, and the
  thing is not permanently broken, it is `.degraded` or lower. A spine that spams is worse than the
  silence it replaced.
- `SYNTH_FAULT_STRICT=1` turns any `.failed` into a crash — set it in gates and tests.

**When to convert a `try?` or a bare `catch`:** only when its failure changes what a **later,
unconditional** code path does, and that path has no way to find out. `try? removeItem(tempFile)`
stays. `try? write(...)` followed by `return path` does not. There is no ticket to instrument the
remaining ~240 `try?` sites — most are correct, and deleting a correct one to satisfy a policy is a
regression with good intentions. The backlog is generated from production instead: the `fault`
event carries `surfaced`, so `surfaced=false` ranks what real people hit that Synth still doesn't
mention. Work that list, not an audit.

Full rationale: `docs/features/2026-09-07.md`. The 151 confirmed findings — twenty fixed, the
rest recorded and deliberately unscheduled — are in
`docs/research/silent-failure-audit-2026-09-07.md`, so nobody runs that sweep twice.

## Designs

- `working.html` — the design; the single source of truth for the shell, interactions and styles.
