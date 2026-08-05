---
id: 003
title: PTY streaming latency spike
type: prototype
status: open
claimed_by:
blocked_by: []
---

## Question

Prove (or kill) the locked boundary empirically: server-owned PTYs streamed over a localhost
socket, with the human judging feel. Cheapest possible rig — a Node process with node-pty +
a WebSocket / Unix-socket stream, a throwaway client rendering into a terminal widget:

- **Keystroke feel**: typing through the rig vs a native terminal, judged by hand (the map's
  acceptance criterion: *keystroke feels native*).
- **Bulk throughput**: a command spewing megabytes (`yes`, a big build log) — does the UI stutter?
  What framing/chunking/backpressure does the spec need to mandate?
- **Node vs Bun**: does node-pty (or an equivalent) actually work on Bun today? Pick the runtime;
  the map's Notes carry Node as the default.

Prototype is disposable evidence — save under assets, record the numbers and the felt verdict.

## Resolution
