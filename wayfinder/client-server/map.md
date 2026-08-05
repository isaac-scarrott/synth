# Client/server split

## Destination

An **architecture spec + handoff brief** for splitting Synth into a local server (owning sessions,
PTYs, state, orchestration) and clients (rendering + input), the Swift app being client #1.
Boundary, protocol, and migration order decided; implementation is a later effort.

## Notes

**Domain.** Synth today is one Swift app owning everything. This effort designs the split: a local
server the UI drives over a socket, so any client — the Swift app now, mobile/sidecars later — can
drive Synth without Synth knowing who's calling.

**Glossary:**

- **Server** — the local process owning everything that *is* the session: PTYs, session/branch/
  worktree state, orchestration, per-branch layouts (as data).
- **Client** — a renderer + input source. Owns only its transient viewpoint (what it renders,
  focus). The Swift app is the first and, day 1, only real client.
- **Sidecar** — any external app (Teams bridge, Datadog webhook receiver, public endpoint) that
  calls the server like any other client. Synth never knows its caller.
- **View state** — per-client: current branch/session being rendered, focus. Never shared.
- **Session I/O** — inherently shared: one PTY, one byte stream; all attached clients see the same
  bytes and may write.

**Locked decisions (charting session, 2026-08-05):**

- **Scope: local split only.** Mobile, public endpoint, Teams approvals, cloud queue, Datadog are
  design *constraints* (the API must not preclude them), not designs. The public endpoint is never
  Synth's — it's a sidecar.
- **Boundary: server owns the session, client owns the glass.** PTYs live server-side, bytes stream
  to clients (tmux / VS Code architecture). Acceptance criterion for the brief: *keystroke feels
  native, verified* — localhost transport is microseconds; the risk is bulk throughput (framing,
  chunking, flow control are hard requirements, not reasons to move the boundary).
- **Lifecycle: app-supervised server** (spawned by and dies with the Swift app), made portable to
  detached/launchd later by three protocol rules: (1) discovery via well-known socket path, never
  parent inheritance; (2) version handshake at connect with a restart path; (3) server state lives
  in its own home, never the app container, and the server never assumes the app's lifetime.
- **Multi-client: session I/O shared, view state per-client.** Server owns all durable truth
  including per-branch layouts (as data; desktop-class clients consume them, a phone ignores them).
  No primary/observer split — writes are a capability question, not the architecture.
- **First client: the Swift app.** No new UI built. The honesty guard is the **scripts litmus**:
  every operation drivable from the command line over the wire; the Swift app gets no privileged
  in-process path.
- **Runtime: TypeScript on Node** (VS Code-server precedent: node-pty + socket streaming; repo
  already runs Node in `mcp/`). Bun contingent on the PTY spike
  ([003](tickets/003-pty-streaming-spike.md)).

**Plan, don't do** (wayfinder default, no override): tickets resolve decisions; the deliverable is
the brief, not the migration.

## Decisions so far

<!-- one line per closed ticket; follow the link for the detail -->

## Not yet specified

- How non-PTY sessions (browser, simulator) traverse the API — they're sessions the sidebar renders
  but not byte streams; awaits the [current-architecture inventory](tickets/001-current-architecture-inventory.md).
- Local permissioning between sidecars and the server (even on localhost, does a caller present a
  token? are some operations gated?) — sharpens once the API surface exists.
- Server-side persistence format for branch layouts + migration off the app's current storage.
- Notifications / approval prompts over the wire (the future Teams-approval flow hangs on approvals
  being API events, not app-internal UI) — awaits the inventory and API-surface work.

## Out of scope

- The public endpoint — a sidecar app's problem, never Synth's.
- The Teams / Datadog sidecars themselves; the cloud queue / offline execution story; any mobile app.
- The implementation of the split — that's what the brief hands off.
