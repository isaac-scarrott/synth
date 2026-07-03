---
status: accepted (realised in the first native build)
---

# SwiftUI-first hybrid UI, with AppKit escape hatches for hot surfaces

The shell, sidebar tree, popovers, modals, and command palette are built in SwiftUI with `@Observable`
state. AppKit is used only through `NSViewRepresentable`, per-surface, where genuinely warranted:
hosting the ghostty Metal terminal surface (a C/Metal view that must be wrapped regardless) and any
surface proven hot by measurement.

Rationale: the "maintainable, great patterns, AI-navigable" ethos favours SwiftUI's declarative
brevity, and ADR-0001 removes the usual perf objection — because the firehose never enters the
observed store, the tree only diffs on rare derived-status changes, which SwiftUI handles cheaply.
Keeping a designed-in AppKit escape hatch (rejecting *pure* SwiftUI) means no surface is trapped when
it hits a diffing/layout ceiling; choosing SwiftUI-first (rejecting *AppKit-first*) avoids the
boilerplate and slower iteration that cut against build-speed and agent-navigability.

Provisional: selected by the agent during a grill while the user was away. Revisit before writing
implementation code.
