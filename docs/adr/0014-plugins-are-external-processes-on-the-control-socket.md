# Plugins are external processes on the control-socket API

Synth needs work to arrive from outside the app: a Teams thread where anyone in the workspace
reports a bug, a Datadog alert, a Monday-morning schedule. Each of those is a real integration with
its own credentials, its own transport and its own audience — and none of them belongs in a
Mac app whose stated ethos is *simple at a glance*. The instinct this ADR locks in: the app does
not grow integrations, it grows **one seam**, and integrations are **plugins** — separate
processes the user installs, configures and can remove without the app changing shape.

The seam already exists. The bundled MCP servers (`mcp/shared.mjs`) discover a live Synth via
`~/Library/Application Support/Synth/instances/*.json` and speak one-line JSON verbs over
`/tmp/synth-ctl-<pid>.sock`, and `app.worktreeCreate` (2026-07-13) proved the critical shape: an
**external process** asks for a mutation, the **app** owns the approval (a ⌘K confirm frame, a
4-minute window, the user's answer as the result), and an approved ask can hand work to a fresh
agent session (`seedAgent`). A plugin is exactly that caller, minus the agent in the middle.

## The shape

- **A plugin is a process, not a bundle of app code.** It runs outside Synth (today: launched by
  the user or launchd; later: supervised by Synth), holds its own credentials, and talks to the
  app only through the control socket. The bundled MCP servers are retroactively the first two
  occupants of this seam; a plugin differs only in who drives it (the outside world, not an agent).
- **The control socket becomes a versioned API.** Verbs gain a `v` field; unknown-verb and
  unknown-version answers are explicit errors, so a plugin built against tomorrow's Synth fails
  loudly against today's. The existing verbs keep their wire shape.
- **Per-plugin permission, granted in the app.** Every mutating verb stays approval-gated in Synth
  (the `app.worktreeCreate` stance: "approval in the app, not the agent"). A plugin's standing
  capabilities — which verbs it may call at all, and any per-source auto-run policy — live in
  Settings → Plugins, ship **off** by default, and *disabled means removed*: a disallowed plugin
  gets a refusal on connect, not a silent no-op. This is the MCP-servers toggle pattern, one level
  up.
- **Triggers are the first plugin-facing noun.** A *trigger* is work arriving from outside,
  normalised to one shape — source, author, title, body, images, a reply reference, a policy —
  and enqueued by a plugin. Pending triggers surface as notification-deck cards and a ⌘K
  Triggers frame (never a modal, never a sidebar row: the tree shows work that *is*, the deck
  shows *asks*). Accept cuts a worktree off the repo head and seeds one Claude session with the
  brief; dismiss tells the source thread. The dedicated verb is `app.triggerEnqueue`; until it
  lands natively, the trigger-gateway plugin rides `app.worktreeCreate`'s approval + handoff,
  which loses only the richer card copy, not the security model.

## What a trigger run is allowed to be

A trigger's prompt is **untrusted input** — the same class of risk as ADR-0011's page-controlled
strings, which must never reach a login shell. The run therefore differs from a user-started
session:

- **Native sandbox + permissions, not Docker** (decided for now): the seeded Claude session runs
  headless with Claude Code's bash sandbox (filesystem + network domain allowlists), an explicit
  tool allowlist, deny rules on destructive commands, and a preamble stating the prompt's external
  origin. Container isolation stays open as a later hardening step; nothing in the seam assumes
  its absence.
- **Nothing may wait on a TTY.** Auto-approve suppresses `permission.asked` (the documented sharp
  edge from the OpenCode integration plan), and a fresh worktree's Claude stalls on the
  trust-this-folder prompt — so trigger worktrees are pre-trusted at creation and interactive
  questions are denied outright. A trigger run finishes or fails; it never hangs.
- **Replies are scoped by construction.** The plugin exposes the reply path (e.g. a Teams thread)
  as a tool bound to the originating thread only — the agent can report progress and results, and
  can address nothing else.

## Considered and set aside

- **Full backend/frontend split** (Synth-as-server, the app as a client): buys headless Synth and
  remote frontends, not plugins — everything above needs only the socket. Recorded as a possible
  future ADR; nothing here forecloses it, since plugins already treat the app as a server.
- **In-app integrations** (a Teams pane in Settings): every integration added to the app is UI,
  credentials and failure modes the app carries for everyone who never uses it.
- **Anthropic Managed Agents** for trigger runs: strongest isolation, but the session leaves the
  machine — no live Synth row, no synth-browser recording, repo access by push/pull. Wrong default
  for a tool whose product is watching your agents work; still a candidate for a "run remotely"
  policy later.

## Consequences

- The first real plugin is the **trigger gateway** (`plugins/trigger-gateway/`): one Node process,
  three sources — a Teams bot (RSC `ChannelMessage.Read.Group`, so it sees every channel post with
  team-owner consent only, replying in-thread as the bot), Datadog webhooks (shared-secret HTTPS
  POST), and local cron — all normalised to triggers. Teams/Datadog reach the Mac through an
  outbound tunnel (Cloudflare Tunnel / Tailscale Funnel); nothing listens on the open internet.
- Per-source policy: default is approval (the deck card + ⌘K review); a source the user trusts
  can be flipped to auto-run. Auto-run still respects the sandbox rules above.
- The control-socket verbs need a version field and a refusal for unregistered plugins before the
  gateway ships beyond spike quality.
- CONTEXT.md gains the nouns **Plugin** and **Trigger**.
