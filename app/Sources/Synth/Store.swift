import AppKit
import Foundation
import Observation

/// A low-frequency derived fact posted by a session's supervisor onto the bus.
/// The firehose (PTY bytes, cursor moves) never appears here — see docs/adr/0001.
enum SessionEvent: Sendable {
    case statusChanged(UUID, SessionStatus)
    case titleChanged(UUID, String)
    case exited(UUID, Int32?)
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

/// The durable, observed source of truth. Holds only the low-frequency facts the
/// UI reads: the tree, per-session status, expansion, and the two selection fields
/// (nav cursor + open session) from docs/adr/0005.
@MainActor @Observable final class AppStore {
    var workspaces: [Workspace] = []
    var expanded: Set<UUID> = []
    var navCursor: UUID?
    var openSessionID: UUID?
    var sidebarCollapsed = false

    /// True only while the keyboard is driving nav — gates the selection ring
    /// (mousemove clears it), mirroring working.html's `.kbd` class.
    var keyboardActive = false

    /// Sheet driver.
    var creatingBranchIn: Workspace?

    /// The row-action menu currently open (nil = none).
    var activeMenu: ActiveMenu?

    /// The ⌘K palette (nil = closed).
    var palette: PaletteModel?

    let bus = EventBus()

    init() {
        TerminalManager.shared.bus = bus
        Task { [weak self] in
            guard let self else { return }
            for await event in self.bus.stream { self.apply(event) }
        }
    }

    // MARK: Bus → store

    private func apply(_ event: SessionEvent) {
        switch event {
        case let .statusChanged(id, status): session(id)?.status = status
        case let .titleChanged(id, title):   session(id)?.title = title
        case let .exited(id, code):
            session(id)?.status = (code ?? 0) == 0 ? .exited(code) : .error
        }
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

    /// Working directory for a session. Worktrees are deferred (ADR-0004); for now a
    /// session runs at its workspace root.
    func cwd(for session: Session) -> URL? {
        guard let br = branch(of: session) else { return nil }
        return workspace(of: br)?.url
    }

    // MARK: Commands

    func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func open(_ session: Session) {
        openSessionID = session.id
        navCursor = session.id
        session.unread = false
    }

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

    private func defaultBranch() -> Branch? {
        if let open = openSession, let br = branch(of: open) { return br }
        return workspaces.first?.branches.first
    }

    @discardableResult
    func newTerminal(in branch: Branch? = nil) -> Session? {
        guard let br = branch ?? defaultBranch() else { return nil }
        let session = Session(kind: .terminal, title: "shell", status: .running)
        br.sessions.append(session)
        br.lastActivity = "now"
        if let ws = workspace(of: br) { expanded.insert(ws.id) }
        expanded.insert(br.id)
        open(session)
        return session
    }

    func closeSession(_ session: Session) {
        TerminalManager.shared.terminate(session.id)
        for br in workspaces.flatMap(\.branches) {
            br.sessions.removeAll { $0.id == session.id }
        }
        if openSessionID == session.id { openSessionID = nil }
    }

    /// Folder picker → workspace. Panel runs modally, so state mutation happens after dismiss.
    func promptAddWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a repository folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addWorkspace(url: url)
    }

    func addWorkspace(url: URL) {
        let name = url.lastPathComponent
        // Real branches, discovered from git. Empty if not a repo.
        let branches = GitService.branches(at: url).map {
            Branch(name: $0.name, lastActivity: GitService.compactAge($0.lastCommitUnix))
        }
        let ws = Workspace(
            name: name,
            url: url,
            branches: branches,
            colorIndex: workspaces.count % Theme.chipColors.count
        )
        workspaces.append(ws)   // collapsed by default
    }
}
