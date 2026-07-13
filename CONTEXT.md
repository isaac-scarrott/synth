# Synth

An AI-first, Mac-native development environment. It organises work as a tree of projects, their
branches, and the live sessions running inside each branch, and keeps that tree responsive with zero
perceptible lag.

## Language

**Project**:
Exactly one git repository that Synth is pointed at. Never more than one, never a subfolder of one.
"Add project" points Synth at a repo path.
_Avoid_: Workspace (legacy; collided with "worktree" one level down, both reading as work*), repo,
repository (in UI copy — say it in prose about git, not as the name of the row).

**Branch**:
A git branch within a project, auto-discovered. Sessions run inside a branch.
_Avoid_: Ref (when a branch specifically is meant).

**Session**:
A live thing running inside a branch — an agent, a terminal, a browser, or a simulator. Each carries
a live status that drives the sidebar indicators.
_Avoid_: Tab, pane, process (a session may own a process but is not synonymous with one).

**Agent**:
The category of session that hosts a coding agent. Claude Code and OpenCode are agents; a third is a
descriptor away. Say the category when Synth must speak generically ("Couldn't start an agent for
this comment"); say the product name on any control that creates or configures a specific one
("New Claude Code", "OpenCode flags").
_Avoid_: AI, assistant, bot, coding agent (as the UI noun — "agent" alone, since Synth hosts nothing
else that could be confused for one).

**Worktree**:
The git worktree that physically hosts a branch's sessions, created lazily when a branch first gains
a session. One per active branch. Session processes run with cwd set to their branch's worktree.

Say it only where a folder on disk is genuinely the subject: **Delete worktree**, and Settings. You
create a **New branch**, never a worktree, because you ask for a branch and the folder is how Synth
gives it to you. The asymmetry is load-bearing: deleting names the folder precisely because the git
branch survives it.
_Avoid_: Checkout, clone, working copy, branch folder.

**Remove**:
Drops a row from the sidebar. The thing it stood for survives: the repo stays cloned, the worktree
folder stays on disk. Always reversible by adding it back. Never red.
_Avoid_: Delete, close, hide.

**Close**:
Ends a session. The row goes and the process dies; nothing leaves the filesystem. Red, and confirms,
while the session is busy, because the agent's turn is lost. An idle session closes without a dialog.
_Avoid_: Delete (a session is not a file), kill, stop, quit.

**Delete**:
Destroys something on disk. Only the worktree folder qualifies. Always red, always confirms, always
states what survives (the git branch does).
_Avoid_: Remove, close, trash.

Red is the loss signal, not the disk signal: it marks any action whose result cannot be got back,
which is why a live Close wears it and a Remove never does.

**Branch group**:
A branch that has become live — it has a worktree and one or more sessions, so it is expandable and
shows a roll-up. A branch with no sessions is dormant (a plain row, no worktree).
_Avoid_: Active branch, current branch (there is no singular current branch — see Liveness).

**Busy**:
Something is happening in a session: an agent is mid-turn, or a process is up. One state, one amber
dot. Synth does not distinguish an agent thinking from a dev server serving, because the row's icon
already says which kind it is.
_Avoid_: Running, working (the two words this replaced), active, live (as the status label; see
Liveness for the concept).

**Liveness**:
Whether a session is busy. Non-exclusive: any number of sessions and branches can be live at once.
There is no single "current" or "checked-out" branch — liveness is the only running-signal, and git's
real HEAD is not surfaced.
_Avoid_: Current, active, checked-out (as a singular running-branch concept).

**Command menu**:
The ⌘K surface. One search box over both finding (projects, branches, sessions) and doing (new
branch, rename, close, delete worktree), scoped on open to the innermost focused level. "Go to X" is
a command like any other, which is why the name covers navigation too.
_Avoid_: Command palette, palette, quick actions (all three shipped at once, in the ⌘? sheet, the
browser hint, and marketing copy). Internal symbols still say `Palette` / `store.palette`; that is
legacy, not the domain term.

**Notification**:
One event, raised when a background session needs input, errors, or finishes. It appears inside Synth
as a stacked card you can jump to with ⌘↩, or in macOS Notification Center when Synth is not the
focused app. Same noun for both: where it lands is a qualifier, not a different thing.
_Avoid_: Toast (implementation jargon that leaked into Settings copy and marketing), alert, banner
(both collide with macOS's own Notification Center styles).

**Needs input**:
A session has stopped and cannot continue until you answer it. The one status that is a request
rather than a report, which is why it outranks every other in a roll-up and wears a glyph, not a dot.
_Avoid_: Waiting for input, blocked, paused, stalled.

**Trigger**:
Work that arrived from outside the app — a Teams thread, a Datadog alert, a schedule — delivered by
a plugin and waiting for a yes. A pending trigger is an ask, not work: it surfaces as a notification
card and in the ⌘K Triggers frame, never as a sidebar row (the tree shows work that is, the deck
shows asks). Accepting cuts a worktree and seeds one agent session with the brief; dismissing tells
the source.
_Avoid_: Task, job, request, webhook (the transport, not the thing), inbox item.

**Navigation cursor**:
The transient keyboard-nav ring that can rest on any row (project, branch, or session). Visible
only during keyboard use and dismissed the moment the mouse moves. A pure visual affordance for
"where the keys are" — it does not by itself change what the content pane shows.
_Avoid_: Selection, focus (too broad; this is specifically the ephemeral ring).

**Open session**:
The single session the content pane is currently rendering. Sticky — it survives mousing around the
tree and only changes when a session is activated (Enter/click). The one "you are here". The white
"active pill" is *derived* from it: the branch containing the open session (never a separately stored
field).
_Avoid_: Selected session, active session, current session.

**Belongs to**:
The relation between a browser session and the agent that opened it. The browser sits as a sibling
row wearing its owner's mark; it is never indented under it. **Attach to** and **Detach** are the two
verbs that make and break the relation. A browser you opened yourself belongs to nobody.
_Avoid_: Move under, nested, child, parent (all claim an indentation the sidebar does not draw).

**Comment**:
A note you leave on an element of a live page in a browser session. Synth delivers it to the agent
the browser belongs to, together with a screenshot and enough context to locate the element. If the
browser belongs to nobody, Synth starts an agent and hands the browser to it.
_Avoid_: Annotation, feedback (reserved for ⌘⇧F, which is feedback about Synth itself), pin.

**Plugin**:
A separate process the user installs that talks to Synth only over the control-socket API, holding
its own credentials and configuration — removable without the app changing shape (ADR-0014). Every
mutating ask a plugin makes is approval-gated in the app, never in the plugin. The trigger gateway
is the first one; the bundled MCP servers are retroactively the same seam.
_Avoid_: Extension, integration (what a plugin wires up, not the noun), add-on, bot.

**Supervisor**:
The per-session watcher that consumes a session's raw event firehose locally and emits only the
occasional *derived status fact* onto the event bus. The single transducer between the high-frequency
local layer and the low-frequency shared layer.
_Avoid_: Watcher, monitor, manager.

**Derived status fact**:
A low-frequency, observed fact about a session distilled from its raw events — busy, idle,
needs-input, error, unread/read. The only session-level thing allowed into global state.
_Avoid_: Event (a status fact is the *result* of processing events, not an event), state (too broad).

**Roll-up**:
The highest-priority derived status surfaced upward onto a collapsed parent row (branch group or
collapsed project), by precedence needs-input > error > busy > unread, falling back to
last-activity time when all nested sessions are idle.
_Avoid_: Summary, aggregate.

**Event bus**:
The transient, high-frequency transport carrying raw events to the one local owner that consumes
them. Distinct from the global store; most bus traffic never reaches the store.
_Avoid_: Message queue, pub/sub (when the Synth bus specifically is meant).

**Global store**:
The durable, observed source of truth holding only low-frequency facts that more than one view needs
or that must outlive any single view — tree structure, per-session derived status, selection, layout.
_Avoid_: State, model, Redux store.
