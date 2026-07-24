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

## 2026-07-23: the Tabs view mode — a single strip that mirrors the sidebar

An experimental **Tabs** view mode (off by default, one global Settings toggle) changes how the same
tree is *presented*, not what it is. Two things move: the sidebar drops to **two deep** (sessions
leave the tree — the branch is the deepest row, carrying only its roll-up), and the content surface
gains **one tab strip** listing the branch's sessions. A tab is a session's handle, nothing more
(`CONTEXT.md` carries the term); the flag is presentation-only, so it flips instantly and losslessly
with no migration — the store is `branch → pane-tree → sessions` either way, and this ADR's spine,
including *"a pane hosts exactly one session,"* is **unchanged**.

**One strip per branch, not one per pane — the split is a bonded cluster of tabs, not a second
strip.** This is the shape decided after a first pass gave every pane its own strip: a split must read
as *one* set of tabs, exactly as the sidebar already shows a split (ADR-0005/012's echo band — the
member rows pull together into a bonded band). So the single strip lists all of the branch's sessions;
the sessions in the on-screen split bond into a contiguous **cluster** at the position of their first
member, and the rest are lone tabs. The strip is a *derived mirror* of the branch's sessions + the
durable layout's membership — the horizontal twin of `renderSidebarEcho`, built the same way, so the
sidebar (tabs-off) and the tab strip (tabs-on) are the same idea drawn on different edges.

**Selecting a tab is the existing open/stash behaviour, verbatim.** Clicking a lone tab full-screens
that session (`openSession` stashes the durable split, which keeps showing as a bonded cluster in the
strip — the band persists behind a transient full-screen, ADR-0014); clicking a cluster member returns
to the split with it active. Splitting stays the existing gesture — `⌘⇧arrow` / the split picker adds a
session to the layout, which *is* bonding it into the cluster; `⌘⇧U` unsplits it back to a lone tab. No
"eject a tab from a strip," no per-pane tab machinery, no new persisted structure. `openSessionID` is
still the one "you are here," now also the strip's active tab.

**Keyboard.** `⌘⇧[`/`⌘⇧]` and `⌃⇥`/`⌃⇧⇥` step through the strip (the branch's sessions, via
`openSession`); `⌘1–9` selects the Nth tab; `⌘W` closes the active tab; `⌘⇧arrow`/`⌘⇧U` split/unsplit
as above; panes keep `⌘1–9`-as-pane and `⌘⌥arrows` while a split is on screen. Closing the last
session drops the branch to **dormant** (worktree kept) — the zero-session case the taxonomy names.

**Nothing is pinned.** The agent is a peer tab, orderable and closable like any other — the explicit
rejection of Cursor's fixed chat rail. An agent-opened browser is a tab wearing its owner-mark with an
unread dot, no focus-steal (the `belongs-to` relation is unchanged; only its display moves onto a tab).

*Rejected:* **a tab strip per pane** (the first pass) — two sets of tabs on a split contradicts "a
single set of tabs," and drifts from the sidebar, which shows a split as one bonded band; the single
strip restores that symmetry. *Rejected:* collapsing a split into one composite tab (you lose the
jump-straight-to-a-member the sidebar gives). *Rejected:* a separate persisted tab model beside the
pane-tree (would make the toggle a migration). The strip shows even for a lone tab, so it never
appears/disappears.

Status: **experimental, unbuilt in the native app.** Landing first in both design files
(`working.html` + `big-picture-design.html`, subset invariant held) behind the toggle; the native
port renders the same strip from the existing layout rather than forking a second layout path.
