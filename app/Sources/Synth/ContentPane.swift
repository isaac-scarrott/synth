import SwiftUI
import AppKit

/// Hosts a managed terminal NSView. The view is owned by TerminalManager (not created
/// here), so SwiftUI re-parenting it never restarts the shell.
struct TerminalHost: NSViewRepresentable {
    let terminal: GhosttySurfaceView

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
            if store.settingsOpen {
                SettingsPane()
            } else if let session = store.openSession {
                SessionPane(session: session)
                    .id(session.id)
            } else if let branch = store.openSetupBranch {
                WorktreeSetupPane(branch: branch)
                    .id(branch.id)
            } else {
                PaneEmpty()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        // In-app notification deck, bottom-left hugging the sidebar — hidden in settings
        // (working.html `.app.settings .notifs { display: none }`).
        .overlay(alignment: .bottomLeading) {
            if !store.settingsOpen { NotificationDeck() }
        }
    }
}

/// working.html `.pane`: head (title · crumb · spacer) over the session body,
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

    // A session — terminal or Claude Code — is backed by a PTY running in its worktree;
    // Claude Code just runs `claude` inside it. The kind drives the sidebar/head visual,
    // not what the pane shows. A browser session hosts an engine instead of a PTY.
    @ViewBuilder private var paneBody: some View {
        if session.kind == .browser {
            BrowserPane(session: session)
        } else if let cwd = store.cwd(for: session) {
            let flags = store.claudeFlags(for: store.branch(of: session).flatMap { store.workspace(of: $0) })
            TermSurface(terminal: TerminalManager.shared.view(for: session, cwd: cwd, claudeFlags: flags))
        } else {
            Placeholder(title: session.title, subtitle: "No working directory for this session.")
        }
    }
}

/// working.html `.pane__head`: the titlebar band, 18pt side padding, hairline bottom border.
private struct PaneHead: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let workspace: Workspace?
    let branch: Branch?

    private var collapsed: Bool { store.sidebarCollapsed }

    var body: some View {
        HStack(spacing: 10) {
            // Collapsed: the expand toggle binds into the header cluster right after the
            // traffic lights, so it's part of the toolbar rather than a floating orphan.
            // The 2pt tops the HStack's 10 up to the mock's 12pt gap before the title.
            if collapsed {
                SidebarToggle().padding(.trailing, 2)
            }
            Phos(path: session.kind.iconPath, size: 15)
                .foregroundStyle(session.kind.tint)
                .frame(width: 15, height: 15)
            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .kerning(-0.13)
                .foregroundStyle(Theme.ink)
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
        }
        // Collapsed, the header starts past the traffic lights; either way it is the same band
        // as the sidebar strip, so the title sits on the traffic-light centre line.
        .padding(.leading, collapsed ? Theme.trafficLightsClearance : 18)
        .padding(.trailing, 18)
        .frame(height: Theme.titlebarHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
    }
}

/// working.html `.term`: the dark rounded card the shell lives in — 14 margin,
/// 13/15 inner padding, #1b1b1e, inset hairline + soft drop shadow.
private struct TermSurface: View {
    let terminal: GhosttySurfaceView

    var body: some View {
        TerminalHost(terminal: terminal)
            .padding(.vertical, 13).padding(.horizontal, 15)
            .background(Theme.tuiBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.tuiHair, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
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

/// The optimistic "setting up worktree…" skeleton: shown the instant a create is
/// requested (so the switch rides the keystroke), resolving in place into the first
/// session once the checkout lands — but only while the user is still parked here
/// (Store.applySessionTemplate). Same head shape as a real session pane so the resolve
/// is a quiet cross-fade, not a jump.
private struct WorktreeSetupPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let branch: Branch
    @State private var shown = false

    private var collapsed: Bool { store.sidebarCollapsed }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if collapsed {
                    SidebarToggle().padding(.trailing, 2)
                }
                Phos(path: Phosphor.branch, size: 15)
                    .foregroundStyle(Theme.inkFaint)
                    .frame(width: 15, height: 15)
                Text(branch.name)
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(-0.13)
                    .foregroundStyle(Theme.ink)
                if let ws = store.workspace(of: branch) {
                    (Text(ws.name).foregroundColor(Theme.inkMuted).fontWeight(.medium)
                        + Text(" / \(branch.name)").foregroundColor(Theme.inkFaint))
                        .font(.system(size: 11, design: .monospaced))
                        .kerning(-0.11)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, collapsed ? Theme.trafficLightsClearance : 18)
            .padding(.trailing, 18)
            .frame(height: Theme.titlebarHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 0.5)
            }

            VStack(spacing: 12) {
                SetupSpinner()
                Text("Setting up worktree…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 4)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.easeOut(duration: 0.22)) { shown = true } }
        }
    }
}

/// The setup pane's centred arc spinner — the pending-row spinner (Sidebar) scaled up
/// to carry the empty pane.
private struct SetupSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(Theme.inkFaint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 22, height: 22)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear { spinning = true }
    }
}

private struct Placeholder: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.copper)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
