# Session layout is a per-branch binary pane tree with sticky full-screen

Synth's content surface used to render exactly one session. It is now a **layout**: a splittable
arrangement of several sessions at once — side by side or stacked, nested arbitrarily — so a branch
can show its dev-server logs beside the agent driving them beside the browser they're building. This
ADR records the primitive that makes that possible, because none of the existing ADRs capture it: a
**binary pane tree**, owned per branch, with full-screen as a *transient stash* rather than a
destructive edit. It supersedes nothing; it extends the model ADR-0003 (observable store), ADR-0010
(persistence), ADR-0009/0011 (terminal/browser surfaces) and ADR-0013 (taxonomy) already established.

**The layout is a binary tree, and the single pane is the degenerate case.** A node is either a
**leaf** binding exactly one session (`PaneNode.sessionID`) — or a still-materialising branch's setup
skeleton, which counts as bound — or a **split** of two children (`a`, `b`) divided along `dir`
(`.row` side-by-side / `.col` stacked), where `a` holds `split` of the axis. A lone leaf is today's
single-session view, so **every existing single-session behaviour is the one-leaf case of the same
code path** — not a parallel mode with its own bugs. This is the mock's `layout` node shape
(`working.html`), ported verbatim. The whole gesture and chord vocabulary funnels through a small set
of tree ops (`splitPane`, `splitRoot`, `removeLeaf`, `unsplitSession`, `pruneLayout`, `setActivePane`),
so the mouse and keyboard create-routes stay one behaviour rather than two implementations that drift.

**Invariants the tree must always hold.** Exactly **one active pane** (the copper ring, shown only
inside a split). A pane **always** hosts exactly one session — **no empty pane, ever**: splits are
born filled, and closing or deleting a session **collapses its pane and reflows the sibling** into the
freed space (`pruneLayout`) rather than leaving a hole. A hard **360×240 min-pane floor** bounds both
drops and resizes. These are enforced centrally in the store so no call site can violate them.

**`openSessionID` survives as the active pane's mirror.** Rather than rewrite every subsystem that
reads "the one open session" (notifications, the ⌘K context, the header, the sidebar "you are here"),
`openSessionID`/`openSetupBranchID` are kept pointing at the active leaf by `syncActive`. The layout is
the source of truth for *what the content renders*; the mirror keeps the single-session machinery
working untouched. This is the mock's `openEl`-survives decision, and it is what let the spine land
without touching notifications, the palette, or the browser verbs.

**The tree is a reference-typed `@Observable`, mutated in place.** A subdivided leaf keeps its identity
and parent links (the mock mutates the node object in place), and each pane view observes its own leaf,
so a fraction change or a reparent re-renders **without tearing down live sibling surfaces**. This is
the load-bearing native constraint: N panes are **N concurrent live surfaces** — each terminal
(ADR-0009: libghostty supports multiple live instances) or browser (ADR-0011) rendering into its own
`NSView`, none stealing another's controls. Activating a pane is DOM-cheap: move the ring and the
mirror, never re-mount the surface. Verified by driving two live terminals side by side and switching
the active pane — both shells keep running across the switch.

**Layout is owned by the branch, and full-screen is sticky.** One remembered layout per branch, keyed
by `workspace‹NUL›branch` (a workspace owns no layout — workspace-switch reduces to branch-switch for
free). Full-screening a pane (zoom, or clicking a non-member session) is a **transient, tmux-window
view**: the durable split is *stashed*, not destroyed (`stashedSplit`), the sidebar keeps echoing it,
and clicking any member returns to it. Split-creating ops commit the current view as the new durable
by nulling the stash. The per-branch tree **persists to disk** under ADR-0010 (serialize dir / fraction
/ session identity per leaf, keyed by branch); on restore, a leaf whose session no longer resolves
takes the same collapse-&-reflow path as a live close — no empty pane on reload. That persistence and
the sticky-nav wiring land in their own slice (014) on top of this primitive; this ADR records the
primitive itself, which the spine (009) establishes.

## Status

Accepted. The spine (the tree model, multi-pane render, active-pane ring, and the collapse-on-missing
invariant) is implemented in `Layout.swift` + `ContentPane.swift` + the store. The gesture, resize,
sidebar-echo, unsplit, persistence, keybinding, and narrow-pane slices build on it without changing
the primitive.
