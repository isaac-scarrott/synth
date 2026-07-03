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

    let bus = EventBus()

    init() {
        seed()
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
        case let .exited(id, code):          session(id)?.status = .exited(code)
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

    private func defaultBranch() -> Branch? {
        if let open = openSession, let br = branch(of: open) { return br }
        return workspaces.first?.branches.first
    }

    @discardableResult
    func newTerminal(in branch: Branch? = nil) -> Session? {
        guard let br = branch ?? defaultBranch() else { return nil }
        let count = br.sessions.filter { $0.kind == .terminal }.count
        let title = count == 0 ? "shell" : "shell \(count + 1)"
        let session = Session(kind: .terminal, title: title, status: .running)
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

    func addWorkspace(url: URL) {
        let ws = Workspace(
            name: url.lastPathComponent,
            url: url,
            branches: [Branch(name: "main", lastActivity: "now")],
            colorIndex: workspaces.count % Theme.chipColors.count
        )
        workspaces.append(ws)
        expanded.insert(ws.id)
    }

    // MARK: Seed

    private func seed() {
        let synth = URL(fileURLWithPath: "/Users/isaac/git/synth")
        let ws = Workspace(
            name: "synth",
            url: synth,
            branches: [
                Branch(name: "main", lastActivity: "2h"),
                Branch(name: "feat/command-palette", lastActivity: "12m"),
                Branch(name: "fix/sidebar-shadow", lastActivity: "5h"),
            ],
            colorIndex: 0
        )
        workspaces = [ws]
        expanded = [ws.id]
    }
}
