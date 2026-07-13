// Synth's app-control MCP server (stdio) — the synth-browser server's sibling, for
// driving Synth itself rather than a page. Off by default; the user opts in per
// machine via Settings → MCP servers, and every mutating verb is approval-gated:
// the tool call blocks on the app's control socket while Synth shows the user a
// native prompt, and only their "Create" click makes anything happen.
//
// Discovery and scoping are shared with the browser server (shared.mjs): the
// worktree named by $SYNTH_WORKTREE / $CLAUDE_PROJECT_DIR picks the Synth
// instance and the workspace the verbs act in.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { controlCall, makeTool, requireScope, text } from "./shared.mjs";

const server = new McpServer({ name: "synth-app", version: "0.1.0" });
const tool = makeTool(server);

// The user gets 4 minutes to answer the prompt (ControlServer's window); the socket
// timeout sits just past it so the app's own timeout answer arrives, not a dead socket.
const APPROVAL_MS = 250_000;

tool("worktree_create",
  "Create a new git worktree in this repo through Synth, so a separate line of work " +
  "gets its own branch, checkout and sessions instead of piling onto the current one. " +
  "PROACTIVELY suggest this by calling it whenever you're asked to start work that " +
  "doesn't belong on the current branch — a new feature while a fix is in flight, an " +
  "unrelated bug, an experiment. Synth asks the user to approve first; this call " +
  "blocks until they answer (up to a few minutes), and nothing is created unless they " +
  "accept. An existing branch is checked out as-is; a new branch is cut off `base`. " +
  "To also hand the work off, pass `handoff`: Synth then starts a fresh Claude " +
  "session in the new worktree and delivers it, instead of the worktree's default " +
  "sessions — write it like a brief for a colleague picking up cold (goal, current " +
  "state, decisions made, next steps, gotchas, key file paths). Without `handoff` " +
  "the worktree starts with its configured session template and the work stays yours.",
  {
    branch: z.string().describe(
      "branch for the worktree, e.g. feat/billing-retries (created off `base` when " +
      "new; an existing local or remote branch is checked out instead)"),
    base: z.string().optional().describe(
      "base branch for a NEW branch (the repo's HEAD when omitted); ignored when " +
      "`branch` already exists"),
    handoff: z.string().optional().describe(
      "handoff brief (markdown) for a fresh Claude session in the new worktree — " +
      "include everything it needs to continue without this conversation's context"),
  },
  async ({ branch, base, handoff }) => {
    const scope = requireScope();
    const res = await controlCall(scope.inst, {
      verb: "app.worktreeCreate", worktreePath: scope.path, branch,
      ...(base && { base }),
      ...(handoff && { handoff }),
      ...(process.env.SYNTH_SESSION_ID &&
          { ownerSessionId: process.env.SYNTH_SESSION_ID }),
    }, { timeoutMs: APPROVAL_MS });
    switch (res.decision) {
      case "declined":
        return text(
          `The user declined creating worktree "${branch}". Continue the work on the ` +
          "current branch, or ask them how they'd like to proceed — don't retry this " +
          "call unprompted.");
      case "exists":
        return text(JSON.stringify({
          branch,
          worktreePath: res.worktreePath,
          note: "this branch is already a Synth worktree — nothing was created; " +
                "work there directly (no prompt was shown)",
        }, null, 2));
      default:
        return text(JSON.stringify({
          created: true,
          branch,
          worktreePath: res.worktreePath,
          note: "approved by the user — the checkout is materialising in the " +
                "background (Synth surfaces any failure to the user)" +
                (handoff
                  ? "; a fresh Claude session there will receive the handoff once it's ready"
                  : "; the worktree starts with the user's configured session template"),
        }, null, 2));
    }
  });

await server.connect(new StdioServerTransport());
