import Foundation

/// A row currently visible in the tree — the unit keyboard navigation moves over.
enum RowRef: Identifiable, Equatable {
    case workspace(Workspace)
    case branch(Branch)
    case session(Session)

    var id: UUID {
        switch self {
        case let .workspace(w): return w.id
        case let .branch(b): return b.id
        case let .session(s): return s.id
        }
    }

    static func == (lhs: RowRef, rhs: RowRef) -> Bool { lhs.id == rhs.id }
}

extension AppStore {
    /// The flattened, ordered list of rows the user can see, respecting expansion.
    /// Keyboard movement only ever visits these (FEATURES: "visible rows only").
    var visibleRows: [RowRef] {
        var rows: [RowRef] = []
        for ws in workspaces {
            rows.append(.workspace(ws))
            guard expanded.contains(ws.id) else { continue }
            for br in ws.branches {
                rows.append(.branch(br))
                guard br.isLive, expanded.contains(br.id) else { continue }
                for s in br.sessions { rows.append(.session(s)) }
            }
        }
        return rows
    }

    var cursorRef: RowRef? { visibleRows.first { $0.id == navCursor } }

    // MARK: Movement

    func moveCursor(_ delta: Int) {
        keyboardActive = true
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == navCursor } ?? -1
        let next = min(max(current + delta, 0), rows.count - 1)
        navCursor = rows[next].id
    }

    /// A row that can expand/collapse: a workspace, or a live branch group.
    private func isToggle(_ ref: RowRef) -> Bool {
        switch ref {
        case .workspace:      return true
        case let .branch(b):  return b.isLive
        case .session:        return false
        }
    }

    /// → : open a closed toggle, else move down (mirrors working.html).
    func expandOrIn() {
        keyboardActive = true
        if let ref = cursorRef, isToggle(ref), !expanded.contains(ref.id) {
            expanded.insert(ref.id)
        } else {
            moveCursor(1)
        }
    }

    /// ← : close an open toggle, else move up (mirrors working.html).
    func collapseOrOut() {
        keyboardActive = true
        if let ref = cursorRef, isToggle(ref), expanded.contains(ref.id) {
            expanded.remove(ref.id)
        } else {
            moveCursor(-1)
        }
    }

    func activateCursor() {
        keyboardActive = true
        switch cursorRef {
        case let .workspace(w): toggleExpanded(w.id)
        case let .branch(b): if b.isLive { toggleExpanded(b.id) }
        case let .session(s): open(s)
        case .none: break
        }
    }

    // MARK: Structural edits

    @discardableResult
    func newBranch(in workspace: Workspace, name: String) -> Branch {
        let branch = Branch(name: name, lastActivity: "now")
        workspace.branches.append(branch)
        expanded.insert(workspace.id)
        navCursor = branch.id
        return branch
    }

    func deleteWorkspace(_ workspace: Workspace) {
        for session in workspace.branches.flatMap(\.sessions) {
            TerminalManager.shared.terminate(session.id)
            if openSessionID == session.id { openSessionID = nil }
        }
        workspaces.removeAll { $0.id == workspace.id }
        expanded.remove(workspace.id)
    }

    func deleteBranch(_ branch: Branch) {
        for session in branch.sessions {
            TerminalManager.shared.terminate(session.id)
            if openSessionID == session.id { openSessionID = nil }
        }
        for ws in workspaces { ws.branches.removeAll { $0.id == branch.id } }
        expanded.remove(branch.id)
    }
}
