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
    /// A terminal was detected running Claude Code (or stopped) — flips the row's visual.
    case kindChanged(UUID, SessionKind)
    /// A background session finished a turn — surface it unless it's the one on screen.
    case markUnread(UUID)
    /// Claude Code reported its own session id (via the SessionStart hook) — stored so a
    /// restored row can resume the conversation with `claude --resume` (ADR-0010).
    case claudeSessionCaptured(UUID, String)
    /// A browser session's address changed — every navigation, including ones the engine's
    /// future CDP clients initiate (ADR-0011). Renames the row and feeds the branch recents.
    case browserNavigated(UUID, URL)
    /// The page's document title — auto-names the session row (URL host+path stands as the
    /// fallback until it arrives) and labels the recents entry.
    case browserPageTitled(UUID, String)
    /// window.open / target=_blank: one page per session, so a popup becomes a NEW
    /// browser session in the same branch, pre-navigated and selected.
    case browserPopupRequested(UUID, URL)
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

/// The escalated sidebar indicator a background session raises as a toast: needs-input is
/// the blue `?` (`Theme.attention`), error the terracotta `!` (`Theme.danger`), and — for
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

/// The durable, observed source of truth. Holds only the low-frequency facts the
/// UI reads: the tree, per-session status, expansion, and the two selection fields
/// (nav cursor + open session) from docs/adr/0005.
@MainActor @Observable final class AppStore {
    var workspaces: [Workspace] = []
    var expanded: Set<UUID> = []
    var navCursor: UUID?
    var openSessionID: UUID?
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
    var soundNeedsInput = AppStore.loadSoundPref(AppStore.soundInputKey, default: true) {
        didSet { UserDefaults.standard.set(soundNeedsInput, forKey: AppStore.soundInputKey) }
    }
    var soundError = AppStore.loadSoundPref(AppStore.soundErrorKey, default: true) {
        didSet { UserDefaults.standard.set(soundError, forKey: AppStore.soundErrorKey) }
    }
    var soundDone = AppStore.loadSoundPref(AppStore.soundDoneKey, default: false) {
        didSet { UserDefaults.standard.set(soundDone, forKey: AppStore.soundDoneKey) }
    }
    static let soundInputKey = "synth-sound-input"
    static let soundErrorKey = "synth-sound-error"
    static let soundDoneKey  = "synth-sound-done"
    /// UserDefaults' `bool(forKey:)` can't tell "unset" from `false`, so read the object and
    /// fall back to the type's default only when it's genuinely absent.
    static func loadSoundPref(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }

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

    /// Default flags passed to `claude` when a Claude Code session starts (no claude
    /// auto-launch is wired up yet — see FEATURES). The raw string is the source of truth,
    /// so ANY claude flag works; the Settings switches are shortcuts for common ones.
    /// A workspace's flags OVERRIDE the global outright — unlike the setup scripts, flags
    /// don't compose; the last word wins. An empty workspace value inherits global.
    var globalClaudeFlags = "--dangerously-skip-permissions"
    var wsClaudeFlags: [UUID: String] = [:]

    /// The effective flags for a scope. A workspace with its own flags replaces the global
    /// outright; an empty (or absent) workspace value inherits global.
    func claudeFlags(for workspace: Workspace?) -> String {
        let w = (workspace.flatMap { wsClaudeFlags[$0.id] } ?? "").trimmingCharacters(in: .whitespaces)
        if !w.isEmpty { return w }
        return globalClaudeFlags.trimmingCharacters(in: .whitespaces)
    }

    /// Session ids with a LIVE Claude Code attached THIS run — asserted only by the hook
    /// seam (claude-start / claudeSessionCaptured; cleared by claude-end / process exit).
    /// A persisted `.claudeCode` kind is NOT liveness: a restored row whose `--resume`
    /// fails drops to a bare shell, and pasting a browser comment there (page-controlled
    /// text submitted with Enter) would hand the page shell execution. Comment delivery
    /// gates on this set (CommentModeController.deliver).
    private(set) var liveClaudeIDs: Set<UUID> = []
    /// Last hook activity per claude session — deterministic most-recently-active targeting.
    @ObservationIgnored private var claudeSeenAt: [UUID: Date] = [:]

    func isLiveClaude(_ id: UUID) -> Bool { liveClaudeIDs.contains(id) }
    func claudeActivity(_ id: UUID) -> Date { claudeSeenAt[id] ?? .distantPast }

    let bus = EventBus()
    let hookServer: HookServer
    /// Stage-two control socket (ADR-0011): browser.list / browser.create for the
    /// bundled MCP server. Request/response, so separate from the one-way hook socket.
    @ObservationIgnored private var controlServer: ControlServer!

    /// Bytes of the last snapshot written — lets the autosave skip an unchanged rewrite
    /// (ADR-0010). @ObservationIgnored: a bookkeeping field, not UI state.
    @ObservationIgnored private var lastSavedBytes: Data?

    init() {
        hookServer = HookServer(bus: bus)
        TerminalManager.shared.bus = bus
        BrowserManager.shared.bus = bus
        TerminalManager.shared.hookSocketPath = hookServer.socketPath
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
    /// Runs at init and on the autosave cadence (both skip unchanged sets), so no
    /// workspace/branch mutation site can forget it — the autosave model.
    private func syncAgentBridge() {
        let paths = workspaces.flatMap { $0.branches.map(\.worktreeURL.path) }
        InstanceRegistry.shared.update(worktreePaths: paths)
        MCPInstaller.syncWorktreeConfigs(paths)
    }

    // MARK: Bus → store

    private func apply(_ event: SessionEvent) {
        switch event {
        case let .statusChanged(id, status):
            guard let s = session(id) else { break }
            if liveClaudeIDs.contains(id) { claudeSeenAt[id] = Date() }
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
            // Keep a hand-picked name; otherwise fall back to the neutral Claude default until
            // the new conversation generates its own ai-title (arriving as .titleChanged).
            if let s = session(id), !s.titleIsCustom { s.title = "Claude Code" }
        case let .exited(id, code):
            guard let s = session(id) else { break }
            let prev = s.status
            let next: SessionStatus = (code ?? 0) == 0 ? .exited(code) : .error
            s.status = next
            liveClaudeIDs.remove(id)
            routeTransition(id, prev: prev, next: next)
        case let .kindChanged(id, kind):
            session(id)?.kind = kind
            // The hook seam's claude lifecycle: claude-start posts .claudeCode, claude-end
            // posts .terminal (HookServer.apply) — the only writers of comment-target liveness.
            if kind == .claudeCode {
                liveClaudeIDs.insert(id)
                claudeSeenAt[id] = Date()
            } else {
                liveClaudeIDs.remove(id)
            }
        case let .markUnread(id): if openSessionID != id { session(id)?.unread = true }
        case let .claudeSessionCaptured(id, claudeID):
            if let s = session(id), s.claudeSessionID != claudeID { s.claudeSessionID = claudeID }
            liveClaudeIDs.insert(id)
            claudeSeenAt[id] = Date()
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
            newBrowser(in: branch(of: s), at: url)
        }
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
    func routeTransition(_ id: UUID, prev: SessionStatus, next: SessionStatus, force: NotifRoute? = nil) {
        if openSessionID == id { clearNotif(id); return }
        let toNC = force.map { $0 == .notificationCenter } ?? !NSApp.isActive
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
                raiseInApp(id, .done)
            }
        default:
            clearNotif(id)   // work / run (and idle-from-idle) clear any standing toast
        }
    }

    /// Raise (or re-raise, bumping it to newest) a background session's toast. A done toast
    /// asks for nothing, so it dismisses itself; the seq check keeps the timer from killing
    /// a newer toast the same session raised in the meantime.
    private func raiseInApp(_ id: UUID, _ kind: NotifKind) {
        notifSeq += 1
        notifs.removeAll { $0.id == id }
        notifs.append(InAppNotif(id: id, kind: kind, seq: notifSeq))
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

    /// Active toasts, most-urgent first: errors before needs-input before done, then newest
    /// within a kind (working.html `notifOrder`). Drops any whose session vanished or is now
    /// the open one.
    var notifOrder: [InAppNotif] {
        notifs.filter { $0.id != openSessionID && session($0.id) != nil }.sorted { a, b in
            if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
            return a.seq > b.seq
        }
    }

    /// The ⌘↩ jump target — the most-urgent toast, or nil when the deck is empty (so the chord
    /// stays free otherwise, working.html `notifTop`).
    var topNotif: InAppNotif? { notifOrder.first }

    func jumpToTopNotif() {
        if let n = topNotif, let s = session(n.id) { jump(to: s) }
    }

    // MARK: Lookups

    var openSession: Session? { openSessionID.flatMap(session) }

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
        openSessionID = session.id
        navCursor = session.id
        session.unread = false
        clearNotif(session.id)   // opening a notified session dismisses its standing toast
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

    func closePalette() { palette = nil }

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

    private func defaultBranch() -> Branch? {
        if let open = openSession, let br = branch(of: open) { return br }
        return workspaces.first?.branches.first
    }

    @discardableResult
    func newTerminal(in branch: Branch? = nil) -> Session? {
        // A freshly opened shell sits at a prompt — nothing is running, so it starts idle.
        // Green (.running) is reserved for a terminal actually running a process.
        addSession(kind: .terminal, title: "shell", status: .idle, in: branch)
    }

    /// Claude Code is just a terminal that opened and ran `claude`, so it spawns
    /// identically — only the kind, title and starting state differ (working.html
    /// SESSION_KINDS/addSession). It opens straight into the content pane.
    @discardableResult
    func newClaude(in branch: Branch? = nil) -> Session? {
        addSession(kind: .claudeCode, title: "Claude Code", status: .working, in: branch)
    }

    /// A browser session (ADR-0011 stage one): titled "Browser" until it navigates, then
    /// named by its page (host+path). `url` non-nil pre-navigates — the popup path.
    /// Browsers carry no liveness of their own, so the row never shows an indicator
    /// and never raises status notifications — it stays .idle for life.
    @discardableResult
    func newBrowser(in branch: Branch? = nil, at url: URL? = nil) -> Session? {
        let session = addSession(kind: .browser,
                                 title: url?.browserHostPath ?? "Browser",
                                 status: .idle, in: branch)
        session?.browserURL = url
        return session
    }

    @discardableResult
    private func addSession(kind: SessionKind, title: String, status: SessionStatus, in branch: Branch?) -> Session? {
        guard let br = branch ?? defaultBranch() else { return nil }
        let session = Session(kind: kind, title: title, status: status)
        br.sessions.append(session)
        br.lastActivity = "now"
        if let ws = workspace(of: br) { expanded.insert(ws.id) }
        expanded.insert(br.id)
        open(session)
        return session
    }

    func closeSession(_ session: Session) {
        TerminalManager.shared.terminate(session.id)
        BrowserManager.shared.terminate(session.id)
        for br in workspaces.flatMap(\.branches) {
            br.sessions.removeAll { $0.id == session.id }
        }
        if openSessionID == session.id { openSessionID = nil }
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

    /// Discover branches + existing worktrees, then open the multi-select picker.
    /// A non-repo folder skips the picker (nothing to pick).
    func beginAddWorkspace(url: URL) {
        let branches = GitService.branches(at: url)
        guard !branches.isEmpty else {
            finishAddWorkspace(url: url, branches: [])
            return
        }
        let worktreeByBranch = Dictionary(
            GitService.worktrees(at: url).compactMap { wt in wt.branch.map { ($0, wt.path) } },
            uniquingKeysWith: { first, _ in first }
        )
        pendingWorkspace = PendingWorkspace(url: url, candidates: branches.map {
            BranchCandidate(name: $0.name,
                            age: GitService.compactAge($0.lastCommitUnix),
                            existingWorktree: worktreeByBranch[$0.name])
        })
    }

    /// Materialise the chosen branches — reusing existing worktrees, creating the
    /// missing ones — and add the workspace.
    func confirmAddWorkspace(_ pending: PendingWorkspace, selected: Set<UUID>) {
        pendingWorkspace = nil
        var rows: [Branch] = []
        var failures: [String] = []
        for c in pending.candidates where selected.contains(c.id) {
            let path: URL
            if let existing = c.existingWorktree {
                path = existing
            } else {
                path = GitService.plannedWorktreePath(repo: pending.url, branch: c.name)
                if let err = GitService.addWorktree(repo: pending.url, path: path, branch: c.name) {
                    failures.append("\(c.name): \(err)")
                    continue
                }
            }
            rows.append(Branch(name: c.name, worktreeURL: path, lastActivity: c.age))
        }
        finishAddWorkspace(url: pending.url, branches: rows)
        if !failures.isEmpty {
            presentGitError("Some worktrees couldn't be created", details: failures.joined(separator: "\n"))
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

    /// Check an existing branch out into a worktree (reusing one if the branch
    /// already has it) and add the row. Returns git's error message, or nil.
    @discardableResult
    func createWorktree(in ws: Workspace, existingBranch: String) -> String? {
        if let wt = GitService.worktrees(at: ws.url).first(where: { $0.branch == existingBranch }) {
            addBranchRow(in: ws, name: existingBranch, worktreeURL: wt.path)
            return nil
        }
        let path = GitService.plannedWorktreePath(repo: ws.url, branch: existingBranch)
        if let err = GitService.addWorktree(repo: ws.url, path: path, branch: existingBranch) { return err }
        addBranchRow(in: ws, name: existingBranch, worktreeURL: path)
        return nil
    }

    /// Cut a new branch off `base` (repo HEAD when nil) into a fresh worktree.
    @discardableResult
    func createWorktree(in ws: Workspace, newBranch: String, base: String?) -> String? {
        let path = GitService.plannedWorktreePath(repo: ws.url, branch: newBranch)
        if let err = GitService.addWorktree(repo: ws.url, path: path, newBranch: newBranch, base: base) {
            return err
        }
        addBranchRow(in: ws, name: newBranch, worktreeURL: path)
        return nil
    }

    private func addBranchRow(in ws: Workspace, name: String, worktreeURL: URL) {
        let branch = Branch(name: name, worktreeURL: worktreeURL, lastActivity: "now")
        ws.branches.append(branch)
        expanded.insert(ws.id)
        navCursor = branch.id
    }

    // MARK: Persistence (ADR-0010)

    /// Snapshot the durable tree for disk — everything that isn't a live-process fact.
    private func snapshot() -> PersistedState {
        PersistedState(
            version: PersistenceStore.schemaVersion,
            workspaces: workspaces.map { ws in
                PersistedWorkspace(
                    id: ws.id, name: ws.name, url: ws.url, colorIndex: ws.colorIndex,
                    branches: ws.branches.map { br in
                        PersistedBranch(
                            id: br.id, name: br.name, worktreeURL: br.worktreeURL,
                            lastActivity: br.lastActivity,
                            sessions: br.sessions.map { s in
                                PersistedSession(id: s.id, kind: s.kind.rawValue, title: s.title,
                                                 titleIsCustom: s.titleIsCustom,
                                                 claudeSessionID: s.claudeSessionID,
                                                 browserURL: s.browserURL)
                            },
                            browserRecents: br.browserRecents.isEmpty ? nil : br.browserRecents)
                    },
                    setupScript: wsScripts[ws.id],
                    claudeFlags: wsClaudeFlags[ws.id])
            },
            // Sorted so an unchanged set always encodes to identical bytes (Set iteration
            // order is per-process nondeterministic) — the skip-if-unchanged check relies on it.
            expanded: expanded.sorted { $0.uuidString < $1.uuidString },
            globalScript: globalScript,
            globalClaudeFlags: globalClaudeFlags
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
        var flags: [UUID: String] = [:]
        for pw in state.workspaces {
            guard !confirmedMissing(pw.url) else { continue }
            let branches: [Branch] = pw.branches.compactMap { pb in
                guard !confirmedMissing(pb.worktreeURL) else { return nil }
                let sessions = pb.sessions.map { ps in
                    Session(id: ps.id, kind: SessionKind(rawValue: ps.kind) ?? .terminal,
                            title: ps.title, status: .idle, titleIsCustom: ps.titleIsCustom,
                            claudeSessionID: ps.claudeSessionID, browserURL: ps.browserURL)
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
            if let f = pw.claudeFlags { flags[pw.id] = f }
        }
        workspaces = restored
        wsScripts = scripts
        wsClaudeFlags = flags
        // Global settings: a nil (pre-settings snapshot) keeps the built-in default.
        if let gs = state.globalScript { globalScript = gs }
        if let gf = state.globalClaudeFlags { globalClaudeFlags = gf }
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

    func presentGitError(_ message: String, details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.alertStyle = .warning
        alert.runModal()
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
