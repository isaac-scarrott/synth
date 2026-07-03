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
            IconButton(path: Phosphor.sidebar, help: "Collapse sidebar") {
                store.sidebarCollapsed = true
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44, alignment: .center)
    }

    private var header: some View {
        HStack {
            Text("WORKSPACE")
                .font(.system(size: 10.5, weight: .semibold)).kerning(0.6)
                .foregroundStyle(Theme.inkFaint)
            Spacer()
            IconButton(path: Phosphor.plus, size: 14, help: "Add workspace") {
                store.addingWorkspace = true
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
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
            .help("\(workspace.name) · \(workspace.branches.count) branches")

            Reveal(open: isOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(workspace.branches) { BranchRow(branch: $0, workspace: workspace) }
                }
                .padding(.leading, 18)
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
        // The branch containing the open session, else the expanded live group —
        // matches working.html showing the pill on the active group at rest.
        if let open = store.openSession { return store.branch(of: open)?.id == branch.id }
        return branch.isLive && isOpen
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
                            .fontWeight(isActivePill ? .medium : .regular)
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
            .help(branch.isLive ? "\(branch.name) · \(branch.sessions.count) sessions" : branch.name)

            Reveal(open: branch.isLive && isOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(branch.sessions) { SessionRow(session: $0) }
                }
                .padding(.leading, 15)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.06)).frame(width: 1)
                }
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
                    Phos(path: session.kind.iconPath, size: 15)
                        .foregroundStyle(session.kind.tint).frame(width: 16)
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
        .help("\(session.title) · \(session.status.label)")
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
            Phos(path: Phosphor.dots, size: 16)
                .foregroundStyle(Theme.inkFaint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Actions")
        .popover(isPresented: $showMenu, arrowEdge: .trailing) {
            RowMenu(level: level, onCreate: onCreate, onDelete: onDelete, isPresented: $showMenu)
        }
    }
}

private struct Chevron: View {
    let open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Phos(path: Phosphor.caret, size: 12)
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
            case .running: Dot(color: Theme.run, halo: true)
            case .idle:    Dot(color: Theme.idle)
            case .exited:  Dot(color: Theme.idle).opacity(0.5)
            case .working: Dot(color: Theme.working, halo: true).pulse()
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
            case .run:   Dot(color: Theme.run, halo: true)
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
        Phos(path: state == .input ? Phosphor.question : Phosphor.exclamation, size: 15)
            .foregroundStyle(state == .input ? Theme.attention : Theme.danger)
    }
}

private struct Dot: View {
    let color: Color
    var halo: Bool = false
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .background(
                halo ? Circle().fill(color.opacity(0.16)).frame(width: 11, height: 11) : nil
            )
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

/// The mock's `.icon-btn`: 26×26, radius 7, hover 5% bg, press scale 0.94.
struct IconButton: View {
    let path: String
    var size: CGFloat = 15
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Phos(path: path, size: size)
                .foregroundStyle(hovering ? Theme.inkMuted : Theme.inkFaint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.black.opacity(0.05) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(IconPressStyle())
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct IconPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.rowHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Height-accordion reveal — matches working.html's 0fr→1fr grid-rows transition
/// (185ms) plus the inner opacity fade. Content is always present and measured;
/// only its clipped height + opacity animate.
struct Reveal<Content: View>: View {
    let open: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var natural: CGFloat = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { natural = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in natural = h }
                }
            )
            .frame(height: open ? natural : 0, alignment: .top)
            .opacity(open ? 1 : 0)
            .clipped()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.185), value: open)
    }
}
