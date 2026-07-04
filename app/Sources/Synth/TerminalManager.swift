import AppKit
import GhosttyKit

/// Owns the live terminal NSViews, keyed by session id, *outside* the SwiftUI view tree —
/// so a session's shell process survives navigating away and back. Each view hosts one
/// libghostty surface (GhosttySurfaceView); libghostty owns the PTY firehose and renderer,
/// and only derived facts (child exited) reach the store via the bus.
@MainActor final class TerminalManager {
    static let shared = TerminalManager()

    weak var bus: EventBus?
    /// The app's hook socket path, injected into every PTY so Claude Code hooks can call back.
    var hookSocketPath = ""
    private var views: [UUID: GhosttySurfaceView] = [:]

    func view(for session: Session, cwd: URL) -> GhosttySurfaceView {
        if let existing = views[session.id] { return existing }

        GhosttyApp.shared.bus = bus
        GhosttyApp.shared.start()

        var base = ProcessInfo.processInfo.environment
        // libghostty sets its own TERM to match `term` in the inline config.
        base.removeValue(forKey: "TERM")
        let env = HookEnvironment.decorate(base, sessionID: session.id, socketPath: hookSocketPath)

        let view = GhosttySurfaceView(session: session, cwd: cwd, env: env, bus: bus)
        views[session.id] = view
        return view
    }

    /// The live view for a session, if one has already been created — never spins up a
    /// shell. Used to move first-responder focus onto an open terminal (⌘1).
    func existingView(_ id: UUID) -> GhosttySurfaceView? { views[id] }

    func terminate(_ id: UUID) {
        views[id]?.close()
        views[id] = nil
    }
}
