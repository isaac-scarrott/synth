import AppKit
import GhosttyKit

/// The login-shell command every session runs. The embedded terminal engine's core spawn
/// injects its own identity into the child environment — vendor `*_RESOURCES_DIR`/`*_BIN_DIR`
/// vars, its app bundle on `PATH`/`MANPATH`/`XDG_DATA_DIRS`, `TERMINFO`, `__CFBundleIdentifier`
/// — and neither config nor the env we pass can suppress it (the engine overwrites afterwards).
/// So the shell is launched through this wrapper, which scrubs all of that before exec'ing the
/// user's login shell: a Synth terminal looks like a plain shell, never revealing what renders it.
enum TerminalLauncher {
    static let command: String = {
        let script = """
        #!/bin/sh
        strip() { printf '%s' "$1" | sed -e 's#[^:]*[Gg]hostty[^:]*:##g' -e 's#:[^:]*[Gg]hostty[^:]*##g'; }
        PATH="$(strip "$PATH")"; MANPATH="$(strip "$MANPATH")"; XDG_DATA_DIRS="$(strip "$XDG_DATA_DIRS")"
        export PATH MANPATH XDG_DATA_DIRS
        unset GHOSTTY_RESOURCES_DIR GHOSTTY_BIN_DIR GHOSTTY_SHELL_FEATURES GHOSTTY_SURFACE_ID CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION __CFBundleIdentifier TERMINFO
        exec "${SHELL:-/bin/zsh}" -l -i
        """
        let path = NSTemporaryDirectory() + "synth-login-\(getpid()).sh"
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }()
}

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

        let view = GhosttySurfaceView(session: session, cwd: cwd, env: env, command: TerminalLauncher.command, bus: bus)
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
