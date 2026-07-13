import Foundation
import SwiftUI

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

/// Stable ids for the non-tree cursor targets, so the one `navCursor: UUID?` primitive
/// can address the Settings foot button and the settings scope list alongside tree rows
/// (working.html addresses these by DOM element; here by constant id). Workspace scope
/// rows reuse their workspace id — the tree and settings lists never render at once, so
/// there's no collision.
enum NavID {
    static let settingsFoot = UUID(uuidString: "00000000-0000-0000-0000-0000000F0071")!
    static let back         = UUID(uuidString: "00000000-0000-0000-0000-0000000BACC0")!
    static let scopeGlobal  = UUID(uuidString: "00000000-0000-0000-0000-00000060BA10")!
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

    /// The tree row under the cursor — nil in Settings, where the cursor lives on the
    /// scope list, not a tree row. Everything gated on "cursor is a real tree row"
    /// (create/rename/delete, Tab-toggle) reads through this (working.html `isTreeRow`).
    var cursorRef: RowRef? { settingsOpen ? nil : visibleRows.first { $0.id == navCursor } }

    // MARK: Movement

    /// The single list the keyboard cursor walks — screen-aware. In the main view it's
    /// the tree followed by the Settings foot button, so ↓/j off the last leaf flows
    /// straight into Settings. In Settings it's the scope list (Back, Global, workspaces).
    /// One list means every nav key works identically on both screens (working.html `activeRows`).
    var activeRows: [UUID] {
        if settingsOpen {
            return [NavID.back, NavID.scopeGlobal] + workspaces.map(\.id)
        }
        return visibleRows.map(\.id) + [NavID.settingsFoot]
    }

    /// Where the cursor rests when nothing is explicitly selected: the open session in the
    /// tree, or the active scope in Settings (working.html `currentRow`).
    func currentRow(_ rows: [UUID]) -> UUID? {
        if settingsOpen { return settingsWorkspace?.id ?? NavID.scopeGlobal }
        if let open = openSessionID, rows.contains(open) { return open }
        return nil
    }

    func moveCursor(_ delta: Int) {
        keyboardActive = true
        let rows = activeRows
        guard !rows.isEmpty else { return }
        // No explicit selection yet → step relative to the current row (open session / active scope).
        let from = (navCursor.map(rows.contains) == true) ? navCursor : currentRow(rows)
        let i = from.flatMap { rows.firstIndex(of: $0) } ?? -1
        let next = min(max(i + delta, 0), rows.count - 1)
        navCursor = rows[next]
    }

    /// ⌘0 / focus-sidebar landing: keep the cursor if it's already on a navigable row,
    /// else drop it on the current row, else the first (working.html `focusSidebar`).
    func focusSidebarCursor() {
        let rows = activeRows
        guard !rows.isEmpty else { return }
        if let c = navCursor, rows.contains(c) { return }
        navCursor = currentRow(rows) ?? rows.first
    }

    // MARK: Reorder within a sibling list (F2 drag + F7 ⇧J/⇧K)

    /// Change a row's priority by moving it `delta` positions within its own sibling list —
    /// sessions inside their branch, branches inside their workspace, workspaces at the top.
    /// A row can never leave its list (cross-list moves are impossible by construction).
    /// Stops at the list edges (no wrap), keeps the cursor on the moved row, and persists
    /// the new order. This is the ⇧J/⇧K keyboard path; drag steps `moveWithinSiblings`.
    @discardableResult
    func reorder(_ ref: RowRef, by delta: Int, animated: Bool) -> Bool {
        keyboardActive = true
        let moved = moveWithinSiblings(ref, by: delta, animated: animated)
        if moved { saveNow() }   // persist the reordered array (ADR-0010)
        return moved
    }

    /// In-place sibling move without persisting — the drag path steps this many times per
    /// gesture and saves once on drop. Keeps `navCursor` and the scroll on the moved row.
    @discardableResult
    func moveWithinSiblings(_ ref: RowRef, by delta: Int, animated: Bool) -> Bool {
        guard delta != 0 else { return false }
        func apply() -> Bool {
            switch ref {
            case let .session(s):
                guard let br = branch(of: s) else { return false }
                // Containment (ADR-0011 stage four): an owned row keeps its place under
                // its owner (no independent reorder); an owning claude hops as a block.
                if s.ownerSessionID != nil { return false }
                return AppStore.shiftSessionBlock(&br.sessions, id: s.id, by: delta)
            case let .branch(b):
                guard let ws = workspace(of: b) else { return false }
                return AppStore.shift(&ws.branches, id: b.id, by: delta)
            case let .workspace(w):
                return AppStore.shift(&workspaces, id: w.id, by: delta)
            }
        }
        let moved = animated ? withAnimation(.easeOut(duration: 0.18)) { apply() } : apply()
        if moved {
            navCursor = ref.id
            reorderScrollNonce &+= 1
        }
        return moved
    }

    /// Move the element with `id` by `delta` positions within `array`, clamped to the ends
    /// (no wrap). Returns whether it actually moved.
    private static func shift<T: Identifiable>(_ array: inout [T], id: T.ID, by delta: Int) -> Bool {
        guard let i = array.firstIndex(where: { $0.id == id }) else { return false }
        let j = i + delta
        guard j >= 0, j < array.count, j != i else { return false }
        array.insert(array.remove(at: i), at: j)
        return true
    }

    /// `shift` at containment granularity (ADR-0011 stage four): sessions group into
    /// blocks — an unowned row plus the owned browsers riding directly behind it — and
    /// the block with `id` at its head moves `delta` block positions. Owned rows never
    /// head a block (the caller no-ops them), so an owner always moves with its browsers.
    private static func shiftSessionBlock(_ array: inout [Session], id: UUID, by delta: Int) -> Bool {
        var blocks: [[Session]] = []
        var blockOf: [UUID: Int] = [:]   // owner id → its block's index
        for row in array {
            if let o = row.ownerSessionID, let i = blockOf[o] {
                blocks[i].append(row)
            } else {
                blockOf[row.id] = blocks.count
                blocks.append([row])
            }
        }
        guard let i = blocks.firstIndex(where: { $0.first?.id == id }) else { return false }
        let j = i + delta
        guard j >= 0, j < blocks.count, j != i else { return false }
        blocks.insert(blocks.remove(at: i), at: j)
        array = blocks.flatMap { $0 }
        return true
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

    /// Activate the row under the cursor — the shared ↵/Space action, dispatched by kind
    /// (working.html `activateRow`).
    func activateCursor() {
        keyboardActive = true
        if settingsOpen {
            switch navCursor {
            case NavID.back:        exitSettings()
            case NavID.scopeGlobal: selectScope(.global)
            case let id? where workspaces.contains(where: { $0.id == id }):
                selectScope(.workspace(id))
            default: break
            }
            return
        }
        if navCursor == NavID.settingsFoot { enterSettings(); return }
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

    /// The keyboard cursor sits on this row or any row inside it — the removal paths use
    /// this to decide whether the cursor needs a new home (working.html `unit.contains(selEl)`).
    func cursorInside(_ ref: RowRef) -> Bool {
        guard let c = navCursor else { return false }
        switch ref {
        case let .workspace(w):
            return c == w.id || w.branches.contains { $0.id == c || $0.sessions.contains { $0.id == c } }
        case let .branch(b):
            return c == b.id || b.sessions.contains { $0.id == c }
        case let .session(s):
            return c == s.id
        }
    }

    func removeWorkspace(_ workspace: Workspace) {
        // A removed workspace has nothing above it — the cursor falls to a neighbouring
        // workspace instead (working.html removeUnit fallback).
        if cursorInside(.workspace(workspace)), let i = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            navCursor = i > 0 ? workspaces[i - 1].id
                : workspaces.count > 1 ? workspaces[i + 1].id : nil
        }
        for session in workspace.branches.flatMap(\.sessions) {
            TerminalManager.shared.terminate(session.id)
            BrowserManager.shared.terminate(session.id)
            if openSessionID == session.id { openSessionID = nil }
        }
        workspaces.removeAll { $0.id == workspace.id }
        expanded.remove(workspace.id)
    }

    /// Remove a worktree row. The row vanishes instantly either way; `deleteWorktree`
    /// then deletes the checkout on disk in the background (rename-aside + prune, so
    /// even a multi-GB tree never stalls the app — features 2026-07-06). Otherwise the
    /// folder is left in place and only the sidebar entry drops (re-addable later).
    /// The primary checkout (repo root) is never deleted from disk — git won't remove
    /// its own working tree.
    func removeBranch(_ branch: Branch, deleteWorktree: Bool) {
        // Cursor falls up the hierarchy to the workspace head (working.html removeUnit fallback).
        if cursorInside(.branch(branch)) { navCursor = workspace(of: branch)?.id }
        // A failed/cancelled create whose setup skeleton was on screen falls back to empty.
        if openSetupBranchID == branch.id { openSetupBranchID = nil }
        for session in branch.sessions {
            TerminalManager.shared.terminate(session.id)
            BrowserManager.shared.terminate(session.id)
            if openSessionID == session.id { openSessionID = nil }
        }
        let ws = workspaces.first { $0.branches.contains { $0.id == branch.id } }
        for ws in workspaces { ws.branches.removeAll { $0.id == branch.id } }
        expanded.remove(branch.id)
        if deleteWorktree, let ws, branch.worktreeURL != ws.url {
            // Serialized per repo, so deleting a still-pending row queues behind its create.
            deleteWorktreeFolder(repo: ws.url, path: branch.worktreeURL,
                                 branchName: branch.name, workspaceName: ws.name)
        }
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

    /// Drop an agent session's manual name so its auto/AI-generated title takes over
    /// again — the palette's "Reset to default name" (working.html renameFrame).
    func resetSessionName(_ session: Session) {
        session.title = session.kind.tplStart
        session.titleIsCustom = false
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
                              creates: [MenuCreate(icon: Phosphor.terminal, title: "New terminal",
                                                   run: { [weak self] in self?.newTerminal(in: b) })]
                                + AgentRegistry.installed.map { agent in
                                    MenuCreate(icon: Phosphor.sparkle, kind: .agent(agent.id),
                                               title: "New \(agent.displayName)",
                                               run: { [weak self] in self?.newAgent(agent.id, in: b) })
                                }
                                + [MenuCreate(icon: Phosphor.globe, title: "New browser",
                                              run: { [weak self] in self?.newBrowser(in: b) })],
                              onDelete: { [weak self] in self?.removeBranch(b, deleteWorktree: false) })
        case let .session(s):
            return ActiveMenu(rowID: s.id, level: .session, creates: [],
                              onDelete: { [weak self] in self?.closeSession(s) },
                              confirmText: deleteSessionHint(s),
                              isDestructive: s.status.isBusy)
        }
    }

    /// `d` on the selected row — always drops into the ⌘K palette's confirm frame so a
    /// single keystroke can't delete (working.html requestDelete → openPaletteAt(confirmFrame)).
    func requestDelete(_ ref: RowRef) {
        activeMenu = nil
        if palette == nil { palette = PaletteModel(store: self) }
        guard let pal = palette else { return }
        let frame: PaletteFrame
        switch ref {
        case let .workspace(w): frame = pal.confirmRemoveWorkspace(w)
        case let .branch(b):    frame = pal.confirmRemoveBranch(b)
        case let .session(s):   frame = pal.confirmDeleteSession(s)
        }
        pal.stack = [pal.rootFrame()]
        pal.push(frame)
    }

    /// ⌘D — close the current context through the same flow as `d` on a sidebar row:
    /// the focused sidebar row when the keyboard owns the sidebar, else the open session
    /// (working.html contextRow → requestDelete). Inert in Settings, where an idle open
    /// session would otherwise close invisibly behind the settings surface.
    func closeContext() {
        guard !settingsOpen else { return }
        if keyboardActive, let ref = cursorRef { requestDelete(ref); return }
        if let s = openSession { requestDelete(.session(s)) }
    }
}
