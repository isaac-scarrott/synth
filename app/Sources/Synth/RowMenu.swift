import SwiftUI

/// The hover-kebab popover. Level-scoped Create + Delete, where Delete swaps the
/// menu to an inline two-step confirm (working.html's non-invasive pattern).
struct RowMenu: View {
    enum Level { case workspace, branch, session }

    let level: Level
    var onCreate: (() -> Void)?
    var onDelete: () -> Void
    @Binding var isPresented: Bool

    @State private var confirming = false

    private var createTitle: String? {
        switch level {
        case .workspace: return "Create branch…"
        case .branch:    return "New terminal"
        case .session:   return nil
        }
    }
    private var createIcon: String {
        level == .workspace ? Phosphor.branch : Phosphor.terminal
    }
    private var confirmLabel: String {
        switch level {
        case .workspace: return "Delete this workspace and all its branches?"
        case .branch:    return "Delete this branch and its sessions?"
        case .session:   return "Delete this session?"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if confirming {
                Text(confirmLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
                HStack(spacing: 6) {
                    Spacer()
                    Button("Cancel") { confirming = false }
                        .buttonStyle(MenuButtonStyle(danger: false))
                    Button("Delete") { onDelete(); isPresented = false }
                        .buttonStyle(MenuButtonStyle(danger: true))
                }
                .padding(.horizontal, 6).padding(.bottom, 4)
            } else {
                if let title = createTitle, let onCreate {
                    MenuItem(icon: createIcon, title: title, danger: false) {
                        isPresented = false
                        onCreate()
                    }
                    Divider().padding(.vertical, 2)
                }
                MenuItem(icon: Phosphor.trash, title: "Delete", danger: true) { confirming = true }
            }
        }
        .padding(6)
        .frame(width: 232)
        .background(Theme.panel)
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
            HStack(spacing: 8) {
                Phos(path: icon, size: 15).frame(width: 16)
                Text(title).font(.system(size: 12.5))
                Spacer()
            }
            .foregroundStyle(danger ? Theme.danger : Theme.ink)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? (danger ? Theme.danger.opacity(0.1) : Theme.rowSelected) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MenuButtonStyle: ButtonStyle {
    let danger: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(danger ? .white : Theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(danger ? Theme.danger : Theme.rowSelected)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
