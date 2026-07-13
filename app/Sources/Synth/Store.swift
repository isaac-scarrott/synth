import AppKit
import Foundation
import Observation
import SwiftUI

/// A low-frequency derived fact posted by a session's supervisor onto the bus.
/// The firehose (PTY bytes, cursor moves) never appears here — see docs/adr/0001.
enum SessionEvent: Sendable {
    case statusChanged(UUID, SessionStatus)
    case titleChanged(UUID, String)
    /// A new Claude conversation started in an existing row (fresh startup or `/clear`) — drop
    /// the previous conversation's ai-title so the stale name doesn't linger until a new one is
    /// generated. Resume/compact keep their title, so they never emit this.
    case titleReset(UUID)
    case exited(UUID, Int32?)
    /// The session's true exit status, reported over the hook socket (zshexit / the claude
    /// shim) just before the process dies. Needed because macOS `login` — libghostty's PTY
    /// wrapper — exits 0 whatever its child's status was, so `.exited`'s own code is
    /// always 0 and can't carry the clean-vs-failure fact (features 2026-07-06).
    case exitCodeReported(UUID, Int32)
    /// A terminal was detected running a coding agent (or stopped) — flips the row's visual.
    case kindChanged(UUID, SessionKind)
    /// A background session finished a turn — surface it unless it's the one on screen.
    case markUnread(UUID)
    /// The agent reported its own session id (Claude Code via its SessionStart hook, opencode
    /// off `session.created`) — stored so a restored row can resume the conversation (ADR-0010).
    case agentSessionCaptured(UUID, String)
    /// The agent is not merely *starting* but reachable — its supervisor can hand it text.
    /// Only a supervisor posts this: Claude Code is ready the moment its own hook fires from
    /// inside the running process, while opencode is ready only once its event stream connects
    /// (its shim announces the launch a beat before the server binds).
    case agentReady(UUID)
    /// A browser session's address changed — every navigation, including ones the engine's
    /// future CDP clients initiate (ADR-0011). Renames the row and feeds the branch recents.
    case browserNavigated(UUID, URL)
    /// The page's document title — auto-names the session row (URL host+path stands as the
    /// fallback until it arrives) and labels the recents entry.
    case browserPageTitled(UUID, String)
    /// window.open / target=_blank: one page per session, so a popup becomes a NEW
    /// browser session in the same branch, pre-navigated and selected.
    case browserPopupRequested(UUID, URL)
    /// A link clicked in a terminal surface (libghostty OPEN_URL). The UUID is the clicking
    /// session (nil for an app-scoped action → the on-screen session). Scheme + host route
    /// it: loopback dev-server pages open in the in-app browser, everything else to the OS.
    case openURLRequested(UUID?, URL)
}

/// The transient transport carrying derived facts to the single consumer (the store).
/// This is the seam an eventual Claude-Code supervisor plugs into unchanged.
@MainActor final class EventBus {
    let stream: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    func post(_ event: SessionEvent) { continuation.yield(event) }
}

/// A repo chosen for adding, awaiting the branch picker: the user selects which
/// branches to show; each becomes a row backed by a real worktree folder.
struct PendingWorkspace {
    let url: URL
    let candidates: [BranchCandidate]
}

struct BranchCandidate: Identifiable {
    let id = UUID()
    let name: String
    let age: String
    let existingWorktree: URL?   // nil → a worktree will be created on Add
}

/// An agent-requested worktree create awaiting the user's yes/no — the synth-app MCP
/// server's approval gate. Nothing happens unless the user clicks Create; `respond`
/// answers the control-socket connection blocked on the answer (called exactly once,
/// always on the main actor).
struct AgentWorktreePrompt: Identifiable {
    let id = UUID()
    let workspace: Workspace
    let branchName: String
    let base: String?           // nil → the repo's HEAD; meaningful only for a new branch
    let handoff: String?        // a brief for a fresh Claude session in the new worktree
    let requesterTitle: String? // the asking agent row's title — the prompt's "who"
    let respond: ([String: Any]) -> Void
}

/// How an agent's worktree request started: answered on the spot (error, or the branch
/// is already a row), or pending as a prompt the user must answer (the id cancels it).
enum AgentPromptStart {
    case immediate([String: Any])
    case pending(UUID)
}

/// The escalated sidebar indicator a background session raises as a toast: needs-input is
/// the slate-blue `?` (`Theme.input`), error the terracotta `!` (`Theme.danger`), and — for
/// any live session settling to idle — the green ✓ `done`, a transient toast that
/// dismisses itself.
enum NotifKind: Sendable {
    case input, error, done

    /// Deck precedence (front first): errors before needs-input before done.
    var rank: Int {
        switch self { case .error: return 0; case .input: return 1; case .done: return 2 }
    }
}

/// One live in-app notification — a background session escalated to a glass toast. `seq` is
/// a monotonic raise counter so same-kind toasts order newest-first (working.html's
/// `notifState` Map value `{ kind, order }`).
struct InAppNotif: Identifiable {
    let id: UUID        // the session id — one toast per session, like working.html
    var kind: NotifKind
    let seq: Int
    /// Display snapshot captured at raise time. A clean exit closes its session right after
    /// the "done" toast goes up (features 2026-07-06), so the card can't count on a live
    /// session to render from.
    let sessionKind: SessionKind
    let title: String
    let colorIndex: Int?
    /// Only the exit-close "done" toast may outlive its session in `notifOrder`; it always
    /// self-dismisses. Every other toast still drops the moment its session vanishes.
    let outlivesSession: Bool
    /// System toasts (no session behind them — e.g. a failed background worktree op)
    /// carry their own verb line and glyph; session toasts leave these nil and derive
    /// both from the session. A system toast persists until clicked.
    var message: String? = nil
    var iconPath: String? = nil
}

/// Where a notification is surfaced. `nil` at a call site means "the real rule" — branch on
/// `NSApp.isActive`; the DEBUG trigger passes an explicit value so both layers are drivable
/// headless (a driven instance isn't reliably frontmost).
enum NotifRoute { case inApp, notificationCenter }

/// Which settings scope the full-screen settings page is showing. A workspace is
/// referenced by id so a removed workspace leaves a dangling scope that falls back
/// to Global rather than crashing (working.html's dangling-scope guard).
enum SettingsScope: Equatable {
    case global
    case workspace(UUID)
}

/// The appearance choice (working.html's System / Light / Dark segmented control).
enum ThemePref: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Who is running this Synth, resolved once at launch. The author (git identity matched)
/// gets the feedback→worktree loop; everyone else gets a pre-filled email. `SYNTH_AUTHOR=1`
/// / `=0` forces it (the established env-override idiom), else it's the git `user.email`.
enum FeedbackMode {
    case author, email

    static let recipient = "isaac.scarrott11@gmail.com"
    static let authorEmails: Set<String> = ["isaac@holibob.tech", "isaac.scarrott11@gmail.com"]

    static func resolve() -> FeedbackMode {
        switch ProcessInfo.processInfo.environment["SYNTH_AUTHOR"] {
        case "1": return .author
        case "0": return .email
        default:
            let email = GitService.gitUserEmail()?.lowercased() ?? ""
            return authorEmails.contains(email) ? .author : .email
        }
    }
}

/// The durable, observed source of truth. Holds only the low-frequency facts the
/// UI reads: the tree, per-session status, expansion, and the two selection fields
/// (nav cursor + open session) from docs/adr/0005.
@MainActor @Observable final class AppStore {
    var workspaces: [Workspace] = []
    var expanded: Set<UUID> = []
    var navCursor: UUID?
    var openSessionID: UUID?
    /// The still-materialising branch whose "setting up…" skeleton the content pane is
    /// showing. Set the instant a worktree create is requested (the switch rides the
    /// keystroke, not the async checkout) and cleared the moment the user opens anything
    /// else — so a finished checkout resolves in place only while this still points at it,
    /// and otherwise lands as a quiet unread row instead of yanking the viewport
    /// (last-intent-wins). Never persisted; a pending row can't outlive a quit.
    var openSetupBranchID: UUID?
    var sidebarCollapsed = false

    /// Appearance — System follows the OS, Light/Dark pin it (working.html's global-only
    /// theme setting). Persisted to UserDefaults (the native `localStorage`).
    var themePref: ThemePref = (ThemePref(rawValue: UserDefaults.standard.string(forKey: AppStore.themeKey) ?? "") ?? .system) {
        didSet { UserDefaults.standard.set(themePref.rawValue, forKey: AppStore.themeKey) }
    }
    static let themeKey = "synth-theme"
    /// nil = follow the system; otherwise pin light/dark (drives `.preferredColorScheme`).
    var colorSchemeOverride: ColorScheme? {
        switch themePref { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }

    /// Active in-app notifications (working.html `notifState`). Rendered as a stacked deck by
    /// NotificationDeck while Synth is frontmost; the unfocused path goes through Notification
    /// Center instead (NotificationService). The open session is never in here — opening one
    /// clears its toast, mirroring the `.markUnread` open-guard.
    var notifs: [InAppNotif] = []
    @ObservationIgnored private var notifSeq = 0

    /// One-shot ambient row-pulse tokens (working.html `session--pulse`). A `done` on an
    /// off-screen live session bumps its token; the sidebar row runs a single soft sweep on
    /// change. Keyed by session id — the value only has to *differ* to re-fire.
    var pulseTokens: [UUID: Int] = [:]

    /// Per-type Notification-Center sound toggles (working.html's per-type sound setting).
    /// Persisted to UserDefaults like `themePref`; defaults needs-input ON, error ON, done OFF.
    /// In-app toasts are always silent — this only gates the unfocused NC path.
    var soundNeedsInput = AppStore.loadBoolPref(AppStore.soundInputKey, default: true) {
        didSet { UserDefaults.standard.set(soundNeedsInput, forKey: AppStore.soundInputKey) }
    }
    var soundError = AppStore.loadBoolPref(AppStore.soundErrorKey, default: true) {
        didSet { UserDefaults.standard.set(soundError, forKey: AppStore.soundErrorKey) }
    }
    var soundDone = AppStore.loadBoolPref(AppStore.soundDoneKey, default: false) {
        didSet { UserDefaults.standard.set(soundDone, forKey: AppStore.soundDoneKey) }
    }
    static let soundInputKey = "synth-sound-input"
    static let soundErrorKey = "synth-sound-error"
    static let soundDoneKey  = "synth-sound-done"
    /// UserDefaults' `bool(forKey:)` can't tell "unset" from `false`, so read the object and
    /// fall back to the type's default only when it's genuinely absent.
    static func loadBoolPref(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }

    /// Per-machine MCP server toggles (Settings → MCP servers): which bundled servers are
    /// registered in every managed worktree's agent config. The browser server ships on;
    /// the app-control server (worktree creation behind a user prompt) is opt-in. A flip
    /// re-syncs every worktree's config immediately — disabled means the entry is REMOVED,
    /// so agents don't even see the tools.
    var mcpBrowserEnabled = AppStore.loadBoolPref(AppStore.mcpBrowserKey, default: true) {
        didSet {
            UserDefaults.standard.set(mcpBrowserEnabled, forKey: AppStore.mcpBrowserKey)
            syncAgentBridge()
        }
    }
    var mcpAppEnabled = AppStore.loadBoolPref(AppStore.mcpAppKey, default: false) {
        didSet {
            UserDefaults.standard.set(mcpAppEnabled, forKey: AppStore.mcpAppKey)
            syncAgentBridge()
        }
    }
    static let mcpBrowserKey = "synth-mcp-browser"
    static let mcpAppKey = "synth-mcp-app"

    /// Draggable sidebar width, clamped and persisted (working.html's `--sidebar-w`).
    var sidebarWidth: CGFloat = {
        let w = UserDefaults.standard.double(forKey: AppStore.sidebarWidthKey)
        return (w >= Theme.sidebarMinWidth && w <= Theme.sidebarMaxWidth) ? CGFloat(w) : Theme.sidebarWidth
    }() {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: AppStore.sidebarWidthKey) }
    }
    static let sidebarWidthKey = "synth-sidebar-w"

    /// True only while the keyboard is driving nav — gates the selection ring
    /// (mousemove clears it), mirroring working.html's `.kbd` class.
    var keyboardActive = false

    /// Drag-to-reorder (F2): the row being dragged (nil = none) and its live vertical
    /// offset within its slot, so the lifted row tracks the pointer while its siblings
    /// shift. `reorderScrollNonce` is bumped on every reorder step (drag + ⇧J/⇧K) so the
    /// sidebar can keep the moving row in view.
    var draggingRowID: UUID?
    var dragOffset: CGFloat = 0
    var reorderScrollNonce = 0

    /// Sheet drivers.
    var creatingWorktreeIn: Workspace?
    var pendingWorkspace: PendingWorkspace?

    /// Agent-requested worktree prompts (synth-app MCP), oldest first — the ⌘K confirm
    /// frame shows the head; resolving or cancelling it reveals the next.
    var agentPrompts: [AgentWorktreePrompt] = []

    /// The agent prompt (if any) currently driving the palette's confirm frame — set by
    /// `presentAgentPrompt`, cleared the moment it's resolved. Closing the palette while
    /// this is non-nil (Esc, ⌘K, backdrop click) declines that prompt, same as before.
    var presentedAgentPromptID: UUID?

    /// The feedback sheet (⌘⇧F). `feedbackDraft` persists an unsent gripe across reopens,
    /// like working.html. `feedbackTitle` is the author-only name that becomes the
    /// `feedback/<slug>` branch (email mode never shows it). `feedbackMode` is resolved
    /// once at launch (see init).
    var feedbackOpen = false
    var feedbackDraft = ""
    var feedbackTitle = ""
    @ObservationIgnored var feedbackMode: FeedbackMode = .email

    /// The row-action menu currently open (nil = none). Clearing it always drops any
    /// in-progress delete confirmation.
    var activeMenu: ActiveMenu? { didSet { if activeMenu == nil { menuConfirming = false } } }

    /// The open menu is showing its two-step delete confirm (working.html `.menu.confirming`).
    /// Lifted out of RowMenu so the keyboard can drive it: `d` opens straight here, ↵ commits.
    var menuConfirming = false

    /// The sidebar row being renamed inline, and its live text — working.html's
    /// contentEditable name label. nil = nothing renaming.
    var renamingRowID: UUID?
    var renameText = ""

    /// The ⌘K palette (nil = closed).
    var palette: PaletteModel?

    /// The ⌘? keyboard-shortcuts sheet (working.html's shortcutsEl).
    var shortcutsOpen = false

    /// Full-screen Settings page: a mode layered over the same shell (working.html's
    /// `.app.settings`). `settingsScope` picks which scope the right pane renders.
    var settingsOpen = false
    var settingsScope: SettingsScope = .global

    /// The worktree setup scripts the effective config is assembled from — a design
    /// surface only. These live in memory (like working.html's mock store) so edits
    /// survive scope hops; no setup-script runner is wired up yet (see FEATURES).
    var globalScript = """
    #!/usr/bin/env bash
    set -euo pipefail

    # Runs in every new worktree, across all workspaces.
    [ -f "$SYNTH_MAIN/.env" ] && cp "$SYNTH_MAIN/.env" .env
    """
    var wsScripts: [UUID: String] = [:]
    let wsScriptPlaceholder = """
    #!/usr/bin/env bash

    # No extra setup for this workspace yet.
    """

    /// Default flags passed to an agent's binary when one of its sessions starts, per agent.
    /// The raw string is the source of truth, so ANY flag the agent accepts works; the
    /// Settings switches are shortcuts for common ones. A workspace's flags OVERRIDE the
    /// global outright — unlike the setup scripts, flags don't compose; the last word wins.
    /// An empty workspace value inherits global.
    ///
    /// opencode needs none: it auto-approves by default, and the needs-input signal Synth
    /// relies on rides the question tool (enabled by env), not a permission flag.
    var globalAgentFlags: [AgentID: String] = [
        .claudeCode: "--dangerously-skip-permissions",
        .opencode: "",
    ]
    var wsAgentFlags: [UUID: [AgentID: String]] = [:]

    /// The effective flags for an agent in a scope. A workspace with its own flags replaces
    /// the global outright; an empty (or absent) workspace value inherits global.
    func agentFlags(_ agent: AgentID, for workspace: Workspace?) -> String {
        let w = (workspace.flatMap { wsAgentFlags[$0.id]?[agent] } ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !w.isEmpty { return w }
        return (globalAgentFlags[agent] ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The ordered session set every new worktree starts with (working.html TPL_KINDS /
    /// globalTpl). Order is creation order — the first entry is the session that opens.
    var globalSessionTemplate: [SessionTemplateEntry] = [
        SessionTemplateEntry(kind: .agent(.claudeCode), name: "Claude Code"),
        SessionTemplateEntry(kind: .terminal, name: "dev server"),
        SessionTemplateEntry(kind: .terminal, name: "shell"),
    ]
    var wsSessionTemplates: [UUID: [SessionTemplateEntry]] = [:]

    /// The effective template for a scope — same override model as the flags: a workspace
    /// with its own list replaces the global outright; an empty (or absent) list inherits.
    func sessionTemplate(for workspace: Workspace?) -> [SessionTemplateEntry] {
        if let w = workspace.flatMap({ wsSessionTemplates[$0.id] }), !w.isEmpty { return w }
        return globalSessionTemplate
    }

    /// Session ids with a LIVE coding agent attached THIS run — asserted only by the supervisor
    /// seam (agent-start / agentSessionCaptured; cleared by agent-end / process exit).
    /// A persisted `.agent` kind is NOT liveness: a restored row whose resume fails drops to a
    /// bare shell, and pasting a browser comment there (page-controlled text submitted with
    /// Enter) would hand the page shell execution. Comment delivery gates on this set
    /// (CommentModeController.deliver).
    private(set) var liveAgentIDs: Set<UUID> = []
    /// True exit statuses reported over the hook socket (`.exitCodeReported`), keyed by
    /// session, consumed by the `.exited` that follows moments later.
    @ObservationIgnored private var reportedExitCodes: [UUID: Int32] = [:]
    /// The in-app browser each terminal/Claude session sends its clicked loopback links to,
    /// so reclicking a dev-server URL reuses one row instead of spawning per click. Keyed by
    /// source session; the entry (and any pointing at a closed browser) is dropped on close.
    @ObservationIgnored private var linkBrowsers: [UUID: UUID] = [:]

    func isLiveAgent(_ id: UUID) -> Bool { liveAgentIDs.contains(id) }

    /// Tear down a session's supervision. Safe to call for a row that never hosted an agent
    /// (nil id) or whose supervisor never attached — both are no-ops.
    private func detachSupervisor(_ agent: AgentID?, _ session: UUID) {
        guard let agent else { return }
        AgentRegistry.supervisor(agent)?.detach(session: session)
    }

    /// The live agent hosted by `session`, if any — the supervisor that can be handed text.
    func liveSupervisor(for session: Session) -> (any AgentSupervisor)? {
        guard isLiveAgent(session.id), let agent = session.kind.agentID else { return nil }
        return AgentRegistry.supervisor(agent)
    }

    let bus = EventBus()
    let hookServer: HookServer
    /// Stage-two control socket (ADR-0011): browser.list / browser.create for the
    /// bundled MCP server. Request/response, so separate from the one-way hook socket.
    @ObservationIgnored private var controlServer: ControlServer!

    /// Bytes of the last snapshot written — lets the autosave skip an unchanged rewrite
    /// (ADR-0010). @ObservationIgnored: a bookkeeping field, not UI state.
    @ObservationIgnored private var lastSavedBytes: Data?

    init() {
        feedbackMode = FeedbackMode.resolve()
        hookServer = HookServer(bus: bus)
        TerminalManager.shared.bus = bus
        BrowserManager.shared.bus = bus
        TerminalManager.shared.hookSocketPath = hookServer.socketPath
        AgentRegistry.startSupervisors(bus: bus)
        HookEnvironment.setup()
        hookServer.start()
        Task { [weak self] in
            guard let self else { return }
            for await event in self.bus.stream { self.apply(event) }
        }
        if let state = PersistenceStore.load() { restore(from: state) }
        // Stage two (ADR-0011): advertise this instance, listen for control verbs,
        // and install/register the bundled browser MCP server.
        InstanceRegistry.shared.start()
        controlServer = ControlServer(store: self)
        controlServer.start()
        MCPInstaller.refreshServerInstall()
        syncAgentBridge()
        startAutosave()
    }

    /// Keep the instance file's worktreePaths and every worktree's .mcp.json current.
    /// Runs at init, on the autosave cadence, and when an MCP toggle flips (all skip
    /// unchanged inputs), so no workspace/branch mutation site can forget it — the
    /// autosave model.
    private func syncAgentBridge() {
        let paths = workspaces.flatMap { $0.branches.map(\.worktreeURL.path) }
        InstanceRegistry.shared.update(worktreePaths: paths)
        MCPInstaller.syncWorktreeConfigs(paths, servers: [
            "synth-browser": mcpBrowserEnabled,
            "synth-app": mcpAppEnabled,
        ])
    }

    // MARK: Bus → store

    private func apply(_ event: SessionEvent) {
        switch event {
        case let .statusChanged(id, status):
            guard let s = session(id) else { break }
            // A `needsInput` (?) is only legitimate mid-turn: a question / permission / plan
            // block always interrupts work in flight. Claude's ambient "waiting for your input"
            // notification instead fires at end-of-turn and races the `Stop`→idle that ends it —
            // each hook is a separate process applied on its own Task, so order isn't guaranteed.
            // Requiring a still-live prior state drops the nudge once the turn has settled, so the
            // finish is order-independent: whichever of idle/needsInput lands last, the row ends
            // idle. Genuine blocks are preceded by UserPromptSubmit/PostToolUse→working, so the ?
            // still lights.
            if status == .needsInput, !s.status.isLive { break }
            let prev = s.status
            s.status = status
            routeTransition(id, prev: prev, next: status)
        case let .titleChanged(id, title):
            // Claude Code's ai-title, refined each turn — but never clobber a hand-picked name.
            if let s = session(id), !s.titleIsCustom, s.title != title { s.title = title }
        case let .titleReset(id):
            // Keep a hand-picked name; otherwise fall back to the agent's neutral default until
            // the new conversation generates its own title (arriving as .titleChanged).
            if let s = session(id), !s.titleIsCustom { s.title = s.spawnedKind.tplStart }
        case let .exitCodeReported(id, code):
            reportedExitCodes[id] = code
        case let .exited(id, code):
            guard let s = session(id) else { break }
            let prev = s.status
            liveAgentIDs.remove(id)
            detachSupervisor(s.kind.agentID ?? s.spawnedKind.agentID, id)
            // The PTY's own code is blind on macOS — libghostty wraps the child in `login`,
            // which exits 0 whatever really happened — so prefer the code the session
            // reported over the hook socket just before dying. The user-interrupt statuses
            // (130 SIGINT, 143 SIGTERM) close clean, the same neutrality the per-command
            // reporter applies: a Ctrl-C'd claude mustn't die as an error row.
            let real = reportedExitCodes.removeValue(forKey: id) ?? code ?? 0
            if real == 0 || real == 130 || real == 143 {
                // A clean exit ends the session outright — `exit` in a shell, quitting a
                // spawned claude (which execs, so this is its exit too). Notify first: both
                // notification paths need the live row (features 2026-07-06).
                s.status = .exited(real)
                routeTransition(id, prev: prev, next: .exited(real), closing: true)
                closeSession(s)
            } else {
                // A failure keeps its row — the error should be seen and inspectable,
                // not vanish with the process.
                s.status = .error
                routeTransition(id, prev: prev, next: .error)
            }
        case let .kindChanged(id, kind):
            guard let s = session(id) else { break }
            // A browser session never runs an agent, so an agent lifecycle signal carrying its
            // id is spurious — applying it would flip the pane to a terminal while
            // BrowserManager still holds the browser controller, desyncing the two and
            // wedging ⌘K on that row.
            if s.spawnedKind == .browser { break }
            // A session spawned as an agent never reverts to a plain terminal: it exec'd the
            // agent, so an agent-end is either the process about to exit (the child-exited
            // signal closes the row moments later) or a /clear's end/start pair — neither
            // should blip the kind.
            if kind == .terminal, s.spawnedKind.isAgent {
                liveAgentIDs.remove(id)
                detachSupervisor(s.spawnedKind.agentID, id)
                break
            }
            s.kind = kind
            // The supervisor seam's agent lifecycle: agent-start posts .agent(id), agent-end
            // posts .terminal. Liveness is NOT asserted here — an agent that has been *launched*
            // may not yet be reachable, and delivering into a not-yet-listening agent silently
            // drops the text. Its supervisor posts `.agentReady` when it truly is.
            if let agent = kind.agentID {
                AgentRegistry.supervisor(agent)?.attach(session: id)
            } else {
                liveAgentIDs.remove(id)
                detachSupervisor(s.spawnedKind.agentID, id)
            }
        case let .markUnread(id): if openSessionID != id { session(id)?.unread = true }
        case let .agentReady(id):
            liveAgentIDs.insert(id)
        case let .agentSessionCaptured(id, agentSessionID):
            if let s = session(id), s.agentSessionID != agentSessionID { s.agentSessionID = agentSessionID }
            liveAgentIDs.insert(id)
        case let .browserNavigated(id, url):
            guard let s = session(id) else { return }
            s.browserURL = url
            if !s.titleIsCustom { s.title = url.browserHostPath }
            noteBrowserRecent(url, for: s)
        case let .browserPageTitled(id, title):
            guard let s = session(id), !title.isEmpty else { return }
            // The page title is the row's auto-name — .browserNavigated already set the
            // host+path fallback, which stands until this arrives (or for untitled pages).
            if !s.titleIsCustom, s.title != title { s.title = title }
            // Also attach it to the current URL's recents entry (the "name" column).
            guard let url = s.browserURL, let br = branch(of: s),
                  let i = br.browserRecents.firstIndex(where: { $0.url == url.absoluteString })
            else { return }
            if br.browserRecents[i].title != title { br.browserRecents[i].title = title }
        case let .browserPopupRequested(id, url):
            guard let s = session(id) else { return }
            // A popup opened from an owned browser inherits the owner (stage four) —
            // it's the same claude's surface, just a second page. Owned means
            // agent-driven (a CDP click looks like a real one), so it announces via
            // the unread bullet; a popup from a browser the user drives opens in front.
            let popupOwner = owner(of: s)
            newBrowser(in: branch(of: s), at: url, ownedBy: popupOwner, focus: popupOwner == nil)
        case let .openURLRequested(sourceID, url):
            openTerminalLink(url, from: sourceID)
        }
    }

    /// A clicked terminal link. Scheme + host decide the target: a loopback dev-server page
    /// opens in the in-app browser (owned by the clicking Claude session, reused across
    /// clicks) so the agent can drive the same page the human sees. Every other web URL and
    /// every non-web scheme goes to the OS default handler — that keeps the user's real
    /// auth/extensions and matches every other macOS terminal (an embedded browser is a
    /// fresh, logged-out profile, wrong for github.com/stripe.com and blank for mailto:).
    func openTerminalLink(_ url: URL, from sourceID: UUID?) {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https", url.isLoopbackHost else {
            NSWorkspace.shared.open(url); return
        }
        let source = sourceID.flatMap(session) ?? openSessionID.flatMap(session)
        // Reuse this session's link browser if it's still alive — reclicking a dev-server URL
        // must not mint a row per click.
        if let srcID = source?.id, let bid = linkBrowsers[srcID], let existing = session(bid) {
            existing.browserURL = url
            BrowserManager.shared.existing(bid)?.navigate(to: url)
            open(existing)
            return
        }
        // Only an agent session can own a browser; a plain terminal spawns an unowned one.
        let owner = (source?.kind.isAgent ?? false) ? source : nil
        guard let browser = newBrowser(in: source.flatMap { branch(of: $0) },
                                       at: url, ownedBy: owner, focus: true) else {
            NSWorkspace.shared.open(url); return   // no branch to host it — don't lose the click
        }
        if let srcID = source?.id { linkBrowsers[srcID] = browser.id }
    }

    /// Front of the branch's Recent list, deduped by URL (keeping the known title), capped at 5.
    /// Hostless URLs (about:blank, data:) are engine plumbing, not destinations.
    private func noteBrowserRecent(_ url: URL, for session: Session) {
        guard url.host != nil, let br = branch(of: session) else { return }
        let key = url.absoluteString
        var recents = br.browserRecents
        let title = recents.first(where: { $0.url == key })?.title ?? ""
        recents.removeAll { $0.url == key }
        recents.insert(BrowserRecent(url: key, title: title), at: 0)
        br.browserRecents = Array(recents.prefix(5))
    }

    // MARK: Notifications (working.html notifyOnTransition → the in-app deck / Notification Center)

    /// A background session's status transition, turned into a notification — the single seam
    /// terminals and Claude both reach (`term-*` and Claude signals alike flow through `apply`).
    /// The open session never notifies. Focus picks the surface: frontmost → the in-app deck,
    /// unfocused → Notification Center. `force` overrides the focus rule for the DEBUG trigger.
    /// `closing` marks the exit-close transition: the caller removes the row right after,
    /// so the raised done toast must outlive its session.
    /// Harness seam (`SYNTH_AUTOMATION`, ControlServer `automation.notifRoute`): pin the surface
    /// a transition routes to. Focus normally decides, and a driven instance never holds focus on
    /// a live desktop — other apps take it straight back — so the deck path is otherwise untestable.
    @ObservationIgnored var automationNotifRoute: NotifRoute?

    func routeTransition(_ id: UUID, prev: SessionStatus, next: SessionStatus, force: NotifRoute? = nil, closing: Bool = false) {
        if openSessionID == id { clearNotif(id); return }
        let route = force ?? automationNotifRoute
        let toNC = route.map { $0 == .notificationCenter } ?? !NSApp.isActive
        switch next.rollup {
        case .input, .error:
            let kind: NotifKind = next.rollup == .error ? .error : .input
            session(id)?.unread = true   // working.html notify() marks the row unread too
            if toNC { NotificationService.shared.postAttention(store: self, id: id, kind: kind) }
            else { raiseInApp(id, kind) }
        case .idle where prev.rollup != .idle:
            // A live session settling to idle off-screen → "done": the unread bullet, one
            // soft row sweep, and a transient toast that dismisses itself (a finished session
            // should be seen, but asks for nothing). Unfocused → a transient banner.
            session(id)?.unread = true   // working.html done also marks the row unread
            if toNC {
                clearNotif(id)
                NotificationService.shared.postDone(store: self, id: id)
            } else {
                pulseTokens[id, default: 0] += 1
                raiseInApp(id, .done, outlivesSession: closing)
            }
        default:
            clearNotif(id)   // work / run (and idle-from-idle) clear any standing toast
        }
    }

    /// Raise (or re-raise, bumping it to newest) a background session's toast. A done toast
    /// asks for nothing, so it dismisses itself; the seq check keeps the timer from killing
    /// a newer toast the same session raised in the meantime.
    private func raiseInApp(_ id: UUID, _ kind: NotifKind, outlivesSession: Bool = false) {
        guard let s = session(id) else { return }
        notifSeq += 1
        notifs.removeAll { $0.id == id }
        notifs.append(InAppNotif(id: id, kind: kind, seq: notifSeq,
                                 sessionKind: s.kind, title: s.title,
                                 colorIndex: branch(of: s).flatMap { workspace(of: $0) }?.colorIndex,
                                 outlivesSession: outlivesSession))
        if kind == .done {
            let seq = notifSeq
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.notifs.removeAll { $0.id == id && $0.seq == seq }
            }
        }
    }

    /// Drop a session's toast (opening it, or a work/run/idle transition off it).
    func clearNotif(_ id: UUID) { notifs.removeAll { $0.id == id } }

    /// A background worktree op failed after its row already changed — raise a persistent
    /// system toast (no session behind it; it stays until clicked, never self-dismisses).
    /// Unfocused, Notification Center is alerted too, and the in-app card still waits so
    /// the failure is there when focus returns. The full git message goes to the log —
    /// the card is one line.
    func raiseWorktreeError(_ verb: String, branch: String, workspace: String, details: String) {
        NSLog("Synth: %@ (%@ · %@): %@", verb, branch, workspace, details)
        notifSeq += 1
        notifs.append(InAppNotif(id: UUID(), kind: .error, seq: notifSeq,
                                 sessionKind: .terminal, title: "\(branch) · \(workspace)",
                                 colorIndex: nil, outlivesSession: true,
                                 message: verb, iconPath: Phosphor.branch))
        if !NSApp.isActive {
            NotificationService.shared.postSystemError(title: verb,
                                                       body: "\(branch) · \(workspace)\n\(details)")
        }
    }

    /// Active toasts, most-urgent first: errors before needs-input before done, then newest
    /// within a kind (working.html `notifOrder`). Drops any whose session vanished (except
    /// the self-dismissing exit-close done toast) or is now the open one.
    var notifOrder: [InAppNotif] {
        notifs.filter { $0.id != openSessionID && (session($0.id) != nil || $0.outlivesSession) }.sorted { a, b in
            if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
            return a.seq > b.seq
        }
    }

    /// The ⌘↩ jump target — the most-urgent toast, or nil when the deck is empty (so the chord
    /// stays free otherwise, working.html `notifTop`).
    var topNotif: InAppNotif? { notifOrder.first }

    func jumpToTopNotif() {
        guard let n = topNotif else { return }
        // A system toast has nowhere to jump — ⌘↩ acknowledges (dismisses) it instead.
        if let s = session(n.id) { jump(to: s) } else { clearNotif(n.id) }
    }

    // MARK: Lookups

    var openSession: Session? { openSessionID.flatMap(session) }

    /// The branch whose setup skeleton the content pane is showing, or nil.
    var openSetupBranch: Branch? {
        guard let id = openSetupBranchID else { return nil }
        for ws in workspaces {
            if let br = ws.branches.first(where: { $0.id == id }) { return br }
        }
        return nil
    }

    func session(_ id: UUID) -> Session? {
        for ws in workspaces {
            for br in ws.branches {
                if let s = br.sessions.first(where: { $0.id == id }) { return s }
            }
        }
        return nil
    }

    func branch(of session: Session) -> Branch? {
        for ws in workspaces {
            for br in ws.branches where br.sessions.contains(where: { $0.id == session.id }) {
                return br
            }
        }
        return nil
    }

    func workspace(of branch: Branch) -> Workspace? {
        workspaces.first { $0.branches.contains { $0.id == branch.id } }
    }

    /// The branch whose worktree folder is `path` — the control socket's scope key
    /// (the MCP server sends $CLAUDE_PROJECT_DIR). Symlink-resolved on both sides so
    /// /tmp-style aliases still match.
    func branch(forWorktreePath path: String) -> Branch? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        for ws in workspaces {
            for br in ws.branches
            where br.worktreeURL.resolvingSymlinksInPath().standardizedFileURL.path == target {
                return br
            }
        }
        return nil
    }

    /// Working directory for a session: its branch's worktree folder (ADR-0007).
    func cwd(for session: Session) -> URL? {
        branch(of: session)?.worktreeURL
    }

    // MARK: Commands

    func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func open(_ session: Session) {
        settingsOpen = false   // jumping to a session leaves settings mode
        openSetupBranchID = nil   // opening a real session revokes any armed setup-resolve
        openSessionID = session.id
        navCursor = session.id
        session.unread = false
        clearNotif(session.id)   // opening a notified session dismisses its standing toast
    }

    /// Optimistically move the content pane onto a still-materialising worktree's
    /// "setting up…" skeleton — tying the switch to the create keystroke, so it can never
    /// surprise the user after an async gap. While this skeleton is what's shown the
    /// finished checkout resolves in place; opening anything else clears it, and the
    /// checkout then lands as a quiet unread row instead (applySessionTemplate).
    func openWorktreeSetup(_ branch: Branch) {
        settingsOpen = false
        openSessionID = nil
        openSetupBranchID = branch.id
        navCursor = branch.id
    }

    // MARK: Settings

    /// True when the settings page should render Global — either the scope is Global
    /// or it points at a workspace that no longer exists (dangling → Global).
    var settingsIsGlobal: Bool { settingsWorkspace == nil }

    /// The workspace the settings scope points at, or nil for Global / a dangling scope.
    var settingsWorkspace: Workspace? {
        guard case let .workspace(id) = settingsScope else { return nil }
        return workspaces.first { $0.id == id }
    }

    func enterSettings(_ scope: SettingsScope = .global) {
        activeMenu = nil
        closePalette()
        shortcutsOpen = false
        sidebarCollapsed = false
        openSetupBranchID = nil   // leaving for settings revokes any armed setup-resolve
        settingsScope = scope
        settingsOpen = true
        // Keyboard cursor lands on the active scope (working.html enterSettings → select .scope--on).
        navCursor = scopeCursorID(scope)
    }

    func exitSettings() {
        settingsOpen = false
        // Cursor returns to the tree — the open session if it's still visible, else the
        // Settings foot button we came from (working.html exitSettings).
        let visible = visibleRows.map(\.id)
        navCursor = openSessionID.flatMap { visible.contains($0) ? $0 : nil } ?? NavID.settingsFoot
    }

    /// Switch scope — the settings-nav twin of opening a session (working.html selectScope):
    /// used by both a scope-row click and ↵ on the cursor. Moves the cursor onto the scope.
    func selectScope(_ scope: SettingsScope) {
        settingsScope = scope
        navCursor = scopeCursorID(scope)
    }

    /// The cursor id for a scope: the Global sentinel, or the workspace's own id.
    func scopeCursorID(_ scope: SettingsScope) -> UUID {
        switch scope {
        case .global:            return NavID.scopeGlobal
        case let .workspace(id): return id
        }
    }

    func toggleSettings() { settingsOpen ? exitSettings() : enterSettings() }

    /// Palette jump: reveal the session (expand collapsed ancestors), open it, mark
    /// read — working.html's jumpTo, selection ring shown as if keyboard-driven.
    func jump(to session: Session) {
        if let br = branch(of: session) {
            expanded.insert(br.id)
            if let ws = workspace(of: br) { expanded.insert(ws.id) }
        }
        open(session)
        keyboardActive = true
    }

    func openPalette() {
        guard palette == nil else { return }
        activeMenu = nil
        palette = PaletteModel(store: self)
    }

    /// Closing while an agent prompt owns the confirm frame IS its "Not now" answer — it
    /// can't just vanish on a blocked MCP call (Esc / ⌘K / backdrop click all funnel here).
    func closePalette() {
        palette = nil
        guard let id = presentedAgentPromptID,
              let prompt = agentPrompts.first(where: { $0.id == id }) else {
            presentedAgentPromptID = nil
            return
        }
        resolveAgentPrompt(prompt, approved: false)
    }

    /// A row's ⋯ kebab opens the palette drilled to that row (working.html openRowActions),
    /// rather than the hover popover. Re-drills if the palette is already open.
    func openRowActions(_ ref: RowRef) {
        activeMenu = nil
        if palette == nil { palette = PaletteModel(store: self) }
        palette?.drill(to: ref)
    }

    /// `a` = add the row's natural child, dropping straight into its ⌘K frame: a worktree
    /// under a workspace (fuzzy branch search), a session under a worktree, or — on a
    /// session leaf — a sibling session in that leaf's parent worktree (working.html addToRow).
    /// Opens the palette if closed; if already open, resets to root then pushes the frame.
    func addToRow(_ ref: RowRef) {
        activeMenu = nil
        if palette == nil { palette = PaletteModel(store: self) }
        guard let pal = palette else { return }
        let frame: PaletteFrame?
        switch ref {
        case let .workspace(w): frame = pal.worktreeFrame(in: w)
        case let .branch(b):    frame = pal.newSessionFrame(branch: b)
        case let .session(s):   frame = branch(of: s).map { pal.newSessionFrame(branch: $0) }
        }
        guard let frame else { return }
        pal.stack = [pal.rootFrame()]
        pal.push(frame)
    }

    /// ⌘N — the new-session picker (terminal / agents / browser) for the branch you're in:
    /// the focused sidebar row's branch when the keyboard owns the sidebar, else the open
    /// session's, else the first available (working.html contextBranch → newSessionFrame).
    func newSessionPicker() {
        let contextual: Branch? = {
            guard keyboardActive, let ref = cursorRef else { return nil }
            switch ref {
            case let .branch(b):    return b
            case let .session(s):   return branch(of: s)
            case let .workspace(w): return w.branches.first { !$0.isPending }
            }
        }()
        guard let br = contextual ?? defaultBranch() else { return }
        activeMenu = nil
        if palette == nil { palette = PaletteModel(store: self) }
        guard let pal = palette else { return }
        pal.stack = [pal.rootFrame()]
        pal.push(pal.newSessionFrame(branch: br))
    }

    private func defaultBranch() -> Branch? {
        if let open = openSession, let br = branch(of: open) { return br }
        return workspaces.first?.branches.first { !$0.isPending }
    }

    @discardableResult
    func newTerminal(in branch: Branch? = nil) -> Session? {
        // A freshly opened shell sits at a prompt — nothing is running, so it starts idle.
        // Green (.running) is reserved for a terminal actually running a process.
        addSession(kind: .terminal, title: "shell", status: .idle, in: branch)
    }

    /// A coding agent is just a terminal that opened and ran the agent's binary, so it spawns
    /// identically — only the kind, title and starting state differ (working.html
    /// SESSION_KINDS/addSession). It opens straight into the content pane.
    @discardableResult
    func newAgent(_ agent: AgentID, in branch: Branch? = nil) -> Session? {
        let kind = SessionKind.agent(agent)
        return addSession(kind: kind, title: kind.tplStart, status: .working, in: branch)
    }

    /// A browser session (ADR-0011 stage one): titled "Browser" until it navigates, then
    /// named by its page (host+path). `url` non-nil pre-navigates — the popup path.
    /// Browsers carry no liveness of their own, so the row never shows an indicator
    /// and never raises status notifications — it stays .idle for life. `ownedBy` a
    /// claude row in the same branch makes it a contained browser (stage four) —
    /// nested, cascading, the deterministic comment target.
    ///
    /// `focus: false` is the agent-initiated path (MCP browser.create, popups off an
    /// owned browser): the row appears with the unread bullet instead of stealing the
    /// pane, and the engine boots detached so CDP callers can drive it before the
    /// user ever clicks the row — the pane adopts the live engine on first render.
    @discardableResult
    func newBrowser(in branch: Branch? = nil, at url: URL? = nil, ownedBy owner: Session? = nil,
                    focus: Bool = true) -> Session? {
        let session = addSession(kind: .browser,
                                 title: url?.browserHostPath ?? "Browser",
                                 status: .idle, in: branch, ownedBy: owner, focus: focus)
        session?.browserURL = url
        if let session, !focus {
            // Next runloop turn, same beat as a pane render would give it — creating
            // inside this call would nest a SwiftUI render pass in the engine's
            // creation pump (see BrowserManager.creating).
            DispatchQueue.main.async { _ = BrowserManager.shared.controller(for: session) }
        }
        return session
    }

    @discardableResult
    private func addSession(kind: SessionKind, title: String, status: SessionStatus,
                            in branch: Branch?, ownedBy owner: Session? = nil,
                            focus: Bool = true) -> Session? {
        // A pending branch has no checkout to run in yet — sessions wait for the worktree.
        guard let br = branch ?? defaultBranch(), !br.isPending else { return nil }
        let session = Session(kind: kind, title: title, status: status)
        br.sessions.append(session)
        if let owner { adopt(session, by: owner) }
        br.lastActivity = "now"
        // Either way the row must be visible in the sidebar — expand down to it.
        if let ws = workspace(of: br) { expanded.insert(ws.id) }
        expanded.insert(br.id)
        if focus {
            open(session)
        } else {
            // Agent-initiated: announce with the unread bullet, leave pane and cursor alone.
            session.unread = true
        }
        return session
    }

    func closeSession(_ session: Session) {
        // Containment cascade (ADR-0011 stage four): an owning claude row's browsers
        // live and die with it — the delete confirm names them before this runs.
        for browser in ownedBrowsers(of: session) { closeSession(browser) }
        // Cursor falls up the hierarchy to the branch row (working.html removeUnit fallback).
        if navCursor == session.id { navCursor = branch(of: session)?.id }
        TerminalManager.shared.terminate(session.id)
        BrowserManager.shared.terminate(session.id)
        for br in workspaces.flatMap(\.branches) {
            br.sessions.removeAll { $0.id == session.id }
        }
        if openSessionID == session.id { openSessionID = nil }
        liveAgentIDs.remove(session.id)
        detachSupervisor(session.kind.agentID ?? session.spawnedKind.agentID, session.id)
        pulseTokens.removeValue(forKey: session.id)
        reportedExitCodes.removeValue(forKey: session.id)
        // Drop this row's link-browser mapping whether it's the source terminal or the
        // browser itself that just closed.
        linkBrowsers[session.id] = nil
        linkBrowsers = linkBrowsers.filter { $0.value != session.id }
    }

    // MARK: Containment (ADR-0011 stage four: a browser can belong to an agent session)

    /// The agent row owning `session`, or nil — a dangling owner id (owner deleted out
    /// from under a snapshot) resolves to nil, i.e. the browser is effectively unowned.
    func owner(of session: Session) -> Session? {
        guard let id = session.ownerSessionID else { return nil }
        return branch(of: session)?.sessions.first { $0.id == id && $0.kind.isAgent }
    }

    /// The browsers an agent row owns, in sidebar order.
    func ownedBrowsers(of session: Session) -> [Session] {
        guard session.kind.isAgent, let br = branch(of: session) else { return [] }
        return br.sessions.filter { $0.ownerSessionID == session.id }
    }

    /// Make `browser` belong to `agent` (creation stamping, the kebab's "Attach to…", or a
    /// comment-spawned agent adopting its browser). Ownership keys off the Synth row id,
    /// so it survives agent exits and resumes.
    func adopt(_ browser: Session, by agent: Session) {
        guard browser.kind == .browser, agent.kind.isAgent,
              let br = branch(of: browser),
              br.sessions.contains(where: { $0.id == agent.id })
        else { return }
        browser.ownerSessionID = agent.id
        snapOwned(in: br)
    }

    /// Release `browser` back to an unowned branch-tier sibling — the cascade escape hatch.
    /// It keeps its slot just below the block it left (snapOwned pulls the still-owned
    /// rows up past it).
    func detach(_ browser: Session) {
        guard browser.ownerSessionID != nil, let br = branch(of: browser) else { return }
        browser.ownerSessionID = nil
        snapOwned(in: br)
    }

    /// Containment's array invariant: owned rows sit contiguously right after their owner,
    /// preserving relative order — the flat `br.sessions` order IS the sidebar order, so
    /// nesting is adjacency, not a second tree (working.html's snapOwned).
    private func snapOwned(in br: Branch) {
        var rows = br.sessions
        var ownedByOwner: [UUID: [Session]] = [:]
        let ownerIDs = Set(rows.filter { $0.kind.isAgent }.map(\.id))
        rows.removeAll { row in
            guard let o = row.ownerSessionID, ownerIDs.contains(o) else { return false }
            ownedByOwner[o, default: []].append(row)
            return true
        }
        br.sessions = rows.flatMap { [$0] + (ownedByOwner[$0.id] ?? []) }
    }

    /// Close-confirm copy for a session: closing an owning claude row cascades, so the
    /// confirm names what goes with it (both confirm surfaces — palette + `d` menu — share it).
    func deleteSessionHint(_ session: Session) -> String {
        let owned = ownedBrowsers(of: session)
        guard !owned.isEmpty else { return "Close this session?" }
        let what = owned.count == 1 ? "browser" : "\(owned.count) browsers"
        return "Close this session? This also closes its \(what)."
    }

    /// Whether closing `session` needs to ask first at all (ADR-0013): busy, because a turn
    /// would be lost, or it owns browsers, because closing cascades onto them too. An idle,
    /// unowned session just closes.
    func closeNeedsConfirm(_ session: Session) -> Bool {
        session.status.isBusy || !ownedBrowsers(of: session).isEmpty
    }

    /// The comment ladder's spawn rung (CommentMode rung 3): an agent row created exactly
    /// like `newAgent` but WITHOUT `open()` — the spawn is silent, focus stays on the
    /// browser pane. The caller mounts the row for a beat so its PTY boots
    /// (GhosttySurfaceView spawns on window attach), then returns to the browser.
    @discardableResult
    func spawnAgent(_ agent: AgentID, in branch: Branch) -> Session? {
        guard !branch.isPending else { return nil }
        let kind = SessionKind.agent(agent)
        let session = Session(kind: kind, title: kind.tplStart, status: .working)
        branch.sessions.append(session)
        branch.lastActivity = "now"
        if let ws = workspace(of: branch) { expanded.insert(ws.id) }
        expanded.insert(branch.id)
        return session
    }

    // MARK: Feedback (⌘⇧F)

    /// Resolved by `feedbackMode`: the author names a fix (title) and optionally details it
    /// (body), turning it into a real `feedback/<slug>` worktree with a Claude session already
    /// working it (seeded with title + body + captured context); everyone else gets a pre-filled
    /// email from the one box. Called from the sheet.
    func submitFeedback(_ raw: String) {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = feedbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        feedbackDraft = ""
        feedbackTitle = ""
        feedbackOpen = false
        switch feedbackMode {
        case .author:
            guard !title.isEmpty else { return }
            startFeedbackFix(title: title, body: body)
        case .email:
            guard !body.isEmpty else { return }
            openFeedbackEmail(body)
        }
    }

    /// Author path: cut a `feedback/<slug>` worktree off the open session's workspace and, once
    /// it lands, spawn a single Claude and seed it with the feedback + context — the comment-mode
    /// delivery loop pointed at Synth itself. Falls back to email if there's nowhere to host it.
    /// The slug is derived from the title the author gave and de-duplicated against existing
    /// branches, so a repeated gripe never collides `git worktree add` (its old failure mode).
    private func startFeedbackFix(title: String, body: String) {
        guard let ws = feedbackWorkspace() else { openFeedbackEmail(body.isEmpty ? title : body); return }
        let repo = ws.url
        let (branchName, planned) = uniqueFeedbackBranch(slug: Self.feedbackSlug(from: title), repo: repo)
        let gripe = body.isEmpty ? title : title + "\n\n" + body
        let seed = gripe + "\n\n" + captureFeedbackContext()
        let row = addBranchRow(in: ws, name: branchName, worktreeURL: planned, pending: true)
        materialize(row, in: ws, spawningTemplate: false, onReady: { [weak self] branch in
            self?.seedAgent(in: branch, seed: seed)
        }) {
            GitService.addWorktree(repo: repo, path: planned, newBranch: branchName, base: nil)
                .map { .failed($0) } ?? .ready(planned)
        }
        raiseFeedbackToast(.done, message: "On it", title: branchName)
    }

    /// Resolve `feedback/<slug>` to a name no existing branch or planned worktree dir already
    /// holds, suffixing `-2`, `-3`… on collision — so a repeated gripe (or the `note` fallback)
    /// can never hard-fail `git worktree add` with "a branch already exists".
    private func uniqueFeedbackBranch(slug: String, repo: URL) -> (branch: String, path: URL) {
        let taken = Set(GitService.allBranches(at: repo).map(\.name))
        var n = 1
        while true {
            let branch = n == 1 ? "feedback/\(slug)" : "feedback/\(slug)-\(n)"
            let path = GitService.plannedWorktreePath(repo: repo, branch: branch)
            if !taken.contains(branch) && !FileManager.default.fileExists(atPath: path.path) {
                return (branch, path)
            }
            n += 1
        }
    }

    /// Spawn a quiet agent in a freshly-materialized branch, mount it for a beat so its PTY
    /// boots (GhosttySurfaceView spawns on window attach), bounce focus back, then boot-and-wait
    /// for the supervisor's liveness signal and hand it the seed — mirroring CommentMode rung 3.
    /// Serves both seeded-worktree flows: the feedback fix and the synth-app handoff.
    private func seedAgent(in branch: Branch, seed: String) {
        guard let agent = AgentRegistry.default?.id,
              let session = spawnAgent(agent, in: branch) else { return }
        let previous = openSessionID
        open(session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.openSessionID == session.id,
                  let previous, let back = self.session(previous) else { return }
            self.open(back)
        }
        // SECURITY (CommentMode): only ever submit to a supervisor-confirmed-live agent — an
        // agent that never started leaves a bare shell, and Claude Code's delivery is a paste
        // plus Enter, i.e. arbitrary execution. Poll ~20s, settle a beat, re-check.
        Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(0.5))
                guard let self, self.isLiveAgent(session.id) else { continue }
                try? await Task.sleep(for: .seconds(1))
                guard self.isLiveAgent(session.id),
                      let supervisor = self.liveSupervisor(for: session) else { continue }
                if supervisor.deliver(seed, to: session.id) { return }
            }
            NSLog("Synth: seed never delivered (agent didn't report in)")
        }
    }

    /// Other path: open the user's mail client with a pre-filled draft. The body attaches only
    /// version/OS (no branch or session names leave the machine), capped for mailto's practical
    /// limit. No mail client → copy to the clipboard and say so.
    private func openFeedbackEmail(_ text: String) {
        let body = String((text + "\n\n— — —\n" + feedbackEnvLine() + "\n\nSent from Synth").prefix(1600))
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = FeedbackMode.recipient
        comps.queryItems = [URLQueryItem(name: "subject", value: "Synth feedback"),
                            URLQueryItem(name: "body", value: body)]
        if let url = comps.url, NSWorkspace.shared.open(url) {
            raiseFeedbackToast(.done, message: "Handed to Mail", title: "Synth feedback")
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            raiseFeedbackToast(.error, message: "No mail app — feedback copied", title: FeedbackMode.recipient)
        }
    }

    /// Where a feedback fix lands: author gripes are always about Synth, so target the Synth repo
    /// itself wherever it sits in the sidebar — never whatever workspace happens to be open (that
    /// could be some unrelated client repo). Falls back to the open session's workspace, then the
    /// first, only if Synth isn't among the workspaces at all.
    private func feedbackWorkspace() -> Workspace? {
        if let synth = workspaces.first(where: { Self.isSynthRepo($0.url) }) { return synth }
        if let s = openSession, let b = branch(of: s), let ws = workspace(of: b) { return ws }
        return workspaces.first
    }

    /// True when `repo`'s working tree is Synth's own source — its root carries the design HTML
    /// and the app sources together, a pairing no other repo has. Matches the main checkout or any
    /// of its worktrees (both carry the full tree).
    private static func isSynthRepo(_ repo: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: repo.appendingPathComponent("big-picture-design.html").path)
            && fm.fileExists(atPath: repo.appendingPathComponent("app/Sources/Synth/SynthApp.swift").path)
    }

    /// Structural facts only — what Synth is doing, never what you're building. Attached to the
    /// author seed silently; no file contents, paths, terminal output, env values or clipboard.
    func captureFeedbackContext() -> String {
        var lines: [String] = []
        if let s = openSession {
            let kind: String
            switch s.kind {
            case .agent:    kind = s.kind.tplStart
            case .terminal: kind = "Terminal"
            case .browser:  kind = "Browser"
            }
            lines.append("Here: \(kind) · \(branch(of: s)?.name ?? "—")")
        }
        let wsCount = workspaces.count
        let allSessions = workspaces.flatMap { $0.branches }.flatMap { $0.sessions }
        let working = allSessions.filter { if case .working = $0.status { return true } else { return false } }.count
        let unread = allSessions.filter(\.unread).count
        lines.append("State: \(wsCount) workspace\(wsCount == 1 ? "" : "s") · \(working) working · \(unread) unread")
        lines.append("Env: \(feedbackEnvLine())")
        return lines.joined(separator: "\n")
    }

    private func feedbackEnvLine() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = Bundle.main.bundleIdentifier != nil
            ? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") : "dev"
        return "Synth \(version) · macOS \(v.majorVersion).\(v.minorVersion) · \(themePref.rawValue) theme"
    }

    /// A title → a filesystem- and ref-safe branch slug: alphanumeric words, dash-joined, then
    /// capped at 48 chars so a pasted URL/hash can't push a single ref component past git's
    /// 255-byte limit (its old "File name too long" failure). Empty input falls back to "note".
    static func feedbackSlug(from text: String) -> String {
        let cleaned = String(text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " })
        let joined = cleaned.split(separator: " ").prefix(6).joined(separator: "-")
        var slug = String(joined.prefix(48))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "note" : slug
    }

    /// A session-less confirmation toast (mirrors `raiseWorktreeError`); `.done` self-dismisses.
    private func raiseFeedbackToast(_ kind: NotifKind, message: String, title: String) {
        notifSeq += 1
        let id = UUID()
        notifs.append(InAppNotif(id: id, kind: kind, seq: notifSeq, sessionKind: .terminal,
                                 title: title, colorIndex: nil, outlivesSession: true,
                                 message: message, iconPath: Phosphor.commentMode))
        if kind == .done {
            let seq = notifSeq
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.notifs.removeAll { $0.id == id && $0.seq == seq }
            }
        }
    }

    /// Folder picker → branch picker. Panel runs modally, so state mutation happens after dismiss.
    func promptAddWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a repository folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginAddWorkspace(url: url)
    }

    /// Discover branches + existing worktrees (off the main thread — `for-each-ref` on a
    /// large/cold repo can take a beat), then open the multi-select picker. A non-repo
    /// folder skips the picker (nothing to pick).
    func beginAddWorkspace(url: URL) {
        Task { [weak self] in
            guard let self else { return }
            let (branches, worktreeByBranch) = await runGit(repo: url) {
                () -> ([GitService.BranchInfo], [String: URL]) in
                let branches = GitService.branches(at: url)
                guard !branches.isEmpty else { return ([], [:]) }
                return (branches, Dictionary(
                    GitService.worktrees(at: url).compactMap { wt in wt.branch.map { ($0, wt.path) } },
                    uniquingKeysWith: { first, _ in first }
                ))
            }
            guard !branches.isEmpty else {
                finishAddWorkspace(url: url, branches: [])
                return
            }
            pendingWorkspace = PendingWorkspace(url: url, candidates: branches.map {
                BranchCandidate(name: $0.name,
                                age: GitService.compactAge($0.lastCommitUnix),
                                existingWorktree: worktreeByBranch[$0.name])
            })
        }
    }

    /// Materialise the chosen branches: existing worktrees become ready rows at once;
    /// the rest appear pending and check out in the background (features 2026-07-06) —
    /// the dialog never blocks the app on git.
    func confirmAddWorkspace(_ pending: PendingWorkspace, selected: Set<UUID>) {
        pendingWorkspace = nil
        var rows: [Branch] = []
        var creating: [Branch] = []
        for c in pending.candidates where selected.contains(c.id) {
            if let existing = c.existingWorktree {
                rows.append(Branch(name: c.name, worktreeURL: existing, lastActivity: c.age))
            } else {
                let path = GitService.plannedWorktreePath(repo: pending.url, branch: c.name)
                let row = Branch(name: c.name, worktreeURL: path, lastActivity: c.age, isPending: true)
                rows.append(row)
                creating.append(row)
            }
        }
        finishAddWorkspace(url: pending.url, branches: rows)
        guard let ws = workspaces.last else { return }
        for row in creating {
            let repo = pending.url, path = row.worktreeURL, name = row.name
            materialize(row, in: ws) {
                GitService.addWorktree(repo: repo, path: path, branch: name).map { .failed($0) }
                    ?? .ready(path)
            }
        }
    }

    private func finishAddWorkspace(url: URL, branches: [Branch]) {
        let ws = Workspace(
            name: url.lastPathComponent,
            url: url,
            branches: branches,
            colorIndex: workspaces.count % Theme.chipColors.count
        )
        workspaces.append(ws)   // collapsed by default
    }

    // MARK: Worktrees (ADR-0007: every branch row is a real folder)

    /// How a background create resolved: the row's real checkout, or git's message.
    private enum WorktreeOutcome: Sendable {
        case ready(URL)
        case failed(String)
    }

    /// Tail of each repo's background git chain. Worktree mutations on one repo are
    /// serialized — concurrent `git worktree` calls race the repo's locks — while
    /// different repos run independently. Ops run detached so a full checkout or a
    /// multi-GB delete never touches the main thread.
    @ObservationIgnored private var gitTails: [URL: Task<Void, Never>] = [:]

    /// Run `op` off the main thread, behind any in-flight op on `repo`, returning its
    /// result on the main actor.
    private func runGit<T: Sendable>(repo: URL, _ op: @escaping @Sendable () -> T) async -> T {
        let prev = gitTails[repo]
        let task = Task<T, Never> {
            await prev?.value
            return await Task.detached(priority: .userInitiated) { op() }.value
        }
        gitTails[repo] = Task { _ = await task.value }
        return await task.value
    }

    /// Run a background create for an already-visible pending row: success activates the
    /// row in place; failure drops it and raises the persistent error toast.
    /// `spawningTemplate` applies the scope's new-worktree session template once the
    /// checkout lands — the Create-worktree flows opt in; adding a workspace doesn't
    /// (those rows import existing branches, and N rows fighting to open a session each
    /// would be noise).
    private func materialize(_ row: Branch, in ws: Workspace, spawningTemplate: Bool = false,
                             onReady: ((Branch) -> Void)? = nil,
                             _ op: @escaping @Sendable () -> WorktreeOutcome) {
        let wsName = ws.name
        Task { [weak self] in
            guard let self else { return }
            switch await runGit(repo: ws.url, op) {
            case .ready(let url):
                row.worktreeURL = url
                row.isPending = false
                row.lastActivity = "now"
                if spawningTemplate { applySessionTemplate(to: row, in: ws) }
                onReady?(row)
                saveNow()
            case .failed(let err):
                removeBranch(row, deleteWorktree: false)
                raiseWorktreeError("Couldn't create worktree", branch: row.name,
                                   workspace: wsName, details: err)
            }
        }
    }

    /// Check an existing branch out into a worktree (reusing one if the branch already
    /// has it). The row appears pending immediately; the checkout lands in the background.
    func createWorktree(in ws: Workspace, existingBranch: String) {
        let repo = ws.url
        let planned = GitService.plannedWorktreePath(repo: repo, branch: existingBranch)
        let row = addBranchRow(in: ws, name: existingBranch, worktreeURL: planned, pending: true)
        openWorktreeSetup(row)
        materialize(row, in: ws, spawningTemplate: true) {
            if let wt = GitService.worktrees(at: repo).first(where: { $0.branch == existingBranch }) {
                return .ready(wt.path)
            }
            return GitService.addWorktree(repo: repo, path: planned, branch: existingBranch)
                .map { .failed($0) } ?? .ready(planned)
        }
    }

    /// Cut a new branch off `base` (repo HEAD when nil) into a fresh worktree — same
    /// pending-row shape as the existing-branch path.
    func createWorktree(in ws: Workspace, newBranch: String, base: String?) {
        let repo = ws.url
        let planned = GitService.plannedWorktreePath(repo: repo, branch: newBranch)
        let row = addBranchRow(in: ws, name: newBranch, worktreeURL: planned, pending: true)
        openWorktreeSetup(row)
        materialize(row, in: ws, spawningTemplate: true) {
            GitService.addWorktree(repo: repo, path: planned, newBranch: newBranch, base: base)
                .map { .failed($0) } ?? .ready(planned)
        }
    }

    // MARK: Agent-requested worktrees (the synth-app MCP server's one verb so far)

    /// Validate an agent's worktree request and, when it needs the user, queue the
    /// approval prompt. Runs on the control connection's main-sync hop, so nothing here
    /// may block: existing-vs-new branch is decided later, inside the background git op.
    func beginAgentWorktreePrompt(_ request: [String: Any],
                                  respond: @escaping ([String: Any]) -> Void) -> AgentPromptStart {
        guard mcpAppEnabled else {
            return .immediate(["ok": false, "error":
                "the Synth app MCP server is turned off — enable it in Synth Settings → MCP servers"])
        }
        guard let worktreePath = request["worktreePath"] as? String,
              let callerBranch = branch(forWorktreePath: worktreePath),
              let ws = workspace(of: callerBranch) else {
            return .immediate(["ok": false, "error":
                "no Synth branch manages worktree \(request["worktreePath"] ?? "<missing>")"])
        }
        guard let name = (request["branch"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return .immediate(["ok": false, "error": "need branch"])
        }
        // Idempotence: a branch that's already a row needs no prompt and no git — hand
        // back its checkout and let the agent proceed.
        if let row = ws.branches.first(where: { $0.name == name }) {
            return .immediate(["ok": true, "decision": "exists",
                               "worktreePath": row.worktreeURL.path])
        }
        if agentPrompts.contains(where: { $0.workspace === ws && $0.branchName == name }) {
            return .immediate(["ok": false, "error":
                "a prompt for \(name) is already awaiting the user's answer"])
        }
        let requester = (request["ownerSessionId"] as? String)
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in callerBranch.sessions.first { $0.id == id && $0.kind.isAgent } }
        let prompt = AgentWorktreePrompt(
            workspace: ws,
            branchName: name,
            base: (request["base"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            handoff: (request["handoff"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            requesterTitle: requester?.title,
            respond: respond)
        agentPrompts.append(prompt)
        presentAgentPrompt(prompt)
        return .pending(prompt.id)
    }

    /// Surfaces an agent prompt as the ⌘K confirm frame (was a modal sheet) — interrupts
    /// whatever the palette was showing, same as the sheet interrupted the app.
    private func presentAgentPrompt(_ prompt: AgentWorktreePrompt) {
        if palette == nil { palette = PaletteModel(store: self) }
        guard let pal = palette else { return }
        presentedAgentPromptID = prompt.id
        pal.stack = [pal.rootFrame(), pal.confirmAgentWorktree(prompt)]
        pal.query = ""
        pal.activeIndex = 0
    }

    /// After a prompt leaves the queue (resolved or cancelled), keep the palette in sync:
    /// chain to the next pending prompt, or close if none remain — only when the palette's
    /// confirm frame actually belonged to the prompt that just left.
    private func advanceAgentPromptPresentation(from id: UUID) {
        guard presentedAgentPromptID == id else { return }
        presentedAgentPromptID = nil
        if let next = agentPrompts.first { presentAgentPrompt(next) }
        else { closePalette() }
    }

    /// The confirm frame's two items. Approve cuts the worktree exactly like ⌘K
    /// "Create worktree" (pending row, background checkout, pane onto the setup
    /// skeleton — the jump rides the user's Create click) and answers the blocked MCP
    /// call; decline just answers it.
    func resolveAgentPrompt(_ prompt: AgentWorktreePrompt, approved: Bool) {
        guard let i = agentPrompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        agentPrompts.remove(at: i)
        advanceAgentPromptPresentation(from: prompt.id)
        guard approved else {
            prompt.respond(["ok": true, "decision": "declined"])
            return
        }
        let planned = agentCreateWorktree(prompt)
        prompt.respond(["ok": true, "decision": "created",
                        "branch": prompt.branchName, "worktreePath": planned.path])
    }

    /// The MCP server gave up waiting — drop the prompt so a stale question isn't
    /// answered into a dead socket. False when it was already resolved (that race is
    /// the caller's to read).
    @discardableResult
    func cancelAgentPrompt(_ id: UUID) -> Bool {
        guard let i = agentPrompts.firstIndex(where: { $0.id == id }) else { return false }
        agentPrompts.remove(at: i)
        advanceAgentPromptPresentation(from: id)
        return true
    }

    /// The approved create. Existing-vs-new is decided inside the background op (a git
    /// scan mustn't run on the approval click's main hop): a branch with a worktree
    /// reuses it, an existing local/remote branch checks out (`worktree add` DWIMs
    /// remote-tracking names), anything else is cut off `base`. A handoff swaps the
    /// session template for one seeded Claude — the feedback loop's delivery path.
    private func agentCreateWorktree(_ prompt: AgentWorktreePrompt) -> URL {
        let ws = prompt.workspace
        let repo = ws.url
        let name = prompt.branchName
        let base = prompt.base
        let planned = GitService.plannedWorktreePath(repo: repo, branch: name)
        let row = addBranchRow(in: ws, name: name, worktreeURL: planned, pending: true)
        openWorktreeSetup(row)
        let onReady: ((Branch) -> Void)? = prompt.handoff.map { seed in
            { [weak self] branch in self?.seedAgent(in: branch, seed: seed) }
        }
        materialize(row, in: ws, spawningTemplate: prompt.handoff == nil, onReady: onReady) {
            if let wt = GitService.worktrees(at: repo).first(where: { $0.branch == name }) {
                return .ready(wt.path)
            }
            if GitService.allBranches(at: repo).contains(where: { $0.name == name }) {
                return GitService.addWorktree(repo: repo, path: planned, branch: name)
                    .map { .failed($0) } ?? .ready(planned)
            }
            return GitService.addWorktree(repo: repo, path: planned, newBranch: name, base: base)
                .map { .failed($0) } ?? .ready(planned)
        }
        return planned
    }

    /// The fast delete path (features 2026-07-06): the row is already gone; the folder is
    /// renamed aside + pruned (O(1)) behind any in-flight op on the repo, and the real
    /// delete runs afterwards where nobody waits on it. A failed rename falls back to the
    /// blocking `git worktree remove` — still off the main thread.
    func deleteWorktreeFolder(repo: URL, path: URL, branchName: String, workspaceName: String) {
        Task { [weak self] in
            guard let self else { return }
            let err = await runGit(repo: repo) { () -> String? in
                guard FileManager.default.fileExists(atPath: path.path) else {
                    GitService.pruneWorktrees(at: repo)   // gone already — just tidy the entry
                    return nil
                }
                if let trash = GitService.detachWorktree(repo: repo, path: path) {
                    Task.detached(priority: .background) { try? FileManager.default.removeItem(at: trash) }
                    return nil
                }
                return GitService.removeWorktree(repo: repo, path: path)
            }
            if let err {
                raiseWorktreeError("Couldn't delete worktree", branch: branchName,
                                   workspace: workspaceName, details: err)
            }
        }
    }

    @discardableResult
    private func addBranchRow(in ws: Workspace, name: String, worktreeURL: URL, pending: Bool = false) -> Branch {
        let branch = Branch(name: name, worktreeURL: worktreeURL,
                            lastActivity: pending ? "" : "now", isPending: pending)
        ws.branches.append(branch)
        expanded.insert(ws.id)
        navCursor = branch.id
        return branch
    }

    /// Spawn the scope's new-worktree session template into a just-materialized row
    /// (working.html addBranch): entries in creation order, the first one opens; the
    /// rest wait dormant like restored rows — their process starts on first open, so
    /// only the opened session touches the PTY layer. A name differing from the kind's
    /// stock start counts as hand-picked (titleIsCustom), so auto-naming — ai-title,
    /// running command, page title — never overwrites a template name the user chose.
    private func applySessionTemplate(to branch: Branch, in ws: Workspace) {
        // Whether the user is still parked on this row's setup skeleton decides the whole
        // handoff: still here → resolve in place; moved on → don't touch the viewport.
        let watching = openSetupBranchID == branch.id
        let entries = sessionTemplate(for: ws)
        guard !entries.isEmpty else {
            // An emptied template means "start bare": nothing to open. If we're still on
            // the skeleton, drop it so the pane settles onto the now-ready (empty) row.
            if watching { openSetupBranchID = nil }
            return
        }
        let sessions = entries.enumerated().map { i, entry in
            Session(kind: entry.kind, title: entry.name,
                    status: entry.kind.isAgent && i == 0 ? .working : .idle,
                    titleIsCustom: entry.name != entry.kind.tplStart)
        }
        branch.sessions.append(contentsOf: sessions)
        branch.lastActivity = "now"
        expanded.insert(ws.id)
        expanded.insert(branch.id)
        if watching, let first = sessions.first {
            open(first)   // last intent still points here — resolve the skeleton in place
        } else {
            // The user moved on after requesting — announce the ready worktree with the
            // quiet unread bullet (browser-ownership idiom) instead of stealing the pane.
            sessions.first?.unread = true
        }
    }

    // MARK: Persistence (ADR-0010)

    /// Snapshot the durable tree for disk — everything that isn't a live-process fact.
    private func snapshot() -> PersistedState {
        PersistedState(
            version: PersistenceStore.schemaVersion,
            workspaces: workspaces.map { ws in
                PersistedWorkspace(
                    id: ws.id, name: ws.name, url: ws.url, colorIndex: ws.colorIndex,
                    // Pending rows are still being created — a quit mid-create must not
                    // restore a row whose checkout may never have landed.
                    branches: ws.branches.filter { !$0.isPending }.map { br in
                        PersistedBranch(
                            id: br.id, name: br.name, worktreeURL: br.worktreeURL,
                            lastActivity: br.lastActivity,
                            sessions: br.sessions.map { s in
                                PersistedSession(id: s.id, kind: s.kind.rawValue, title: s.title,
                                                 titleIsCustom: s.titleIsCustom,
                                                 agentSessionID: s.agentSessionID,
                                                 browserURL: s.browserURL,
                                                 ownerSessionID: s.ownerSessionID)
                            },
                            browserRecents: br.browserRecents.isEmpty ? nil : br.browserRecents)
                    },
                    setupScript: wsScripts[ws.id],
                    agentFlags: wsAgentFlags[ws.id].map { flags in
                        flags.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
                    },
                    // nil when empty: an empty workspace list means "inherit global",
                    // the same fact as having no list at all.
                    sessionTemplate: (wsSessionTemplates[ws.id]?.isEmpty ?? true)
                        ? nil : wsSessionTemplates[ws.id])
            },
            // Sorted so an unchanged set always encodes to identical bytes (Set iteration
            // order is per-process nondeterministic) — the skip-if-unchanged check relies on it.
            expanded: expanded.sorted { $0.uuidString < $1.uuidString },
            globalScript: globalScript,
            globalAgentFlags: globalAgentFlags.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value },
            globalSessionTemplate: globalSessionTemplate
        )
    }

    /// Rebuild the tree from a snapshot, reconciling against disk: a workspace or branch
    /// folder that was *confirmed deleted* (see `confirmedMissing`) is dropped — the user
    /// removed it outside Synth. A folder that's merely unreachable (unmounted volume,
    /// offline network path) is kept, so a transient absence never silently and permanently
    /// erases rows. Sessions come back dormant — kind/title/name only, status `.idle`, no
    /// live process; opening one respawns a shell (a Claude row resumes). Stale expansion
    /// ids for pruned rows are discarded.
    private func restore(from state: PersistedState) {
        var restored: [Workspace] = []
        var scripts: [UUID: String] = [:]
        var flags: [UUID: [AgentID: String]] = [:]
        var templates: [UUID: [SessionTemplateEntry]] = [:]
        for pw in state.workspaces {
            guard !confirmedMissing(pw.url) else { continue }
            let branches: [Branch] = pw.branches.compactMap { pb -> Branch? in
                guard !confirmedMissing(pb.worktreeURL) else { return nil }
                let sessions = pb.sessions.map { ps in
                    Session(id: ps.id, kind: SessionKind(rawValue: ps.kind) ?? .terminal,
                            title: ps.title, status: .idle, titleIsCustom: ps.titleIsCustom,
                            agentSessionID: ps.resumeID, browserURL: ps.browserURL,
                            ownerSessionID: ps.ownerSessionID)
                }
                // Scrub hostless recents (about:blank) recorded before the filter existed.
                let recents = (pb.browserRecents ?? []).filter { URL(string: $0.url)?.host != nil }
                return Branch(id: pb.id, name: pb.name, worktreeURL: pb.worktreeURL,
                              sessions: sessions, lastActivity: pb.lastActivity,
                              browserRecents: recents)
            }
            restored.append(Workspace(id: pw.id, name: pw.name, url: pw.url,
                                      branches: branches, colorIndex: pw.colorIndex))
            if let s = pw.setupScript { scripts[pw.id] = s }
            if let f = pw.effectiveAgentFlags { flags[pw.id] = f }
            if let t = pw.sessionTemplate, !t.isEmpty { templates[pw.id] = t }
        }
        workspaces = restored
        wsScripts = scripts
        wsAgentFlags = flags
        wsSessionTemplates = templates
        // Global settings: a nil (pre-settings snapshot) keeps the built-in default. A
        // pre-agents snapshot carries only Claude's flags — merge, don't replace, or the
        // other agents' defaults vanish.
        if let gs = state.globalScript { globalScript = gs }
        if let gf = state.effectiveGlobalAgentFlags { globalAgentFlags.merge(gf) { _, new in new } }
        if let gt = state.globalSessionTemplate { globalSessionTemplate = gt }
        let liveIDs = Set(restored.flatMap { ws in
            [ws.id] + ws.branches.flatMap { [$0.id] + $0.sessions.map(\.id) }
        })
        expanded = Set(state.expanded).intersection(liveIDs)
    }

    /// True only when a folder is *confirmed deleted*: its parent directory exists but the
    /// folder itself doesn't. If the parent is also absent (unmounted volume, missing
    /// ancestor) the answer is false — the path is unreachable, not deleted, so we keep it.
    private func confirmedMissing(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return false }
        return fm.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    /// Persist on a low cadence (backstop for any mutation) plus a flush on quit — cmux's
    /// timer-over-instrumentation model, so no mutation site can forget to save. The
    /// skip-if-unchanged check in the store keeps the idle case free.
    private func startAutosave() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                self.saveNow()
            }
        }
        // queue: nil so the block runs synchronously on the posting (main) thread — NSApp
        // posts willTerminate then exit()s in the same stack, so an async .main hop would
        // never fire. assumeIsolated is then the correct guard.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveNow()
                // Engines must not outlive the app: a surviving instance owns the profile
                // singleton and silently absorbs the next launch (BrowserEngine.shutdown docs).
                BrowserManager.shared.shutdownAll()
            }
        }
    }

    func saveNow() {
        lastSavedBytes = PersistenceStore.save(snapshot(), lastBytes: lastSavedBytes)
        syncAgentBridge()
    }

    #if DEBUG
    // Design-time notification harness (working.html's ⌥N demo). Fires fake transitions on
    // real background sessions so the deck, hover-fan, ⌘↩-jump, "+N" and ambient pulse are
    // observable without live session events. `force` lets a driven (non-frontmost) instance
    // still exercise either surface. Left `#if DEBUG`-gated for the maintainer to keep or cut.
    @ObservationIgnored private var debugCursor = 0

    /// ⌥F — force the deck's hover-fan open (the pointer can't reach an inactive window when
    /// driven headless), so the fanned state is screenshottable.
    var debugDeckSpread = false

    /// Sessions the deck may notify — everything except the open one (working.html demo `bg`).
    private var debugBackground: [Session] {
        workspaces.flatMap { $0.branches.flatMap(\.sessions) }.filter { $0.id != openSessionID }
    }

    private func debugReveal(_ s: Session) {
        guard let br = branch(of: s) else { return }
        expanded.insert(br.id)
        if let ws = workspace(of: br) { expanded.insert(ws.id) }
    }

    /// ⌥N — escalate the next background session; kinds cycle (mostly needs-input, every third
    /// an error) so successive presses grow a deck with real ordering and a "+N" past three.
    func debugRaiseNext(force: NotifRoute) {
        let bg = debugBackground
        guard !bg.isEmpty else { return }
        let s = bg[debugCursor % bg.count]
        debugReveal(s)
        let next: SessionStatus = (debugCursor % 3 == 1) ? .error : .needsInput
        debugCursor += 1
        let prev = s.status
        s.status = next
        routeTransition(s.id, prev: prev, next: next, force: force)
    }

    /// ⌥D — walk the next background session live→idle to fire "done" (row pulse + a transient
    /// toast on a terminal/browser, or a Notification Center banner when forced there).
    func debugFireDone(force: NotifRoute) {
        let bg = debugBackground
        guard !bg.isEmpty else { return }
        let s = bg[debugCursor % bg.count]
        debugReveal(s)
        debugCursor += 1
        s.status = .idle
        routeTransition(s.id, prev: .running, next: .idle, force: force)
    }

    /// ⌥C — clear every standing toast (reset the deck).
    func debugClearNotifs() { notifs.removeAll() }
    #endif
}
