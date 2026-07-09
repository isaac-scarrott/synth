<!-- Spike run 2026-07-08 against OpenCode 1.17.7 (real binary ~/.opencode/bin/opencode), driving a live `opencode serve` + /event SSE with the opencode/claude-haiku-4-5 model. Resolves the 13 open questions in opencode-integration-plan.md. -->

# OpenCode port — spike results (verified against 1.17.7)

Every open question from `opencode-integration-plan.md` was resolved by driving a **real** headless
`opencode serve` (OpenAPI at `/doc`, event stream at `/event`) and, where needed, running live turns
with a free/cheap model. Confidence is **high** unless noted. Raw captures live in the session
scratchpad (`opencode-spike/`: `openapi.json`, `timeline*.json`, `driver*.mjs`).

## Verdict

**Green light — implement end-to-end.** No blocker survived. The two headline risks (Gap #1
auto-approve hiding needs-input; Gap #5 abort mis-flagged as error) both have concrete, verified
fixes. The real API is *richer* than the docs implied.

## Resolved questions

| # | Question | Verified answer | Design consequence |
|---|---|---|---|
| 1 | Does auto-approve hide "needs-input"? | **No, for real questions.** `question.asked` fires **independently of the permission ruleset** — verified firing under an all-allow session (`[{permission:"*",action:"allow"}]`). Permission auto-approve (`allow`) *does* suppress `permission.asked` (verified), but a tool set to `ask` reliably emits `permission.asked`→`permission.replied` (verified). | needs-input = `question.asked` **OR** `permission.asked`. Set `OPENCODE_ENABLE_QUESTION_TOOL=1` (the tool is env-gated). Optionally keep `bash`/`edit` at `ask` for unattended agents. |
| 2 | Abort → `idle` or `error`? | **Both.** A user-abort emits `session.error{ error.name: "MessageAbortedError" }` **and then** `session.status:idle` + `session.idle`. | **Classify `session.error` by `error.name`.** `MessageAbortedError` = clean interrupt (OpenCode's 130/143), never a failure toast. |
| 3 | `permission.replied` vs `session.idle` order? | **Reply precedes idle**, always — the turn resumes (`busy`) after the reply and only later goes `idle`. Verified: `asked → replied → busy → idle`. | The reconcile guard is safe: a late needs-input after idle can't happen within one turn. |
| 4 | TUI `-s <id>` reattach vs `--fork`? | `-s/--session <id>` continues **in place**; `--fork` is an explicit opt-in flag; there's also `POST /session/{id}/fork`. Sessions persist server-side (`session.list`, SQLite `opencode-local.db`). | Restore = launch/attach with `-s <id>`, or just `session.prompt` the persisted id via the server. No accidental forking. |
| 5 | Does an API-posted prompt need the TUI? | **No.** `message.part.updated` / `message.part.delta` stream full text and tool parts over `/event`. | Synth renders its **own** transcript from events; the OpenCode TUI is optional. "SDK prompt visibility in TUI" is moot. |
| 6 | One server, many worktrees? | **No — one server binds to one worktree** (`project/current` + `path.worktree` are fixed at launch; `session.create` has no `directory`). | **One `opencode serve` per worktree.** Fits Synth exactly: a branch already == one worktree. |
| 7 | `OPENCODE_*` nesting markers to scrub? | Child/tool env carries `OPENCODE` and `AGENT` (+ injection vars below). **No `CHILD_SESSION`-style crippling var** — subagents are in-process `task` children, not re-exec'd CLIs. | Defensive one-liner: strip `OPENCODE_*` + `AGENT` from the spawn env. Low risk. |
| 8 | Clean-quit exit code? | `opencode run` clean = **exit 0**. | Under server-first, status comes from events, so exit code is secondary. (Interrupt code untested; not load-bearing — medium confidence on that sub-point.) |
| 9 | MCP tool-name separator? | **`<server>_<tool>` (underscore).** Observed `synth-fs_list_directory` from a registered MCP. | Synth's CC name `mcp__synth-browser__browser_navigate` → **`synth-browser_browser_navigate`**. Update hardcoded names/allow-lists/globs. |
| 10 | Project MCP trust prompt? | **None.** A project-scoped `mcp` entry in `opencode.json` loaded and reported `{"synth-fs":{"status":"connected"}}` with no prompt. | Per-worktree `opencode.json` MCP registration "just works". `OPENCODE_DISABLE_PROJECT_CONFIG` exists if Synth ever wants to gate it. |
| 11 | Does `session.status` carry `parentID`? | **No** (only `{sessionID,status}`), but `Session` (embedded in `session.created/updated/deleted`) **does** carry `parentID`. | Build a `sessionID→parentID` map from `session.created/updated`; filter subagents on status/idle by that map. |
| 12 | OS-notification double-fire to suppress? | **None from the server** — OpenCode has no built-in OS-notification channel (community-plugin only). | Don't ship a notify plugin → nothing to suppress. `preferredNotifChannel` concern dissolves. |
| 13 | Config layering — merge or replace? | **Merge.** Multiple files load (`config.json` + `opencode.json` + `opencode.jsonc`) and an injected `permission` ruleset **concatenates** with agent/global rules (last-match-wins). | Synth adds config additively; the user's own opencode.json keeps working. No clobber. |

## Ground-truth API facts (1.17.7) worth pinning

- **Liveness** is a first-class enum: `EventSessionStatus.status.type ∈ { busy | idle | retry }` (`retry`
  carries `attempt`/`message`/`action` for provider retries). Plus discrete `session.idle`, `session.error`.
- **Lifecycle events** all carry native `sessionID`; `session.created/updated/deleted` embed the full
  `Session` (with `parentID`, `title`, `directory`, `agent`, `model`, `permission`). Correlation is intrinsic
  — no injected id needed.
- **Titles** are `Session.title`, generated after the first user message and delivered via `session.updated`
  (one-shot, overridable via `PATCH /session/{id}`). No transcript scraping.
- **Needs-input** has two channels: `permission.asked`/`permission.replied` (reply enum `once|always|reject`)
  and `question.asked`/`question.replied`/`question.rejected`. The question channel is permission-independent.
- **Rich permission taxonomy**: `bash, edit, read (with pattern `*.env` → ask by default!), webfetch, write,
  task, question, plan_enter/plan_exit, doom_loop, external_directory`. Enables granular auto-approve.
- **Injection via env, no files needed**: `OPENCODE_CONFIG_CONTENT` (inline config, highest precedence),
  `OPENCODE_PERMISSION` (inline permission), `OPENCODE_AUTH_CONTENT` / `OPENCODE_API_KEY` (auth). This is the
  clean replacement for CC's `--settings` blob.
- **Useful knobs**: `OPENCODE_ENABLE_QUESTION_TOOL`, `OPENCODE_DISABLE_AUTOUPDATE`,
  `OPENCODE_DISABLE_TERMINAL_TITLE`, `OPENCODE_DISABLE_PROJECT_CONFIG`, `OPENCODE_DISABLE_DEFAULT_PLUGINS`.
- **Security**: the server is **unsecured by default** ("Warning: OPENCODE_SERVER_PASSWORD is not set").
  Synth must set `OPENCODE_SERVER_PASSWORD` (+ `OPENCODE_SERVER_USERNAME`) since it's an HTTP server on
  loopback that can run shell/edit.
- **Alternative surfaces** (not needed, but exist): a PTY API (`/pty`, `EventPty*`) and an ACP server
  (`opencode acp`) — OpenCode can host terminals itself, and there's an Agent-Client-Protocol mode.
- Endpoints that matter: `POST /session` (create), `POST /session/{id}/message` (sync prompt) &
  `/prompt_async`, `POST /session/{id}/abort`, `POST /session/{id}/fork`, `POST /api/session/{id}/wait`,
  `GET /event` (SSE), `POST /mcp` (runtime MCP add), `POST /permission/{id}/reply`,
  `POST /question/{id}/reply`.

## Net effect on the plan

- **Gap #1 downgraded** from HIGH/low-confidence to **manageable/verified**: keep the question tool enabled
  and (optionally) select permissions at `ask`; needs-input is covered.
- **Gap #5 (abort) resolved**: filter `session.error` on `error.name === "MessageAbortedError"`.
- The architecture recommendation (**server-first, one `opencode serve` per worktree, render from `/event`,
  deliver via `session.prompt`, inject config/permission/auth via `OPENCODE_*` env**) is confirmed feasible
  end-to-end. Remaining engineering is mechanical, not exploratory.
