# Synth

An AI-first, Mac-native development environment. It organises work as a tree of git repositories,
their branches, and the live sessions running inside each branch, and keeps that tree responsive
with zero perceptible lag.

## Language

**Workspace**:
A git repository that Synth is pointed at. "Add workspace" points Synth at a repo path.
_Avoid_: Repo (in UI/domain prose — "workspace" is the canonical user-facing term), project.

**Branch**:
A git branch within a workspace, auto-discovered. Sessions run inside a branch.
_Avoid_: Ref (when a branch specifically is meant).

**Session**:
A live thing running inside a branch — a Claude Code agent, a terminal, a dev server, a browser,
or a simulator. Each carries a live status that drives the sidebar indicators.
_Avoid_: Tab, pane, process (a session may own a process but is not synonymous with one).

**Worktree**:
The git worktree that physically hosts a branch's sessions, created lazily when a branch first gains
a session. One per active branch. Session processes run with cwd set to their branch's worktree.
_Avoid_: Checkout, clone, working copy.

**Branch group**:
A branch that has become live — it has a worktree and one or more sessions, so it is expandable and
shows a roll-up. A branch with no sessions is dormant (a plain row, no worktree).
_Avoid_: Active branch, current branch (there is no singular current branch — see Liveness).

**Liveness**:
Whether a session is actively running (a working agent, or a live process in a terminal), shown as a
green dot. Non-exclusive: any number of sessions and branches can be live at once. There is no single
"current" or "checked-out" branch — liveness is the only running-signal, and git's real HEAD is not
surfaced.
_Avoid_: Current, active, checked-out (as a singular running-branch concept).

**Navigation cursor**:
The transient keyboard-nav ring that can rest on any row (workspace, branch, or session). Visible
only during keyboard use and dismissed the moment the mouse moves. A pure visual affordance for
"where the keys are" — it does not by itself change what the content pane shows.
_Avoid_: Selection, focus (too broad; this is specifically the ephemeral ring).

**Open session**:
The single session the content pane is currently rendering. Sticky — it survives mousing around the
tree and only changes when a session is activated (Enter/click). The one "you are here". The white
"active pill" is *derived* from it: the branch containing the open session (never a separately stored
field).
_Avoid_: Selected session, active session, current session.

**Supervisor**:
The per-session watcher that consumes a session's raw event firehose locally and emits only the
occasional *derived status fact* onto the event bus. The single transducer between the high-frequency
local layer and the low-frequency shared layer.
_Avoid_: Watcher, monitor, manager.

**Derived status fact**:
A low-frequency, observed fact about a session distilled from its raw events — running, working,
idle, needs-input, error, unread/read. The only session-level thing allowed into global state.
_Avoid_: Event (a status fact is the *result* of processing events, not an event), state (too broad).

**Roll-up**:
The highest-priority derived status surfaced upward onto a collapsed parent row (branch group or
collapsed workspace), by precedence needs-input > error > working > running, falling back to
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
