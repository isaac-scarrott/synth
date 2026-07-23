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

## 2026-07-23: the Tabs view mode amends "one session per pane"

An experimental **Tabs** view mode (off by default, one global Settings toggle) changes how the same
tree is *presented*, not what it is. Two things move: the sidebar drops to **two deep** (sessions
leave the tree — the branch is the deepest row, carrying only its roll-up), and each pane draws a
**strip of tabs**, one per session it hosts. A tab is a session's handle, nothing more (`CONTEXT.md`
carries the term); the flag is presentation-only, so it flips instantly and losslessly with no
migration — the store is `branch → pane-tree → sessions` either way.

**The one invariant that genuinely changes.** This ADR's *"a pane hosts exactly one session"* becomes
**"a pane hosts a strip of ≥1 sessions, exactly one active."** Everything else in the spine survives
verbatim: still exactly one active pane, still no *empty* pane (a strip always holds at least one
session), still `pruneLayout` on the last tab leaving a pane — closing the last tab collapses the pane
and reflows its sibling, and closing the last tab of the *last* pane drops the branch to **dormant**
(worktree kept), which is just the zero-session case the taxonomy already names. `openSessionID`
keeps mirroring the active leaf's *active tab*, so notifications, ⌘K, the header and the "you are
here" pill read it untouched.

**A session lives in exactly one strip at a time — split *moves*, never duplicates.** This is the
load-bearing divergence from editor tabs (Cursor/VSCode open one file in two split groups). A session
is a live surface rendering into its own `NSView` (ADR-0009/0011); it cannot be in two panes at once.
So `⌘⇧arrow` *sends* the active tab toward the arrow — into the neighbour pane's strip if one exists
there, else a new split — and the existing tree ops (`splitPane`, `removeLeaf`, `pruneLayout`) carry
it with no new primitive. Tab-switch is a new, cheap op (move the active-tab pointer + the mirror,
never re-mount a surface), keyed `⌘⇧[`/`⌘⇧]` (panes keep `⌘1–9`); `⌘W` closes the active tab.

**Nothing is pinned.** The agent is a peer tab, orderable and closable like any other — the explicit
rejection of Cursor's fixed chat rail. An agent-opened browser lands as a tab in its *owner's* pane
strip wearing the owner-mark, with an unread dot and no focus-steal (the `belongs-to` relation is
unchanged; only its display moves off the sidebar row onto the tab).

*Rejected:* a separate persisted tab-group model beside the pane-tree — it would make the toggle a
migration and forfeit "flip it off and the sessions are back in the tree." *Rejected:* refusing to
close the last tab (traps you in a session; Close is a session verb and must always work) and hiding
the strip until a second tab exists (the strip appearing/disappearing is a layout jump, and the
new-tab affordance would hide exactly when a newcomer needs it). The strip shows even for a lone tab.

Status: **experimental, unbuilt in the native app.** Landing first in both design files
(`working.html` + `big-picture-design.html`, subset invariant held) behind the toggle; the native
port amends the `Layout` invariant above rather than forking a second layout path.
