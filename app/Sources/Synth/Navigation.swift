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
                guard expanded.contains(br.id) else { continue }
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

    /// A row that can expand/collapse: a workspace, or any branch group.
    private func isToggle(_ ref: RowRef) -> Bool {
        switch ref {
        case .workspace:      return true
        case .branch:         return true
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
        case let .branch(b): toggleExpanded(b.id)
        case let .session(s): open(s); focusContent(self)
        case .none: break
        }
    }

    /// The cursor sits on a group (workspace or branch group) that Tab can toggle.
    var cursorIsGroup: Bool {
        guard let ref = cursorRef else { return false }
        return isToggle(ref)
    }

    /// Tab: toggle the highlighted group open↔closed (groups only; the cursor stays put).
    /// `l`/`h` remain the directional expand/collapse — Tab is the toggle (working.html).
    func toggleGroup() {
        guard let ref = cursorRef, isToggle(ref) else { return }
        keyboardActive = true
        toggleExpanded(ref.id)
    }

    // MARK: Structural edits — remove from the sidebar only; worktrees and
    // branches stay on disk untouched.

    func removeWorkspace(_ workspace: Workspace) {
        for session in workspace.branches.flatMap(\.sessions) {
            TerminalManager.shared.terminate(session.id)
            if openSessionID == session.id { openSessionID = nil }
        }
        workspaces.removeAll { $0.id == workspace.id }
        expanded.remove(workspace.id)
    }

    func removeBranch(_ branch: Branch) {
        for session in branch.sessions {
            TerminalManager.shared.terminate(session.id)
            if openSessionID == session.id { openSessionID = nil }
        }
        for ws in workspaces { ws.branches.removeAll { $0.id == branch.id } }
        expanded.remove(branch.id)
    }

    // MARK: Rename

    /// Any row by id — resolves the inline-rename target on commit (it stays in the tree
    /// even if it is no longer the cursor row).
    func rowRef(_ id: UUID) -> RowRef? {
        for ws in workspaces {
            if ws.id == id { return .workspace(ws) }
            for br in ws.branches {
                if br.id == id { return .branch(br) }
                if let s = br.sessions.first(where: { $0.id == id }) { return .session(s) }
            }
        }
        return nil
    }

    func currentName(of ref: RowRef) -> String {
        switch ref {
        case let .workspace(w): return w.name
        case let .branch(b):    return b.name
        case let .session(s):   return s.title
        }
    }

    /// Write a new name onto the unit. Renaming the open session updates the pane title
    /// for free — ContentPane reads `session.title` (no manual sync, unlike working.html).
    func rename(_ ref: RowRef, to name: String) {
        let v = name.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        switch ref {
        case let .workspace(w): w.name = v
        case let .branch(b):    b.name = v
        case let .session(s):   s.title = v; s.titleIsCustom = true
        }
    }

    // MARK: Inline rename (r on the selected row)

    func beginRename(_ ref: RowRef) {
        activeMenu = nil
        renameText = currentName(of: ref)
        renamingRowID = ref.id
        keyboardActive = true
    }

    /// ↵ / blur — commit the field (whitespace collapsed); an empty name reverts.
    func commitRename() {
        guard let id = renamingRowID else { return }
        renamingRowID = nil
        guard let ref = rowRef(id) else { return }
        let v = renameText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !v.isEmpty { rename(ref, to: v) }
    }

    /// Esc — leave the name untouched.
    func cancelRename() { renamingRowID = nil }

    // MARK: Row menu (shared by the kebab and the `d` shortcut)

    /// The action menu for a row — the same card the kebab opens, centralised so the
    /// `d` shortcut can raise it straight into its confirm step.
    func rowMenu(for ref: RowRef) -> ActiveMenu {
        switch ref {
        case let .workspace(w):
            return ActiveMenu(rowID: w.id, level: .workspace,
                              creates: [MenuCreate(icon: Phosphor.branch, title: "Create worktree…",
                                                   run: { [weak self] in self?.creatingWorktreeIn = w })],
                              onDelete: { [weak self] in self?.removeWorkspace(w) })
        case let .branch(b):
            return ActiveMenu(rowID: b.id, level: .branch,
                              creates: [
                                MenuCreate(icon: Phosphor.terminal, title: "New terminal",
                                           run: { [weak self] in self?.newTerminal(in: b) }),
                                MenuCreate(icon: Phosphor.sparkle, title: "New Claude Code",
                                           run: { [weak self] in self?.newClaude(in: b) }),
                              ],
                              onDelete: { [weak self] in self?.removeBranch(b) })
        case let .session(s):
            return ActiveMenu(rowID: s.id, level: .session, creates: [],
                              onDelete: { [weak self] in self?.closeSession(s) })
        }
    }

    /// `d` on the selected row — open its menu straight in the confirm step so a single
    /// keystroke can't delete (working.html requestDelete → showConfirm).
    func requestDelete(_ ref: RowRef) {
        activeMenu = rowMenu(for: ref)
        menuConfirming = true
    }
}
