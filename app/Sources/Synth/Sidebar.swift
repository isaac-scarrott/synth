import SwiftUI

struct Sidebar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        .background(Theme.panel)
    }

    private var header: some View {
        HStack {
            Text("WORKSPACE")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.inkFaint)
            Spacer()
            Button(action: pickWorkspace) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, Theme.titlebarInset + 6)
        .padding(.bottom, 8)
    }

    private func pickWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.addWorkspace(url: url)
        }
    }
}

// MARK: - Workspace (tier 1)

private struct WorkspaceRow: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace

    private var isOpen: Bool { store.expanded.contains(workspace.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { store.toggleExpanded(workspace.id) } label: {
                HStack(spacing: 8) {
                    Chevron(open: isOpen)
                    Monogram(text: workspace.monogram,
                             color: Theme.chipColors[workspace.colorIndex % Theme.chipColors.count])
                    Text(workspace.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    if !isOpen {
                        Text("\(workspace.branches.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.inkFaint)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())

            if isOpen {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(workspace.branches) { BranchRow(branch: $0) }
                }
                .padding(.leading, 18)
            }
        }
    }
}

// MARK: - Branch (tier 2)

private struct BranchRow: View {
    @Environment(AppStore.self) private var store
    let branch: Branch

    private var isOpen: Bool { store.expanded.contains(branch.id) }
    private var isActivePill: Bool {
        // Derived (ADR-0005): the branch that contains the open session.
        guard let open = store.openSession else { return false }
        return store.branch(of: open)?.id == branch.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if branch.isLive { store.toggleExpanded(branch.id) }
                store.navCursor = branch.id
            } label: {
                HStack(spacing: 6) {
                    if branch.isLive { Chevron(open: isOpen) } else { Spacer().frame(width: 12) }
                    Text(branch.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(isActivePill ? Theme.ink : Theme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    BranchRollup(branch: branch)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isActivePill
                        ? RoundedRectangle(cornerRadius: 7).fill(Color.white)
                            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                        : nil
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())

            if isOpen {
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
}

// MARK: - Session (tier 3)

private struct SessionRow: View {
    @Environment(AppStore.self) private var store
    let session: Session

    private var isOpen: Bool { store.openSessionID == session.id }

    var body: some View {
        Button { store.open(session) } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.unread ? Theme.ink : .clear)
                    .frame(width: 4, height: 4)
                Image(systemName: session.kind.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(session.kind.tint)
                    .frame(width: 16)
                Text(session.title)
                    .font(.system(size: 12.5))
                    .fontWeight(session.unread ? .medium : .regular)
                    .foregroundStyle(session.unread ? Theme.ink : Theme.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusIndicator(status: session.status)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isOpen ? RoundedRectangle(cornerRadius: 7).fill(Theme.rowSelected) : nil
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

// MARK: - Bits

private struct Chevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.inkFaint)
            .rotationEffect(.degrees(open ? 90 : 0))
            .frame(width: 12)
    }
}

private struct Monogram: View {
    let text: String
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(color)
            .frame(width: 19, height: 19)
            .overlay(Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
    }
}

private struct StatusIndicator: View {
    let status: SessionStatus
    var body: some View {
        Group {
            switch status {
            case .running, .idle:
                Circle().fill(status.isLive ? Theme.run : Theme.idle).frame(width: 6, height: 6)
            case .working:
                Circle().fill(Color(hex: 0xF5A623)).frame(width: 6, height: 6)
            case .needsInput:
                Image(systemName: "questionmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.attention)
            case .error:
                Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.danger)
            case .exited:
                Circle().fill(Theme.idle).frame(width: 6, height: 6).opacity(0.5)
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct BranchRollup: View {
    let branch: Branch
    var body: some View {
        if branch.sessions.contains(where: { $0.status.isLive }) {
            Circle().fill(Theme.run).frame(width: 6, height: 6)
        } else if !branch.lastActivity.isEmpty {
            Text(branch.lastActivity)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.inkFaint)
                .monospacedDigit()
        }
    }
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
