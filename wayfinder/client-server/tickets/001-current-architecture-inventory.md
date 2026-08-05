---
id: 001
title: Current-architecture inventory
type: research
status: open
claimed_by:
blocked_by: []
---

## Question

What does the Swift app actually own today? The split can't be specced against a foggy current
state ("I think it runs the server"). Read `app/Sources/Synth/` and `mcp/` and produce an
inventory in this ticket's assets directory covering:

- Where PTYs / terminal sessions are created, owned, and rendered.
- Every kind of session (Claude Code, opencode, dev-server logs, plain terminal, browser,
  simulator) and what "owning" each one means — which are byte streams, which are something else.
- Git worktree / branch / workspace state: who creates, tracks, persists it.
- The MCP servers in `mcp/` (`server.mjs`, `app-server.mjs`, `simulator-server.mjs`): what they
  already expose, how the app talks to them — is part of the "server" already extracted?
- All persisted state and where it lives (UserDefaults, files, the app container).
- The full set of operations the UI can perform (the ⌘K command surface is a good index) — this
  becomes the raw material for the v1 API surface.

## Resolution
