---
name: port-design-html
description: Port a change that has landed in design.html into the native SwiftUI Synth app (app/Sources/Synth/) and verify it by driving the real app. Fans out sub-agents in isolated git worktrees to implement independent slices concurrently, then integrates, builds, and drives the app to prove it works. Use when the user says the design in design.html is ready and wants it implemented/built into the native app, when porting a design.html change to the app, or invokes /port-design-html.
---

# Port design.html → native app

`design.html` is the source of truth for the design; the native app under `app/` mirrors it.
This skill takes a change that is already in `design.html` and lands it in the app, verified.
This skill only *reads* the HTML — never edit it here.

## Concurrency model (the safety rule)

The SwiftUI files (`Store`, `Sidebar`, `Palette`, …) are tightly coupled — two agents editing the
same file in the same tree corrupts the build. So **every implementer works in its own git worktree**
(via the `create-worktree` skill). Parallelism scales with the number of *independent* slices:
one worktree + one sub-agent per slice, integrated on the main tree. A single coupled change = one
worktree, one implementer. Only ever parallelize freely for **read-only** work (understanding,
fidelity audits) and **own-instance** verification.

The machine is contested (parallel agents + several Synth instances). **Kill only your own PID.**
Trust only `swift build` — SourceKit shows false "cannot find type/module" errors; ignore them.

## Workflow

1. **Scope the change (intent + diff + audit).** In the main tree, gather all three:
   - **Intent** — what the user/conversation said the change is.
   - **Diff** — `git log -p -- design.html` since the app last synced (find the relevant commits;
     before the merge the design lived in `working.html` + `big-picture-design.html`, so older
     history is under those paths).
   - **Audit** — spawn parallel read-only sub-agents (Explore) to compare `design.html` against the
     current app and list gaps.
   Serve the reference: `python3 -m http.server 8912` (repo root) → `http://localhost:8912/design.html`.
   Produce a **slice list**: independent units of work, each naming the files it will touch.

2. **Isolate.** For each slice, invoke the **`create-worktree` skill** to make `.worktree/<slice>`.
   (One slice → one worktree. N independent slices → N worktrees.)

3. **Implement (concurrent across slices).** Spawn one sub-agent per slice, each told to work **only
   inside its worktree** (`.worktree/<slice>/app/Sources/Synth`). Each: makes the minimal change,
   `swift build` until clean, self-verifies by driving its own instance (see TESTING.md), commits on
   its branch. Give each sub-agent the intent, the relevant `design.html` markup/CSS, and TESTING.md.

4. **Integrate.** On the main working branch, merge each slice branch (`git merge <slice>`), resolve
   conflicts, then `swift build` the combined tree until it is clean.

5. **Verify the integrated app.** Drive the *real* built app and screenshot it, comparing against
   `design.html` served at :8912 — see [TESTING.md](TESTING.md). For anything nontrivial, also spawn
   an **independent** fidelity-audit sub-agent (static code-vs-spec, no GUI launching). Do not claim it
   works without a screenshot or captured output.

6. **Land.** Commit to `app/` (and `docs/` if the change warrants an ADR or ledger entry — a
   ledger entry goes in `docs/features/<date>.md` plus its index line in `FEATURES.md`; never touch
   the HTML). Fetch, then push to `main`. Remove the slice worktrees
   (`git worktree remove .worktree/<slice>`) and delete merged branches.

## Checklist before declaring done
- [ ] `swift build` on the integrated main tree prints `Build complete!` (0 errors).
- [ ] The change is visible in a screenshot of the running app and matches design.html.
- [ ] Only your own Synth PIDs were killed; slice worktrees cleaned up.
- [ ] Pushed to `main`; local == `origin/main`.

Detailed driving/screenshot technique and gotchas: [TESTING.md](TESTING.md).
