# Synth

AI-first, Mac-native dev environment. Speed first (chained keyboard shortcuts must feel instant),
simple at a glance, progressive disclosure to go deeper.

`FEATURES.md` is the index of the append-only features ledger — skim it for what's locked in; full
entries (the why) live in `docs/features/<YYYY-MM-DD>.md`. When a feature is decided, proactively
append a dated entry to today's day file and add its one-line index entry to `FEATURES.md` (never
edit or delete existing entries).

## Failures

**Errors are caught at the doors work enters through, not at the call sites where they happen.**
A function that can fail says `throws`. Its caller says `try` and nothing else — no `try?`, no
local `catch`, no logging, no per-site fault. The error travels to the door it came in through and
is captured there, with the file and line it was actually raised at and the domain inferred from
that file. Adding error handling to new code costs zero lines; fixing a silent failure is usually
deleting a `?`.

- **The doors** (`Guarded.swift`): `Guarded.run` for a synchronous boundary, `Guarded.task` /
  `Guarded.mainTask` in place of `Task { }`, `Guarded.thread` in place of
  `Thread.detachNewThread`. A bare `Task` discards anything thrown inside it — never write one.
- **The spine** (`Fault.swift`): `Fault.note` is a breadcrumb, `Fault.report` is counted and
  silent, `Fault.surface(say:)` is counted and said. Use `surface` only where a leaf cannot
  throw — a SwiftUI body, a C callback — and only when the user's own action just failed.
- **Self-healing** (`Capability.swift`): most failures are states, not events, and a state can be
  retried. Conform something that can be down and brought back, and its owner calls
  `Capabilities.ensure(...)` rather than a one-shot start. Heals are bounded, silent while
  healing, one sentence when exhausted. **Only heal a specific, understood cause** — a socket
  file left by a dead pid, a device that went away. Retrying a deterministic failure is a hang
  with extra steps.
- **Severity decides the surface and nothing else.** If the user did not just press something,
  and the thing is not permanently broken, it is `.degraded` or lower. A spine that spams is
  worse than the silence it replaced.
- **Non-PII is enforced by the type.** `details:` takes `[Detail]` — numbers, `StaticString` keys
  typed in source, closed enums. `evidence:` is free text that reaches the user's card and the
  local log only; `wireProps` cannot see it. If you could interpolate it, it stays on this
  machine. Never call `PostHogSDK` or `Analytics.capture` outside `Analytics.swift`.
- `SYNTH_FAULT_STRICT=1` turns any `.failed` into a crash — set it in gates and tests.

**When to convert a `try?` or a bare `catch`:** only when its failure changes what a **later,
unconditional** code path does, and that path has no way to find out. `try? removeItem(tempFile)`
stays. `try? write(...)` followed by `return path` does not. There is no ticket to convert the
remaining sites wholesale — most are correct, and deleting a correct `try?` to satisfy a policy is
a regression with good intentions. The backlog comes from production instead: the `fault` event
carries `surfaced`, so `surfaced=false` ranks what real people hit that Synth still doesn't
mention. Work that list, not an audit.

**Prefer instrumenting a seam over a site.** `GitService.runChecked` reports non-zero exits once
and covers every git call in the app; that is the shape to look for before writing anything
per-site.

Full rationale: `docs/features/2026-09-07.md`. The 151-finding sweep behind it is in
`docs/research/silent-failure-audit-2026-09-07.md`, so nobody runs it twice.

## Designs

- `working.html` — the design; the single source of truth for the shell, interactions and styles.
