import SwiftUI
import SwiftTerm

/// Hosts a managed terminal NSView. The view is owned by TerminalManager (not created
/// here), so SwiftUI re-parenting it never restarts the shell.
struct TerminalHost: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Focus the shell when a session is opened (this view is rebuilt per
        // session via .id). Not on every update — that would steal focus from
        // the sidebar and dialogs.
        DispatchQueue.main.async { container.window?.makeFirstResponder(terminal) }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let session = store.openSession {
                switch session.kind {
                case .terminal:
                    if let cwd = store.cwd(for: session) {
                        TerminalHost(terminal: TerminalManager.shared.view(for: session, cwd: cwd))
                            .id(session.id)
                            .padding(10)
                    }
                case .claudeCode:
                    Placeholder(title: session.title,
                                subtitle: "Claude Code sessions aren't wired up yet.")
                }
            } else {
                EmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
    }
}

private struct Placeholder: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.claude)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.inkFaint)
            Text("No session open")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
            Text("Press ⌘T to create a terminal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
