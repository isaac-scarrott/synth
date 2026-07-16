---
id: 005
title: Layout persistence & navigation behaviour
type: grilling
status: closed
claimed_by: isaac
blocked_by: []
---

## Question

Layout is transient and unowned (decided while charting) — but "transient" still has to answer what
happens on navigation. Pin the edges:

- You have a 3-pane split up. You switch **branch** in the sidebar. Does the split stay, collapse to
  one session, or something else? Same question for switching **workspace**.
- Does the arrangement survive an **app restart**, or is a fresh launch always single-pane?
  (Out-of-scope draft says no disk persistence — confirm or overturn.)
- If a session shown in a pane is **deleted/closed** from the sidebar, what happens to its pane?
- Is there ever more than one layout alive at once (e.g. per branch you last visited), or is there
  strictly **one** current arrangement, full stop?

HITL grilling. The user leaned hard on "just the current arrangement", so the likely answer is
minimal/transient — but the navigation edges must be explicit before the build. Blocks the build.

## Resolution

**Layout is owned by the branch, persisted to disk, and sticky. Navigation is tmux-style.**
This overturns the charting stance that a layout is unowned/transient — the branch owns it and it
survives restart.

- **Scope unit = the branch.** A branch owns exactly one remembered layout (its pane arrangement).
  Many layouts are alive at once — one per branch you've split. The **workspace owns no layout of its
  own** (workspace → branches → sessions); switching workspace lands you on a branch there and restores
  *that branch's* layout, so **workspace-switch reduces entirely to branch-switch**. Persistence is
  keyed by branch identity.

- **Switching branch** swaps to the target branch's own remembered layout (single-pane if it was never
  split); switching back restores the previous branch's split intact.

- **Persisted to disk.** Per-branch layouts survive quit/relaunch — reopen Synth and each branch is
  arranged as you left it. Overturns the out-of-scope "no disk persistence" draft. In `working.html`
  this is *simulated* (in-memory / `localStorage` across reload); genuine on-disk serialization is a
  spec point the **handoff brief (008)** carries, since the native impl is the next effort, not this one.

- **Sticky split + tmux navigation.** A branch's split is its durable layout; viewing a single session
  full-screen is a *transient* view that does **not** tear the split down — the model is switching tmux
  windows. This needs **no new rule** — it falls straight out of 002: clicking a session that **is** a
  split member focuses its pane (you're in the split); clicking a **non-member** session full-screens
  it while the split stays remembered underneath; clicking **any member** returns you to the split. The
  keyboard toggle between the split and a full-screened session (⌘1 semantics while full-screen) is
  deferred to **007**.

- **Session removed → collapse & reflow.** Deleting/closing a session that's live in a pane makes the
  pane vanish; siblings grow to absorb the space (tree reflow per 001); a 2-pane split collapses to one
  full-screen pane. **No confirmation guard** — speed-first. A persisted layout that references a
  now-missing session on relaunch takes the same collapse path (consistent with 004's no-empty-pane rule).
