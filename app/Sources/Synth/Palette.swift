import SwiftUI

// The ⌘K command palette — a navigation stack of frames (working.html's cmdk).
// Simple at rest, progressive search on typing; drill pushes a frame, Backspace on
// an empty query pops. Create / delete / confirm happen inline as text — never a modal.

// MARK: - Fuzzy matcher

/// Subsequence match with word-boundary + contiguity bonuses; nil = no match.
/// Ports working.html's `fuzzy()` exactly.
func fuzzyScore(_ query: String, _ text: String) -> Double? {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased())
    let t = Array(text.lowercased())
    var ti = 0, first = -1
    var run = 0.0, score = 0.0
    for c in q {
        var idx = -1
        var i = ti
        while i < t.count { if t[i] == c { idx = i; break }; i += 1 }
        if idx == -1 { return nil }
        if first == -1 { first = idx }
        run = idx == ti ? run + 2 : 0
        if idx == 0 || !(t[idx - 1].isLetter || t[idx - 1].isNumber) { score += 3 }
        score += 1 + run
        ti = idx + 1
    }
    return score - Double(first) * 0.5
}

// MARK: - Model

enum PaletteIcon {
    case phosphor(String)                 // path, default grey tint
    case session(SessionKind)             // kind icon + its tint
    case chip(String, Color)              // workspace monogram
}

struct PaletteItem {
    var icon: PaletteIcon
    var label: String
    var sec: String? = nil                // nav / act / list → divider grouping in a frame
    var group: String? = nil              // Actions / Workspaces / … → text headers in search
    var ctx: String? = nil                // location, shown only where not already established
    var meta: String? = nil               // status label
    var metaColor: Color? = nil
    var kbd: [String]? = nil
    var danger = false
    var disabled = false
    var enter: () -> Void
}

struct PaletteFrame {
    enum Mode { case list, input, confirm }
    var crumb: String? = nil
    var placeholder: String
    var mode: Mode = .list
    var build: (String) -> [PaletteItem]
}

@MainActor @Observable final class PaletteModel {
    unowned let store: AppStore
    var stack: [PaletteFrame] = []
    var query = "" { didSet { activeIndex = 0 } }
    var activeIndex = 0

    init(store: AppStore) {
        self.store = store
        stack = [rootFrame()]
    }

    var frame: PaletteFrame { stack[stack.count - 1] }

    /// The frame's items, fuzzy-filtered for `list` frames — section order preserved,
    /// fuzzy-ranked within each section (working.html's renderFrame).
    var items: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let built = frame.build(q)
        guard frame.mode == .list, !q.isEmpty else { return built }
        var order: [String] = []
        var byKey: [String: [(PaletteItem, Double)]] = [:]
        for it in built {
            guard let s = fuzzyScore(q, it.label) else { continue }
            let k = it.group ?? it.sec ?? ""
            if byKey[k] == nil { byKey[k] = []; order.append(k) }
            byKey[k]!.append((it, s))
        }
        return order.flatMap { byKey[$0]!.sorted { $0.1 > $1.1 }.map(\.0) }
    }

    func push(_ frame: PaletteFrame) { stack.append(frame); query = "" }
    func pop() { if stack.count > 1 { stack.removeLast(); query = "" } }
    func pop(to depth: Int) { stack.removeLast(stack.count - max(1, depth + 1)); query = "" }

    func move(_ delta: Int) {
        let n = items.count
        guard n > 0 else { return }
        activeIndex = (activeIndex + delta + n) % n
    }

    func runActive() {
        let its = items
        guard activeIndex < its.count else { return }
        let it = its[activeIndex]
        guard !it.disabled else { return }
        it.enter()
    }

    private func runAndClose(_ fn: @escaping () -> Void) { store.closePalette(); fn() }

    // MARK: Store-derived helpers

    /// Which workspace a context-sensitive action targets: the nav cursor's, else the first.
    private var contextWorkspace: Workspace? {
        if let id = store.navCursor {
            for ws in store.workspaces {
                if ws.id == id { return ws }
                for br in ws.branches {
                    if br.id == id || br.sessions.contains(where: { $0.id == id }) { return ws }
                }
            }
        }
        if let open = store.openSession, let br = store.branch(of: open) {
            return store.workspace(of: br)
        }
        return store.workspaces.first
    }

    private func wsOf(_ branch: Branch) -> String { store.workspace(of: branch)?.name ?? "" }
    private func ctxOf(_ session: Session) -> String {
        guard let br = store.branch(of: session) else { return "" }
        return [wsOf(br), br.name].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    private func chipIcon(_ ws: Workspace) -> PaletteIcon {
        .chip(ws.monogram, Theme.chipColors[ws.colorIndex % Theme.chipColors.count])
    }

    private func sessionItem(_ s: Session, ctx: Bool, sec: String? = nil, group: String? = nil) -> PaletteItem {
        PaletteItem(icon: .session(s.kind), label: s.title, sec: sec, group: group,
                    ctx: ctx ? ctxOf(s) : nil,
                    meta: s.status.paletteLabel, metaColor: s.status.paletteColor,
                    enter: { [self] in runAndClose { [store] in store.jump(to: s) } })
    }

    // MARK: Frames

    func rootFrame() -> PaletteFrame {
        PaletteFrame(placeholder: "Search or jump to anything…") { [self] q in
            if q.isEmpty {
                return [
                    PaletteItem(icon: .phosphor(Phosphor.folder), label: "Workspaces", sec: "nav",
                                enter: { self.push(self.workspacesFrame()) }),
                    PaletteItem(icon: .phosphor(Phosphor.branch), label: "Branches", sec: "nav",
                                enter: { self.push(self.branchesFrame()) }),
                    PaletteItem(icon: .phosphor(Phosphor.squares), label: "Sessions", sec: "nav",
                                enter: { self.push(self.sessionsFrame()) }),
                    PaletteItem(icon: .phosphor(Phosphor.sidebar), label: "Toggle sidebar", sec: "act",
                                kbd: ["⌘", "B"],
                                enter: { self.runAndClose { self.store.sidebarCollapsed.toggle() } }),
                ]
            }
            var items = [
                PaletteItem(icon: .phosphor(Phosphor.plus), label: "New workspace…", group: "Actions",
                            enter: { self.push(self.createWorkspaceFrame()) }),
                PaletteItem(icon: .phosphor(Phosphor.branch), label: "New branch…", group: "Actions",
                            enter: { self.push(self.createBranchFrame(in: self.contextWorkspace)) }),
                PaletteItem(icon: .phosphor(Phosphor.sidebar), label: "Toggle sidebar", group: "Actions",
                            kbd: ["⌘", "B"],
                            enter: { self.runAndClose { self.store.sidebarCollapsed.toggle() } }),
            ]
            for ws in store.workspaces {
                items.append(PaletteItem(icon: chipIcon(ws), label: ws.name, group: "Workspaces",
                                         enter: { self.push(self.workspaceFrame(ws)) }))
            }
            for ws in store.workspaces {
                for br in ws.branches {
                    items.append(PaletteItem(icon: .phosphor(Phosphor.branch), label: br.name,
                                             group: "Branches", ctx: ws.name,
                                             enter: { self.push(self.branchFrame(br)) }))
                }
            }
            for ws in store.workspaces {
                for br in ws.branches {
                    for s in br.sessions { items.append(sessionItem(s, ctx: true, group: "Sessions")) }
                }
            }
            return items
        }
    }

    func workspacesFrame() -> PaletteFrame {
        PaletteFrame(crumb: "Workspaces", placeholder: "Search workspaces…") { [self] _ in
            var items = [
                PaletteItem(icon: .phosphor(Phosphor.plus), label: "New workspace…", sec: "act",
                            enter: { self.push(self.createWorkspaceFrame()) }),
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Delete workspace…", sec: "act",
                            danger: true, enter: { self.push(self.deleteWorkspacePicker()) }),
            ]
            for ws in store.workspaces {
                items.append(PaletteItem(icon: chipIcon(ws), label: ws.name, sec: "list",
                                         enter: { self.push(self.workspaceFrame(ws)) }))
            }
            return items
        }
    }

    func branchesFrame() -> PaletteFrame {
        PaletteFrame(crumb: "Branches", placeholder: "Search branches…") { [self] _ in
            var items = [
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Delete branch…", sec: "act",
                            danger: true, enter: { self.push(self.deleteBranchPicker()) }),
            ]
            for ws in store.workspaces {
                for br in ws.branches {
                    items.append(PaletteItem(icon: .phosphor(Phosphor.branch), label: br.name,
                                             sec: "list", ctx: ws.name,
                                             enter: { self.push(self.branchFrame(br)) }))
                }
            }
            return items
        }
    }

    func sessionsFrame() -> PaletteFrame {
        PaletteFrame(crumb: "Sessions", placeholder: "Search sessions…") { [self] _ in
            var items = [
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Delete session…", sec: "act",
                            danger: true, enter: { self.push(self.deleteSessionPicker()) }),
            ]
            for ws in store.workspaces {
                for br in ws.branches {
                    for s in br.sessions { items.append(sessionItem(s, ctx: true, sec: "list")) }
                }
            }
            return items
        }
    }

    func workspaceFrame(_ ws: Workspace) -> PaletteFrame {
        PaletteFrame(crumb: ws.name, placeholder: "Search \(ws.name)…") { [self] _ in
            var items = [
                PaletteItem(icon: .phosphor(Phosphor.branch), label: "New branch…", sec: "act",
                            enter: { self.push(self.createBranchFrame(in: ws)) }),
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Delete \(ws.name)", sec: "act",
                            danger: true, enter: { self.push(self.confirmDeleteWorkspace(ws)) }),
            ]
            for br in ws.branches {
                items.append(PaletteItem(icon: .phosphor(Phosphor.branch), label: br.name, sec: "list",
                                         enter: { self.push(self.branchFrame(br)) }))
            }
            return items
        }
    }

    func branchFrame(_ branch: Branch) -> PaletteFrame {
        PaletteFrame(crumb: branch.name, placeholder: "Search \(branch.name)…") { [self] _ in
            var items = [
                PaletteItem(icon: .phosphor(Phosphor.terminal), label: "New terminal", sec: "act",
                            enter: { self.runAndClose { self.store.newTerminal(in: branch) } }),
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Delete \(branch.name)", sec: "act",
                            danger: true, enter: { self.push(self.confirmDeleteBranch(branch)) }),
            ]
            for s in branch.sessions { items.append(sessionItem(s, ctx: false, sec: "list")) }
            return items
        }
    }

    // MARK: Delete pickers → inline confirm

    func deleteWorkspacePicker() -> PaletteFrame {
        PaletteFrame(crumb: "Delete workspace", placeholder: "Select a workspace to delete…") { [self] _ in
            store.workspaces.map { ws in
                PaletteItem(icon: chipIcon(ws), label: ws.name, danger: true,
                            enter: { self.push(self.confirmDeleteWorkspace(ws)) })
            }
        }
    }

    func deleteBranchPicker() -> PaletteFrame {
        PaletteFrame(crumb: "Delete branch", placeholder: "Select a branch to delete…") { [self] _ in
            store.workspaces.flatMap { ws in
                ws.branches.map { br in
                    PaletteItem(icon: .phosphor(Phosphor.branch), label: br.name, ctx: ws.name,
                                danger: true, enter: { self.push(self.confirmDeleteBranch(br)) })
                }
            }
        }
    }

    func deleteSessionPicker() -> PaletteFrame {
        PaletteFrame(crumb: "Delete session", placeholder: "Select a session to delete…") { [self] _ in
            store.workspaces.flatMap(\.branches).flatMap(\.sessions).map { s in
                PaletteItem(icon: .session(s.kind), label: s.title, ctx: ctxOf(s),
                            meta: s.status.paletteLabel, metaColor: s.status.paletteColor,
                            danger: true, enter: { self.push(self.confirmDeleteSession(s)) })
            }
        }
    }

    private func confirmFrame(name: String, noun: String, perform: @escaping () -> Void) -> PaletteFrame {
        PaletteFrame(crumb: "Delete \(name)?", placeholder: "Delete this \(noun)?  ↵ confirm · esc cancel",
                     mode: .confirm) { [self] _ in
            [
                PaletteItem(icon: .phosphor(Phosphor.trash), label: "Delete \(name)", danger: true,
                            enter: { self.runAndClose(perform) }),
                PaletteItem(icon: .phosphor(Phosphor.close), label: "Cancel", enter: { self.pop() }),
            ]
        }
    }

    func confirmDeleteWorkspace(_ ws: Workspace) -> PaletteFrame {
        confirmFrame(name: ws.name, noun: "workspace") { [store] in store.deleteWorkspace(ws) }
    }
    func confirmDeleteBranch(_ br: Branch) -> PaletteFrame {
        confirmFrame(name: br.name, noun: "branch") { [store] in store.deleteBranch(br) }
    }
    func confirmDeleteSession(_ s: Session) -> PaletteFrame {
        confirmFrame(name: s.title, noun: "session") { [store] in store.closeSession(s) }
    }

    // MARK: Create frames — the search input becomes the name field

    func createWorkspaceFrame() -> PaletteFrame {
        PaletteFrame(crumb: "New workspace", placeholder: "Repository path or name…", mode: .input) { [self] q in
            let v = q.trimmingCharacters(in: .whitespaces)
            return [PaletteItem(icon: .phosphor(Phosphor.plus),
                                label: v.isEmpty ? "Type a workspace name…" : "Create workspace “\(v)”",
                                disabled: v.isEmpty,
                                enter: { self.runAndClose {
                                    let path = (v as NSString).expandingTildeInPath
                                    self.store.addWorkspace(url: URL(fileURLWithPath: path))
                                } })]
        }
    }

    func createBranchFrame(in workspace: Workspace?) -> PaletteFrame {
        PaletteFrame(crumb: "New branch", placeholder: "Branch name…", mode: .input) { [self] q in
            let v = q.trimmingCharacters(in: .whitespaces)
            return [PaletteItem(icon: .phosphor(Phosphor.plus),
                                label: v.isEmpty ? "Type a branch name…" : "Create branch “\(v)”",
                                disabled: v.isEmpty,
                                enter: { self.runAndClose {
                                    if let ws = workspace { self.store.newBranch(in: ws, name: v) }
                                } })]
        }
    }
}

extension SessionStatus {
    // working.html's STATE_LABEL + .cmdk__meta--* colours.
    var paletteLabel: String {
        switch self {
        case .running:       return "running"
        case .working:       return "working"
        case .needsInput:    return "needs input"
        case .error:         return "error"
        case .idle, .exited: return "idle"
        }
    }
    var paletteColor: Color {
        switch self {
        case .running:       return Color(hex: 0x2EA043)
        case .working:       return Color(hex: 0xC8811A)
        case .needsInput:    return Color(hex: 0x0A6FD6)
        case .error:         return Color(hex: 0xD13C2F)
        case .idle, .exited: return Color(hex: 0xA1A1A6)
        }
    }
}

// MARK: - View

/// One rendered row of the palette list: text headers between search groups,
/// thin dividers between a frame's sections, and the items themselves.
private enum PaletteRow: Identifiable {
    case header(String)
    case divider(Int)
    case item(Int, PaletteItem)

    var id: String {
        switch self {
        case let .header(g): return "h-\(g)"
        case let .divider(i): return "d-\(i)"
        case let .item(i, _): return "i-\(i)"
        }
    }
}

struct PaletteOverlay: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: PaletteModel

    @State private var shown = false
    @FocusState private var focused: Bool

    private var rows: [PaletteRow] {
        var rows: [PaletteRow] = []
        var lastGroup: String?
        var lastSec: String?
        for (i, it) in model.items.enumerated() {
            if let g = it.group, g != lastGroup {
                rows.append(.header(g)); lastGroup = g; lastSec = it.sec
            } else if let s = it.sec, s != lastSec {
                if i > 0 { rows.append(.divider(i)) }
                lastSec = s
            }
            rows.append(.item(i, it))
        }
        return rows
    }

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.16)
                    .contentShape(Rectangle())
                    .onTapGesture { store.closePalette() }

                panel
                    .frame(width: 560)
                    .scaleEffect(shown ? 1 : 0.98)
                    .offset(y: shown ? 0 : -8)
                    .opacity(shown ? 1 : 0)
                    .padding(.top, geo.size.height * 0.14)
            }
            .ignoresSafeArea()
        }
        .opacity(shown ? 1 : 0)
        .onAppear {
            focused = true
            if reduceMotion { shown = true }
            else { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
        }
    }

    private var panel: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Phos(path: Phosphor.search, size: 17).foregroundStyle(Theme.navLabel)
                let crumbs = model.stack.enumerated().filter { $0.element.crumb != nil }
                if !crumbs.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(crumbs, id: \.offset) { depth, frame in
                            CrumbChip(text: frame.crumb ?? "") { model.pop(to: depth) }
                        }
                    }
                }
                TextField(model.frame.placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.repoName)
                    .focused($focused)
                    .onChange(of: model.stack.count) { focused = true }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
            }

            list
        }
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.white.opacity(0.86)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.28), radius: 60, y: 24)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.items.isEmpty {
                        Text("No results")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.navLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(rows) { row in
                            switch row {
                            case let .header(g):
                                Text(g.uppercased())
                                    .font(.system(size: 10, weight: .semibold)).kerning(0.5)
                                    .foregroundStyle(Theme.navLabel)
                                    .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                            case .divider:
                                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                            case let .item(i, it):
                                PaletteItemRow(item: it, active: i == model.activeIndex) {
                                    model.activeIndex = i
                                    model.runActive()
                                } onHover: {
                                    if model.activeIndex != i { model.activeIndex = i }
                                }
                                .id(i)
                            }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.items.count)
            .onChange(of: model.activeIndex) { _, i in
                proxy.scrollTo(i, anchor: nil)
            }
        }
    }
}

private struct CrumbChip: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color(hex: 0x46464C))
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(hovering ? 0.09 : 0.05))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PaletteItemRow: View {
    let item: PaletteItem
    let active: Bool
    let action: () -> Void
    let onHover: () -> Void

    private var labelColor: Color {
        if item.danger { return Theme.danger }
        return active ? Color(hex: 0x0A5FD6) : Theme.repoName
    }

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 20)
            Text(item.label)
                .font(.system(size: 13.5))
                .foregroundStyle(labelColor)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if let ctx = item.ctx, !ctx.isEmpty {
                Text(ctx)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hex: 0xB6B6BB))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 210, alignment: .trailing)
            }
            if let meta = item.meta {
                Text(meta)
                    .font(.system(size: 11)).kerning(0.1)
                    .foregroundStyle(item.metaColor ?? Theme.inkMuted)
            }
            if let kbd = item.kbd {
                HStack(spacing: 3) {
                    ForEach(kbd, id: \.self) { key in
                        Text(key)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                            .frame(minWidth: 17)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.black.opacity(0.05))
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                            )
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(active ? (item.danger ? Theme.danger.opacity(0.1) : Color(hex: 0x0A84FF).opacity(0.1)) : .clear)
        )
        .opacity(item.disabled ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !item.disabled { action() } }
        .onContinuousHover { phase in
            if case .active = phase { onHover() }
        }
    }

    @ViewBuilder private var iconView: some View {
        switch item.icon {
        case let .phosphor(path):
            Phos(path: path, size: 16)
                .foregroundStyle(item.danger ? Theme.danger : Color(hex: 0x6A6A70))
        case let .session(kind):
            Phos(path: kind.iconPath, size: 16)
                .foregroundStyle(item.danger ? Theme.danger : kind.tint)
        case let .chip(text, color):
            RoundedRectangle(cornerRadius: 5).fill(color).frame(width: 16, height: 16)
                .overlay(Text(text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        }
    }
}
