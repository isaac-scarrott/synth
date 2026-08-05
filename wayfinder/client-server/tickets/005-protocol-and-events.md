---
id: 005
title: Protocol & event model
type: grilling
status: open
claimed_by:
blocked_by: [003, 004]
---

## Question

The wire contract. Informed by the spike's framing findings ([003](003-pty-streaming-spike.md))
and shaped around the surface ([004](004-v1-api-surface.md)):

- Transport: Unix domain socket vs loopback TCP; one connection or control + per-session streams.
- Framing: JSON-RPC vs bespoke; binary side-channel for PTY bytes vs base64-in-JSON (spike data
  decides).
- Server→client push: how state changes and notifications reach clients (the event model).
- The three lifecycle-portability rules made concrete: socket path convention, version-handshake
  shape and restart path, server state home.
- Whether local callers present any credential (graduates the permissioning fog note if the answer
  is sharp by then).

## Resolution
