import AppKit
import SwiftTerm

/// Owns the live terminal NSViews, keyed by session id, *outside* the SwiftUI view
/// tree — so a session's shell process survives navigating away and back. This is
/// the local, high-frequency layer: the PTY firehose lives entirely in these views
/// and never reaches the store. Only derived facts are posted onto the bus.
@MainActor final class TerminalManager {
    static let shared = TerminalManager()

    weak var bus: EventBus?
    /// The app's hook socket path, injected into every PTY so Claude Code hooks can call back.
    var hookSocketPath = ""
    private var views: [UUID: LocalProcessTerminalView] = [:]
    private var supervisors: [UUID: TerminalSupervisor] = [:]

    func view(for session: Session, cwd: URL) -> LocalProcessTerminalView {
        if let existing = views[session.id] { return existing }

        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let supervisor = TerminalSupervisor(sessionID: session.id, bus: bus)
        view.processDelegate = supervisor

        // working.html's .term surface: #1b1b1e card, #d4d4d8 text, 12px mono.
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(name: nil) { $0.isDarkAqua ? NSColor(hex: 0x131315) : NSColor(hex: 0x1B1B1E) }
        view.nativeForegroundColor = NSColor(srgbRed: 212/255, green: 212/255, blue: 216/255, alpha: 1)
        // The mock's term shows no scrollbar gutter; scrollback still works via wheel.
        for sub in view.subviews where sub is NSScroller { sub.isHidden = true }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // A Claude session is a terminal that runs `claude` on entry (through the shimmed
        // PATH, so hooks auto-attach); when Claude exits it drops back to an interactive
        // shell. A plain terminal is detected the same way if the user runs `claude` by hand.
        let launch = shellQuote(shell) + " -il"
        let inner = session.kind == .claudeCode ? "claude; exec \(launch)" : "exec \(launch)"
        let command = "cd \(shellQuote(cwd.path)) && \(inner)"

        var base = ProcessInfo.processInfo.environment
        base["TERM"] = "xterm-256color"
        let env = HookEnvironment.decorate(base, sessionID: session.id, socketPath: hookSocketPath)
        view.startProcess(executable: "/bin/sh", args: ["-c", command],
                          environment: env.map { "\($0.key)=\($0.value)" })

        views[session.id] = view
        supervisors[session.id] = supervisor
        return view
    }

    /// The live view for a session, if one has already been created — never spins up
    /// a shell. Used to move first-responder focus onto an open terminal (⌘1).
    func existingView(_ id: UUID) -> LocalProcessTerminalView? { views[id] }

    func terminate(_ id: UUID) {
        views[id] = nil
        supervisors[id] = nil
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The transducer for a terminal session: it watches the PTY view's lifecycle and
/// emits only the occasional derived status fact onto the bus (docs/adr/0001).
final class TerminalSupervisor: NSObject, LocalProcessTerminalViewDelegate {
    let sessionID: UUID
    weak var bus: EventBus?

    init(sessionID: UUID, bus: EventBus?) {
        self.sessionID = sessionID
        self.bus = bus
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            bus?.post(.exited(sessionID, exitCode))
        }
    }
}
