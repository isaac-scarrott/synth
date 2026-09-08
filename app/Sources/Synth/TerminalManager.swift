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
    /// Written on demand rather than once at startup: the per-user temp dir is swept of
    /// anything untouched for three days while the app is still running, and a Synth left up
    /// over a long weekend lost the wrapper under itself — every new row then exec'd a path
    /// that no longer existed, died on the spot, and was reported as the agent quitting.
    /// Fallible because the failure mode is the reported bug. This used to `try?` the write,
    /// ignore `chmod`, and hand back the path either way — so a failed write meant every
    /// terminal opened afterwards exec'd a file that wasn't there and died on the spot, which
    /// `login` then reported as exit 0 and the app read as a clean quit. The row vanished.
    /// A path this function has no reason to believe in is not a path it may return.
    static func command() -> Fallible<String> {
        let path = NSTemporaryDirectory() + "synth-login-\(getpid()).sh"
        if FileManager.default.isExecutableFile(atPath: path) { return .success(path) }
        let script = """
        #!/bin/sh
        strip() { printf '%s' "$1" | sed -e 's#[^:]*[Gg]hostty[^:]*:##g' -e 's#:[^:]*[Gg]hostty[^:]*##g'; }
        PATH="$(strip "$PATH")"; MANPATH="$(strip "$MANPATH")"; XDG_DATA_DIRS="$(strip "$XDG_DATA_DIRS")"
        export PATH MANPATH XDG_DATA_DIRS
        unset GHOSTTY_RESOURCES_DIR GHOSTTY_BIN_DIR GHOSTTY_SHELL_FEATURES GHOSTTY_SURFACE_ID CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION __CFBundleIdentifier TERMINFO
        # $SHELL reaches a GUI app from Directory Services, so it names whatever the user last
        # chsh'd to — including a homebrew fish or nushell they have since uninstalled. exec'ing
        # it then fails, `login` reports 0 anyway, and no rc file ever runs to say otherwise:
        # a plain terminal that dies here leaves no trace at all. Say so over the socket while
        # there is still a process to say it with.
        sh="${SHELL:-/bin/zsh}"
        if [ ! -x "$sh" ]; then
          [ -n "$SYNTH_HOOK_BIN" ] && "$SYNTH_HOOK_BIN" report --exit 127 --fault shell_not_executable
          printf 'synth: your login shell (%s) is not executable\\n' "$sh" >&2
          exit 127
        fi
        launch="$SYNTH_LAUNCH_COMMAND"; unset SYNTH_LAUNCH_COMMAND
        [ -n "$launch" ] && exec "$sh" -l -i -c "$launch"
        exec "$sh" -l -i
        """
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return .failure(fault(path, stage: .write, evidence: error.localizedDescription))
        }
        guard chmod(path, 0o755) == 0 else {
            return .failure(fault(path, stage: .write, evidence: String(cString: strerror(errno))))
        }
        // Re-ask rather than trust the two calls above: atomic writes go through a temp file
        // and a rename, and the thing that matters is whether the final path is runnable.
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .failure(fault(path, stage: .resolve, evidence: "The wrapper isn't executable."))
        }
        return .success(path)
    }

    private static func fault(_ path: String, stage: Fault.Detail.Stage,
                              evidence: String) -> Fault.Record {
        Fault.Record(domain: .terminalSpawn, code: .launcherScriptUnwritable,
                     severity: .blocked, session: nil,
                     details: [.stage(stage), .posixErrno(errno)],
                     evidence: evidence,
                     copy: .init(title: "Synth can't start terminals", retry: .restartSynth),
                     site: "TerminalManager.swift")
    }
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

    /// When the user asked for this terminal — armed on *intent*, not on a surface existing,
    /// which is the whole point: the worst failures are the ones where no surface, no PTY and
    /// no exit event ever appear, so a detector that waits for one of those sees nothing.
    private var intentAt: [UUID: Date] = [:]
    private var watchdogs: [UUID: [Task<Void, Never>]] = [:]
    /// Sessions whose death the watchdog has already spoken for, so the exit event that may
    /// follow doesn't say it twice.
    private var claimed: Set<UUID> = []
    /// Sessions that have shown any sign of life since spawning — a hook line, a status
    /// change, a title. Proof the shell got far enough to run something.
    private var aliveSignals: Set<UUID> = []
    /// Whether a row's failure to speak within twelve seconds means anything. A plain shell
    /// where the user typed nothing looks identical to a hung one; an agent row that hasn't
    /// reached its own start hook by then has not started.
    private var expectsPrompt: [UUID: Bool] = [:]

    func view(for session: Session, cwd: URL, agentFlags: String = "") -> Fallible<GhosttySurfaceView> {
        if let existing = views[session.id] { return .success(existing) }

        GhosttyApp.shared.bus = bus
        // If the engine is down this kicks off a heal and returns; the pane shows its refusal
        // and the Retry that follows a successful heal simply works. Nothing here waits.
        Capabilities.ensure(GhosttyApp.shared)
        guard GhosttyApp.shared.isReady else {
            return .failure(Fault.Record(
                domain: .terminalEngine, code: .engineUnavailable, severity: .failed,
                session: session.id, details: [.sessionKind(session.kind), .stage(.spawn)],
                evidence: "The terminal engine isn't running.",
                copy: .init(title: "This terminal couldn't start", retry: .restartSynth),
                site: "TerminalManager.swift"))
        }
        guard let command = TerminalLauncher.command().mapError({ r in
            Fault.Record(domain: r.domain, code: r.code, severity: r.severity,
                         session: session.id, details: r.details, evidence: r.evidence,
                         copy: r.copy, site: r.site)
        }).reported() else {
            return .failure(Fault.Record(
                domain: .terminalSpawn, code: .launcherScriptUnwritable, severity: .failed,
                session: session.id, details: [.sessionKind(session.kind), .stage(.write)],
                evidence: "Synth couldn't write the shell it launches terminals through.",
                copy: .init(title: "This terminal couldn't start", retry: .respawnSession(session.id)),
                site: "TerminalManager.swift"))
        }

        var base = ProcessInfo.processInfo.environment
        // libghostty sets its own TERM to match `term` in the inline config.
        base.removeValue(forKey: "TERM")
        // decorate() lets every installed agent's supervisor stamp its env — including the port
        // opencode's server will listen on. Supervisors are attached by the agent-start signal
        // (Hooks), never here: a launched agent is not yet a reachable one.
        let env = HookEnvironment.decorate(base, sessionID: session.id, socketPath: hookSocketPath,
                                           cwd: cwd.path)

        let view = GhosttySurfaceView(session: session, cwd: cwd, env: env,
                                      command: command, agentFlags: agentFlags, bus: bus)
        views[session.id] = view
        arm(session)
        return .success(view)
    }

    // MARK: The watchdog

    /// Two checks, armed the moment a terminal is asked for and disarmed by any evidence of
    /// life. It fires on *absence*, which is what makes it cause-independent: a missing
    /// wrapper script, an unexecutable `$SHELL`, a Bun killed by the hardened runtime, an rc
    /// file that exits, a `login` refused by policy, a jetsam kill and an engine that never
    /// came up all land here with the same signal — none of them delivers an error anyone
    /// could have caught. It is the one detector that would have caught the report that
    /// prompted all of this without anyone knowing the cause.
    private func arm(_ session: Session) {
        intentAt[session.id] = Date()
        expectsPrompt[session.id] = session.spawnedKind.isAgent || session.kind == .markdown
        let id = session.id
        let kind = session.spawnedKind
        watchdogs[id] = [
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.checkDeath(id, kind: kind)
            },
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                self?.checkSilence(id, kind: kind)
            },
        ]
    }

    /// Two seconds in, is the child already gone? `ghostty_surface_process_exited` is a direct
    /// answer that owes nothing to `login`'s zeroed status, to the hook socket, or to an exit
    /// event being delivered at all.
    private func checkDeath(_ id: UUID, kind: SessionKind) {
        guard let view = views[id], claimed.insert(id).inserted else { return }
        // A surface that failed outright has already said so, at the point of failure.
        guard view.startFailure == nil else { return }
        // On screen with no surface: nothing was ever spawned, so no exit event is coming.
        // This is the pane that just sits there, and it is invisible to every other detector
        // in the app precisely because nothing happened.
        if view.isBlank {
            Fault.surface(.terminalSpawn, .engineUnavailable, session: id,
                          say: .init(title: "This terminal never started",
                                     retry: .respawnSession(id)),
                          details: [.sessionKind(kind), .stage(.spawn)],
                          evidence: "Nothing was running behind the pane.")
            bus?.post(.spawnFailed(id, .engineUnavailable))
            return
        }
        guard view.childHasExited == true else {
            claimed.remove(id)   // alive — leave the exit path free to speak for it later
            return
        }
        let ms = lifetimeMS(id) ?? 0
        Analytics.capture("terminal_exited", ["classified": "instant_death", "detector": "watchdog",
                                              "ms_alive": ms, "code_source": "none",
                                              "session_kind": kind.analyticsSlug])
        Fault.surface(.terminalExit, .instantDeath, session: id,
                      say: .init(title: "This terminal closed the moment it opened",
                                 retry: .respawnSession(id)),
                      details: [.msAlive(ms), .sessionKind(kind), .codeSource(.none)],
                      evidence: "It ended before the shell could report why.")
    }

    /// Twelve seconds in, a row that should have said something hasn't. This is the only
    /// detector here that sees a hang — an rc file blocking on `read`, a wedged working
    /// directory, an agent stuck behind a trust prompt — none of which ever exits.
    private func checkSilence(_ id: UUID, kind: SessionKind) {
        guard expectsPrompt[id] == true, !claimed.contains(id), !aliveSignals.contains(id),
              let view = views[id], view.startFailure == nil, view.childHasExited == false
        else { return }
        Fault.report(.terminalSpawn, .noPrompt, severity: .degraded, session: id,
                     details: [.msAlive(lifetimeMS(id) ?? 0), .sessionKind(kind), .stage(.ready)],
                     evidence: "Started, but nothing has run in it.")
    }

    /// Any derived fact about a session is proof its shell got somewhere.
    func noteAlive(_ id: UUID) { aliveSignals.insert(id) }

    /// How long this terminal has been up, in milliseconds — nil once it has been reaped.
    func lifetimeMS(_ id: UUID) -> Int? {
        intentAt[id].map { Int(Date().timeIntervalSince($0) * 1000) }
    }

    /// True the first time anyone speaks for this session's death — so the watchdog and the
    /// exit event, which race by design, cannot both raise a card for the same terminal.
    func claimDeath(_ id: UUID) -> Bool { claimed.insert(id).inserted }

    func disarm(_ id: UUID) {
        watchdogs.removeValue(forKey: id)?.forEach { $0.cancel() }
        intentAt[id] = nil
        expectsPrompt[id] = nil
        aliveSignals.remove(id)
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
        disarm(id)
        claimed.remove(id)
        views[id]?.close()
        views[id] = nil
    }

    /// Tear down every live terminal on app quit — free each surface and reap its PTY
    /// process tree (login → shell → agent → MCP servers). App quit doesn't route through
    /// closeSession/removeBranch, and nothing else frees these, so without this every open
    /// session's whole process tree is orphaned to launchd when Synth exits. Mirror of
    /// BrowserManager.shutdownAll; both are driven off the willTerminate observer.
    func shutdownAll() {
        for id in views.keys { disarm(id) }
        for view in views.values { view.close() }
        views.removeAll()
        claimed.removeAll()
    }
}
