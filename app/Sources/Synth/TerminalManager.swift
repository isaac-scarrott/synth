import AppKit
import GhosttyKit

/// The login-shell command every session runs. The embedded terminal engine's core spawn
/// injects its own identity into the child environment — vendor `*_RESOURCES_DIR`/`*_BIN_DIR`
/// vars, its app bundle on `PATH`/`MANPATH`/`XDG_DATA_DIRS`, `TERMINFO`, `__CFBundleIdentifier`
/// — and neither config nor the env we pass can suppress it (the engine overwrites afterwards).
/// So the shell is launched through this wrapper, which scrubs all of that before exec'ing the
/// user's login shell: a Synth terminal looks like a plain shell, never revealing what renders it.
///
/// An agent row's launch line rides in on `$SYNTH_LAUNCH_COMMAND` and is handed to the shell as
/// `-c`, never written into its stdin. Startup files routinely read the tty themselves — oh-my-zsh's
/// update prompt takes a single keypress, nvm/asdf/fnm and bash-preexec installers ask questions —
/// and anything already queued there is theirs to eat: one stolen byte turned `exec claude` into
/// `xec claude`. As an argument the line cannot be consumed by whatever the user's rc files do,
/// on any shell.
enum TerminalLauncher {
    static let command: String = {
        let script = """
        #!/bin/sh
        strip() { printf '%s' "$1" | sed -e 's#[^:]*[Gg]hostty[^:]*:##g' -e 's#:[^:]*[Gg]hostty[^:]*##g'; }
        PATH="$(strip "$PATH")"; MANPATH="$(strip "$MANPATH")"; XDG_DATA_DIRS="$(strip "$XDG_DATA_DIRS")"
        export PATH MANPATH XDG_DATA_DIRS
        unset GHOSTTY_RESOURCES_DIR GHOSTTY_BIN_DIR GHOSTTY_SHELL_FEATURES GHOSTTY_SURFACE_ID CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION __CFBundleIdentifier TERMINFO
        launch="$SYNTH_LAUNCH_COMMAND"; unset SYNTH_LAUNCH_COMMAND
        [ -n "$launch" ] && exec "${SHELL:-/bin/zsh}" -l -i -c "$launch"
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
    /// The app's hook socket path, injected into every PTY so agent hooks can call back.
    var hookSocketPath = ""
    private var views: [UUID: GhosttySurfaceView] = [:]

    func view(for session: Session, cwd: URL, agentFlags: String = "") -> GhosttySurfaceView {
        if let existing = views[session.id] { return existing }

        GhosttyApp.shared.bus = bus
        GhosttyApp.shared.start()

        var base = ProcessInfo.processInfo.environment
        // libghostty sets its own TERM to match `term` in the inline config.
        base.removeValue(forKey: "TERM")
        // decorate() lets every installed agent's supervisor stamp its env — including the port
        // opencode's server will listen on. Supervisors are attached by the agent-start signal
        // (Hooks), never here: a launched agent is not yet a reachable one.
        let env = HookEnvironment.decorate(base, sessionID: session.id, socketPath: hookSocketPath)

        let view = GhosttySurfaceView(session: session, cwd: cwd, env: env,
                                      command: TerminalLauncher.command, agentFlags: agentFlags, bus: bus)
        views[session.id] = view
        return view
    }

    /// The live view for a session, if one has already been created — never spins up a
    /// shell. Used to move first-responder focus onto an open terminal (⌘1).
    func existingView(_ id: UUID) -> GhosttySurfaceView? { views[id] }

    /// The session whose surface is (or contains) `view` — the reverse of `existingView`,
    /// so a first-responder change can be mapped back to the pane that owns it. The
    /// responder may be the surface itself or one of its subviews.
    func sessionID(containing view: NSView) -> UUID? {
        views.first { view === $0.value || view.isDescendant(of: $0.value) }?.key
    }

    /// Feed `text` into a session's PTY as pasted input, then press Enter to submit —
    /// how a browser comment reaches the branch's Claude Code session (ADR-0011 stage
    /// three). The Enter trails by a beat so the TUI finishes ingesting the paste
    /// before it sees the submit. False when the session has no live terminal.
    @discardableResult
    func submit(_ text: String, to id: UUID) -> Bool {
        guard let view = views[id] else { return false }
        view.sendPaste(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            view.sendTypedText("\r")
        }
        return true
    }

    func terminate(_ id: UUID) {
        views[id]?.close()
        views[id] = nil
    }

    /// Tear down every live terminal on app quit — free each surface and reap its PTY
    /// process tree (login → shell → agent → MCP servers). App quit doesn't route through
    /// closeSession/removeBranch, and nothing else frees these, so without this every open
    /// session's whole process tree is orphaned to launchd when Synth exits. Mirror of
    /// BrowserManager.shutdownAll; both are driven off the willTerminate observer.
    func shutdownAll() {
        for view in views.values { view.close() }
        views.removeAll()
    }
}
