# trigger-gateway (spike)

The first Synth **plugin** (ADR-0014): a single Node process that turns outside events into
Synth *triggers*. Three sources, one shape:

| source  | transport                                   | arrives as                        |
|---------|---------------------------------------------|-----------------------------------|
| Teams   | Bot Framework messaging endpoint (`/api/messages`) | every post in channels the bot is in |
| Datadog | webhook (`/hooks/datadog`, shared secret)   | monitor alert with custom payload |
| cron    | in-process scheduler                        | a configured prompt on an interval |

Each trigger asks Synth — over the control socket, via `app.worktreeCreate` — to cut a
`trigger/<slug>` worktree and seed one Claude session with a security-preambled brief. The
approval lives in Synth's ⌘K (nothing runs until the user accepts); the brief states the
prompt's external origin and fences the reported content as data.

## Run

```sh
cp config.example.json config.json   # edit repo path + secrets
node gateway.mjs
```

Requires the Synth app running and managing `repo` (adopt it via ⌘K → New worktree if not).

## Try it

```sh
curl -s -X POST 127.0.0.1:8787/hooks/datadog \
  -H 'x-gateway-secret: change-me' -H 'content-type: application/json' \
  -d '{"title":"p95 above 800ms on /v1/checkout","body":"Monitor crossed threshold for 15m.","link":"https://app.datadoghq.eu/monitors/123"}'
```

Synth pops the approval in ⌘K; approve and the worktree + seeded Claude session appear.

## Wiring the real sources

- **Datadog**: Integrations → Webhooks → URL `https://<tunnel-host>/hooks/datadog`, custom
  payload `{"title":"$EVENT_TITLE","body":"$EVENT_MSG","link":"$LINK","snapshot":"$SNAPSHOT","org":"$ORG_NAME"}`,
  custom header `x-gateway-secret`. Add `@webhook-<name>` to the monitor message.
- **Teams**: Entra app registration + Azure Bot (F0) pointing at `https://<tunnel-host>/api/messages`;
  Teams app manifest declaring the bot with RSC permission `ChannelMessage.Read.Group`
  (team-owner consent — the bot then receives *every* channel post, not just @mentions).
- **Tunnel**: Cloudflare Tunnel or Tailscale Funnel to `127.0.0.1:8787` — outbound-only,
  nothing listens on the open internet.

## Spike gaps (before this is a real plugin)

- **No Bot Framework JWT validation** on `/api/messages` — do not put the Teams route on a
  tunnel until requests are verified against Microsoft's OpenID keys.
- **No image download**: pasted Teams images need Graph `hostedContents/$value` with an app
  token; the brief currently just states the attachment count.
- **No reply path**: the plan is a thread-scoped reply tool (Bot Framework proactive reply to
  `conversation.id = "<channelId>;messageid=<parentId>"`) exposed to the seeded session, plus
  lifecycle acks posted by the gateway itself.
- **Rides `app.worktreeCreate`**: the dedicated `app.triggerEnqueue` verb (richer ⌘K card,
  per-source auto-run policy) doesn't exist natively yet.
- No dedupe/rate limit, and cron is fixed-interval only.
