import SwiftUI

/// The hover-kebab popover content. Level-scoped Create + Delete, where Delete
/// swaps to an inline two-step confirm (design.html's non-invasive pattern).
/// Styling matches the mock's `.menu` / `.menu__item` / `.menu__confirm` exactly.
struct RowMenu: View {
    enum Level { case workspace, branch, session }

    let level: Level
    var creates: [MenuCreate]
    var onDelete: () -> Void
    /// Overrides the level's stock confirm copy (ActiveMenu.confirmText).
    var confirmText: String? = nil
    @Binding var isPresented: Bool
    /// Lifted to the store so the `d` shortcut can open straight into confirm and ↵ can commit.
    @Binding var confirming: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Workspaces and branches are *removed* — sidebar-only; worktrees and branches
    /// stay on disk. Sessions are deleted for real (the process ends).
    private var deleteTitle: String {
        level == .session ? "Delete" : "Remove"
    }
    private var confirmLabel: String {
        if let confirmText { return confirmText }
        switch level {
        case .workspace: return "Remove this workspace from the sidebar? Nothing on disk is deleted."
        case .branch:    return "Remove this branch from the sidebar? Its worktree stays on disk."
        case .session:   return "Delete this session?"
        }
    }

    var body: some View {
        // The confirm step morphs in place: the container animates its height while
        // the panes crossfade — one continuous object, not a jump-cut swap
        // (FEATURES "Delete-confirm morphs in place").
        VStack(alignment: .leading, spacing: 0) {
            if confirming {
                confirmPane.transition(.opacity)
            } else {
                actionsPane.transition(.opacity)
            }
        }
        .padding(5)
        .frame(width: 178)
        .background(Theme.panel)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.19), value: confirming)
    }

    private var confirmPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(confirmLabel)
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .foregroundStyle(Theme.ink4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2).padding(.top, 2).padding(.bottom, 9)
            HStack(spacing: 6) {
                ConfirmButton(title: "Cancel", danger: false) { confirming = false }
                ConfirmButton(title: deleteTitle, danger: true) { onDelete(); isPresented = false }
            }
        }
        .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 8)
    }

    @ViewBuilder private var actionsPane: some View {
        ForEach(creates) { create in
            MenuItem(icon: create.icon, title: create.title, danger: false) {
                isPresented = false
                create.run()
            }
        }
        if !creates.isEmpty {
            Rectangle().fill(Theme.border).frame(height: 0.5)
                .padding(.horizontal, 6).padding(.vertical, 4)
        }
        MenuItem(icon: Phosphor.trash, title: deleteTitle, danger: true) { confirming = true }
    }
}

private struct MenuItem: View {
    let icon: String
    let title: String
    let danger: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Phos(path: icon, size: 15)
                    .foregroundStyle(danger ? Theme.danger : Theme.menuIcon)
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(danger ? Theme.danger : Theme.repoName)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ConfirmButton: View {
    let title: String
    let danger: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(danger ? .white : Theme.repoName)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(danger ? Theme.danger : Theme.raised)
                        .overlay(
                            danger ? nil :
                                RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 0.5)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
