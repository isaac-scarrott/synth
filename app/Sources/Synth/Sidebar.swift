import SwiftUI
import AppKit

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topStrip
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.workspaces) { WorkspaceRow(workspace: $0) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.185), value: store.expanded)
            }
        }
        .frame(width: Theme.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .onContinuousHover { phase in
            if case .active = phase { store.keyboardActive = false }
        }
    }

    private var topStrip: some View {
        HStack {
            Spacer()
            Button { store.sidebarCollapsed = true } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.inkFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, Theme.titlebarInset)
        .frame(height: Theme.titlebarInset + 14)
    }

    private var header: some View {
        HStack {
            Text("WORKSPACE")
                .font(.system(size: 10.5, weight: .semibold)).kerning(0.6)
                .foregroundStyle(Theme.inkFaint)
            Spacer()
            Button { store.addingWorkspace = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

// MARK: - Workspace (tier 1)

private struct WorkspaceRow: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace
    @State private var hovering = false
    @State private var showMenu = false

    private var isOpen: Bool { store.expanded.contains(workspace.id) }
    private var selected: Bool { store.keyboardActive && store.navCursor == workspace.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ZStack(alignment: .trailing) {
                Button {
                    focusSidebar()
                    store.toggleExpanded(workspace.id)
                    store.navCursor = workspace.id
                } label: {
                    HStack(spacing: 8) {
                        Chevron(open: isOpen)
                        Monogram(text: workspace.monogram,
                                 color: Theme.chipColors[workspace.colorIndex % Theme.chipColors.count])
                        Text(workspace.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 4)
                        trailing.opacity(hovering || showMenu ? 0 : 1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())

                KebabButton(showMenu: $showMenu, level: .workspace,
                            onCreate: { store.creatingBranchIn = workspace },
                            onDelete: { store.deleteWorkspace(workspace) })
                    .opacity(hovering || showMenu ? 1 : 0)
                    .padding(.trailing, 10)
            }
            .rowChrome(hovering: hovering, selected: selected)
            .onHover { hovering = $0 }

            if isOpen {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(workspace.branches) { BranchRow(branch: $0, workspace: workspace) }
                }
                .padding(.leading, 18)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if !isOpen {
            HStack(spacing: 6) {
                if let a = workspace.attention { AttentionGlyph(state: a) }
                Text("\(workspace.branches.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkFaint).monospacedDigit()
            }
        }
    }
}

// MARK: - Branch (tier 2)

private struct BranchRow: View {
    @Environment(AppStore.self) private var store
    let branch: Branch
    let workspace: Workspace
    @State private var hovering = false
    @State private var showMenu = false

    private var isOpen: Bool { store.expanded.contains(branch.id) }
    private var selected: Bool { store.keyboardActive && store.navCursor == branch.id }
    private var isActivePill: Bool {
        guard let open = store.openSession else { return false }
        return store.branch(of: open)?.id == branch.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ZStack(alignment: .trailing) {
                Button {
                    focusSidebar()
                    if branch.isLive { store.toggleExpanded(branch.id) }
                    store.navCursor = branch.id
                } label: {
                    HStack(spacing: 6) {
                        if branch.isLive { Chevron(open: isOpen) } else { Spacer().frame(width: 12) }
                        Text(branch.name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(isActivePill ? Theme.ink : Theme.inkMuted)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        BranchRollup(branch: branch).opacity(hovering || showMenu ? 0 : 1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(activePillBackground)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())

                KebabButton(showMenu: $showMenu, level: .branch,
                            onCreate: { store.newTerminal(in: branch) },
                            onDelete: { store.deleteBranch(branch) })
                    .opacity(hovering || showMenu ? 1 : 0)
                    .padding(.trailing, 10)
            }
            .rowChrome(hovering: hovering, selected: selected)
            .onHover { hovering = $0 }

            if branch.isLive && isOpen {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(branch.sessions) { SessionRow(session: $0) }
                }
                .padding(.leading, 15)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1)
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, 11)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1)
        }
    }

    @ViewBuilder private var activePillBackground: some View {
        if isActivePill {
            RoundedRectangle(cornerRadius: 7).fill(Color.white)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        }
    }
}

// MARK: - Session (tier 3)

private struct SessionRow: View {
    @Environment(AppStore.self) private var store
    let session: Session
    @State private var hovering = false
    @State private var showMenu = false

    private var isOpen: Bool { store.openSessionID == session.id }
    private var selected: Bool { store.keyboardActive && store.navCursor == session.id }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button { store.open(session) } label: {
                HStack(spacing: 8) {
                    Circle().fill(session.unread ? Theme.ink : .clear).frame(width: 4, height: 4)
                    Image(systemName: session.kind.symbol)
                        .font(.system(size: 12)).foregroundStyle(session.kind.tint).frame(width: 16)
                    Text(session.title)
                        .font(.system(size: 12.5))
                        .fontWeight(session.unread ? .medium : .regular)
                        .foregroundStyle(session.unread ? Theme.ink : Theme.inkMuted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    StatusIndicator(status: session.status).opacity(hovering || showMenu ? 0 : 1)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(isOpen ? RoundedRectangle(cornerRadius: 7).fill(Theme.rowSelected) : nil)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())

            KebabButton(showMenu: $showMenu, level: .session,
                        onCreate: nil,
                        onDelete: { store.closeSession(session) })
                .opacity(hovering || showMenu ? 1 : 0)
                .padding(.trailing, 8)
        }
        .rowChrome(hovering: hovering, selected: selected)
        .onHover { hovering = $0 }
    }
}

// MARK: - Shared bits

private struct KebabButton: View {
    @Binding var showMenu: Bool
    let level: RowMenu.Level
    var onCreate: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        Button { showMenu = true } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkFaint)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMenu, arrowEdge: .trailing) {
            RowMenu(level: level, onCreate: onCreate, onDelete: onDelete, isPresented: $showMenu)
        }
    }
}

private struct Chevron: View {
    let open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.inkFaint)
            .rotationEffect(.degrees(open ? 90 : 0))
            .frame(width: 12)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: open)
    }
}

private struct Monogram: View {
    let text: String
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 6).fill(color).frame(width: 19, height: 19)
            .overlay(Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
    }
}

private struct StatusIndicator: View {
    let status: SessionStatus
    var body: some View {
        Group {
            switch status {
            case .running: Dot(color: Theme.run)
            case .idle:    Dot(color: Theme.idle)
            case .exited:  Dot(color: Theme.idle).opacity(0.5)
            case .working: Dot(color: Theme.working).pulse()
            case .needsInput: AttentionGlyph(state: .input).pulse()
            case .error:      AttentionGlyph(state: .error)
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct BranchRollup: View {
    let branch: Branch
    var body: some View {
        Group {
            switch branch.rollup {
            case .input: AttentionGlyph(state: .input).pulse()
            case .error: AttentionGlyph(state: .error)
            case .work:  Dot(color: Theme.working).pulse()
            case .run:   Dot(color: Theme.run)
            case .idle, .none:
                if !branch.lastActivity.isEmpty {
                    Text(branch.lastActivity)
                        .font(.system(size: 10.5)).foregroundStyle(Theme.inkFaint).monospacedDigit()
                }
            }
        }
        .frame(minWidth: 16, alignment: .trailing)
    }
}

private struct AttentionGlyph: View {
    let state: RollupState
    var body: some View {
        Image(systemName: state == .input ? "questionmark" : "exclamationmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(state == .input ? Theme.attention : Theme.danger)
    }
}

private struct Dot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.25), radius: 0, x: 0, y: 0)
    }
}

// Ambient pulse, reserved for genuine attention (needs-input / working).
private struct PulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion ? 1 : (on ? 1 : 0.45))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

extension View {
    func pulse() -> some View { modifier(PulseModifier()) }

    /// Row hover + keyboard-selection chrome (working.html: hover 3.5%, sel 5% + ring).
    func rowChrome(hovering: Bool, selected: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.rowSelected : (hovering ? Theme.rowHover : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.selRing, lineWidth: 1.5)
                .opacity(selected ? 1 : 0)
        )
    }
}

/// Release the terminal's first-responder status so the global key monitor drives
/// sidebar navigation instead of the shell.
@MainActor func focusSidebar() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.rowHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
