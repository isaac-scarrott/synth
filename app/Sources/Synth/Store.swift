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

/// Which settings scope the full-screen settings page is showing. A workspace is
/// referenced by id so a removed workspace leaves a dangling scope that falls back
/// to Global rather than crashing (working.html's dangling-scope guard).
enum SettingsScope: Equatable {
    case global
    case workspace(UUID)
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

    /// Sheet drivers.
    var creatingWorktreeIn: Workspace?
    var pendingWorkspace: PendingWorkspace?

    /// The row-action menu currently open (nil = none).
    var activeMenu: ActiveMenu?

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
    }

    func exitSettings() { settingsOpen = false }

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

    private func defaultBranch() -> Branch? {
        if let open = openSession, let br = branch(of: open) { return br }
        return workspaces.first?.branches.first
    }

    @discardableResult
    func newTerminal(in branch: Branch? = nil) -> Session? {
        addSession(kind: .terminal, title: "shell", status: .running, in: branch)
    }

    /// Claude Code is just a terminal that opened and ran `claude`, so it spawns
    /// identically — only the kind, title and starting state differ (working.html
    /// SESSION_KINDS/addSession). It opens straight into the content pane.
    @discardableResult
    func newClaude(in branch: Branch? = nil) -> Session? {
        addSession(kind: .claudeCode, title: "Claude Code", status: .working, in: branch)
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

    func presentGitError(_ message: String, details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.alertStyle = .warning
        alert.runModal()
    }
}
