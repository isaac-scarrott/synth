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
                SessionPane(session: session)
                    .id(session.id)
            } else {
                PaneEmpty()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
    }
}

/// working.html `.pane`: head (title · crumb · spacer · chip) over the session body,
/// entering with the 220ms fade + 4px rise.
private struct SessionPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: Session
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHead(session: session,
                     workspace: store.branch(of: session).flatMap { store.workspace(of: $0) },
                     branch: store.branch(of: session))
            paneBody
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 4)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.easeOut(duration: 0.22)) { shown = true } }
        }
    }

    @ViewBuilder private var paneBody: some View {
        switch session.kind {
        case .terminal:
            if let cwd = store.cwd(for: session) {
                TermSurface(terminal: TerminalManager.shared.view(for: session, cwd: cwd))
            }
        case .claudeCode:
            Placeholder(title: session.title,
                        subtitle: "Claude Code sessions aren't wired up yet.")
        }
    }
}

/// working.html `.pane__head`: 13/18 padding, hairline bottom border, 12 gap.
private struct PaneHead: View {
    let session: Session
    let workspace: Workspace?
    let branch: Branch?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Phos(path: session.kind.iconPath, size: 15)
                    .foregroundStyle(session.kind.tint)
                    .frame(width: 15, height: 15)
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(-0.13)
                    .foregroundStyle(Theme.ink)
            }
            // Crumb: `<b>workspace</b> / branch` — mono 11, faint, workspace muted.
            if let ws = workspace, let br = branch {
                (Text(ws.name).foregroundColor(Theme.inkMuted).fontWeight(.medium)
                    + Text(" / \(br.name)").foregroundColor(Theme.inkFaint))
                    .font(.system(size: 11, design: .monospaced))
                    .kerning(-0.11)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            StateChip(status: session.status)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
    }
}

/// working.html `.chip`: state pill mirroring the sidebar liveness vocabulary.
private struct StateChip: View {
    let status: SessionStatus

    private var label: String { status.paletteLabel }

    private var ink: SwiftUI.Color {
        switch status {
        case .running:       return Color(hex: 0x1F8F43)
        case .working:       return Color(hex: 0xA56A12)
        case .needsInput:    return Color(hex: 0x0A63C4)
        case .error:         return Color(hex: 0xCF2B22)
        case .idle, .exited: return Theme.inkMuted
        }
    }
    private var bg: SwiftUI.Color {
        switch status {
        case .running:       return Theme.run.opacity(0.12)
        case .working:       return Theme.working.opacity(0.15)
        case .needsInput:    return Theme.attention.opacity(0.12)
        case .error:         return Theme.danger.opacity(0.12)
        case .idle, .exited: return Color.black.opacity(0.045)
        }
    }
    private var dot: SwiftUI.Color {
        switch status {
        case .running:       return Theme.run
        case .working:       return Theme.working
        case .needsInput:    return Theme.attention
        case .error:         return Theme.danger
        case .idle, .exited: return Theme.idle
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if case .working = status {
                    Circle().fill(dot).sdotPulse()
                } else {
                    Circle().fill(dot)
                }
            }
            .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .kerning(0.105)
        }
        .foregroundStyle(ink)
        .padding(.leading, 7).padding(.trailing, 9).padding(.vertical, 3)
        .background(Capsule().fill(bg))
    }
}

/// working.html `.term`: the dark rounded card the shell lives in — 14 margin,
/// 13/15 inner padding, #1b1b1e, inset hairline + soft drop shadow.
private struct TermSurface: View {
    let terminal: LocalProcessTerminalView

    var body: some View {
        TerminalHost(terminal: terminal)
            .padding(.vertical, 13).padding(.horizontal, 15)
            .background(Color(hex: 0x1B1B1E))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .padding(14)
    }
}

/// working.html `.pane-empty`: centered terminal mark + "No session open".
private struct PaneEmpty: View {
    var body: some View {
        VStack(spacing: 12) {
            Phos(path: Phosphor.terminal, size: 26)
                .foregroundStyle(Theme.inkFaint)
                .opacity(0.5)
            Text("No session open")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.inkFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
