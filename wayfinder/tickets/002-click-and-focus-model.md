---
id: 002
title: Selection & focus model with a split open
type: grilling
status: closed
claimed_by: isaac
blocked_by: []
---

## Question

Once a layout shows more than one pane, what does **clicking a session in the sidebar** do, and
which pane is **active**?

- Clicking a sidebar session with a split open: fill the *focused* pane, replace the *whole* split
  with that session full-screen, or open it as a *new* pane? (There's already precedent: today a
  click renders the session full-screen and hands focus to the content pane.)
- Which pane is "focused/active", and how is that shown? How does clicking *into* a pane move focus?
- How does this reconcile with the existing focus split — `⌘0` sidebar / `⌘1` session, and
  "click follows focus" (see FEATURES ledger)? Is there now a notion of "the focused pane" that
  `⌘1` targets?
- Does the sidebar highlight *all* sessions currently visible in panes, or just one "active" one?

HITL grilling — the answers hang on how the user actually navigates. Blocks the build.

## Resolution

There is **always exactly one active pane** (in the single-pane case it's just the whole surface).
Everything below hangs off that.

**Clicking a sidebar session — "take me to it".** A plain click is never a split gesture; splitting
stays drag-only.

- The session is **already visible** in a pane → **focus that pane**. Layout untouched, active pane
  moves to it.
- The session is **not on screen** → **collapse the split and show it full-screen** — today's exact
  behaviour. A plain click always means "go single" unless the thing is already up.

**Which pane is active, and how focus moves.**

- **Clicking into a pane's body** makes that pane active.
- **After a drag-split** (drop a session on a pane edge / the outer rim), focus **follows the
  newly-dropped pane** — you land ready to type/scroll in the thing you just placed.
- The active-pane cue in the **content area** (border / header treatment) is [ticket 004](004-pane-chrome-and-states.md)'s
  to draw; this ticket only fixes *which* pane is active and *when* it changes.

**`⌘0` / `⌘1` reconciliation.** The two-focusable-halves model holds unchanged: **`⌘0` → sidebar,
`⌘1` → the active pane** (formerly "the open session", now "the active pane"). No new binding is
invented here; finer pane-to-pane keyboard movement (cycling, directional) is deferred to
[the keybinding ticket](007-keybinding-scheme.md) — keybindings are designed only after the mouse
model, per the map.

**Sidebar reflection — the sidebar always mirrors the layout.** An on-screen split renders its
members **side-by-side in the sidebar** (the visual is [ticket 003](003-sidebar-grouping.md)'s
prototype). Being *in that side-by-side pair* is the "this is on screen" signal — there is **no**
separate visible-but-inactive glow. Only the **active** session carries the accent, and it's the
**existing `.session--open` treatment, unchanged** (`rgba(--accent-rgb,0.10)` tint + bold
`--ink-open` name, working.html:269-270) — just now laid out side-by-side with its pane-mate.

**Consequence for [ticket 003](003-sidebar-grouping.md):** the sidebar pairing is **automatic**, not
a separate opt-in — any on-screen split auto-pairs those sessions in the sidebar, so the sidebar is a
live map of the layout. The "drag a session onto another *in the sidebar*" secondary gesture is
therefore **just a second route to create the same split** (from the sidebar side rather than the
content edge), producing the identical paired rendering. 003 prototypes how that side-by-side (and
deeper nested trees) actually looks.
