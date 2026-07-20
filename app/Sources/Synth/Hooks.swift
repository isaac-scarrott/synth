import Foundation

/// Listens on a unix socket for status signals from `synth-hook` (fired by Claude Code
/// hooks inside a session's terminal) and turns each into a `SessionEvent` on the bus —
/// the same low-frequency seam every other derived fact flows through (docs/adr/0001).
///
/// Wire format: one JSON line per signal, `{"session":"<uuid>","signal":"working"}`.
/// The session id is the row's `Session.id`, injected as `$SYNTH_SESSION_ID` at PTY spawn,
/// so a signal maps to exactly one row even when several terminals share a worktree.
final class HookServer: @unchecked Sendable {
    let socketPath = "/tmp/synth-hook-\(getpid()).sock"
    private weak var bus: EventBus?
    private var listenFD: Int32 = -1

    @MainActor init(bus: EventBus) {
        self.bus = bus
    }

    func start() {
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: cap) {
                    strncpy($0, src, cap - 1)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0, listen(listenFD, 16) == 0 else { close(listenFD); listenFD = -1; return }
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { if errno == EINTR { continue }; break }
            Thread.detachNewThread { [weak self] in self?.handle(conn) }
        }
    }

    /// A hook connects, writes its line(s), and closes — read to EOF, then dispatch.
    private func handle(_ conn: Int32) {
        defer { close(conn) }
        var acc = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(conn, &buf, buf.count)
            if n <= 0 { break }
            acc.append(contentsOf: buf[0..<n])
        }
        for line in acc.split(separator: 0x0A) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let sid = obj["session"] as? String, let id = UUID(uuidString: sid) else { continue }
            let bus = self.bus
            if let signal = obj["signal"] as? String {
                Task { @MainActor in HookServer.apply(signal: signal, session: id, bus: bus) }
            }
            if let title = obj["title"] as? String {
                Task { @MainActor in bus?.post(.titleChanged(id, title)) }
            }
            if obj["titleReset"] != nil {
                Task { @MainActor in bus?.post(.titleReset(id)) }
            }
            if let agentSession = obj["agentSession"] as? String, !agentSession.isEmpty {
                Task { @MainActor in bus?.post(.agentSessionCaptured(id, agentSession)) }
            }
            // The session's true exit status (zshexit / the claude shim), sent moments
            // before the process dies — the PTY's own code arrives later as 0 (login).
            if let codeStr = obj["exitCode"] as? String, let code = Int32(codeStr) {
                Task { @MainActor in bus?.post(.exitCodeReported(id, code)) }
            }
        }
    }

    /// Map a signal to bus events. Status maps 1:1 onto `SessionStatus`; an agent's visual is
    /// switched on/off by flipping the session's kind on start/end.
    ///
    /// `agent-start:<id>` / `agent-end:<id>` name which agent attached, so a terminal that runs
    /// `opencode` becomes an opencode row and one that runs `claude` a Claude Code row.
    @MainActor static func apply(signal: String, session id: UUID, bus: EventBus?) {
        guard let bus else { return }
        if let agent = signal.strippingPrefix("agent-start:") {
            bus.post(.kindChanged(id, .agent(AgentID(agent))))
            bus.post(.statusChanged(id, .idle))
            return
        }
        if signal.hasPrefix("agent-end:") {
            bus.post(.kindChanged(id, .terminal))
            bus.post(.statusChanged(id, .idle))
            return
        }
        switch signal {
        case "working":    bus.post(.statusChanged(id, .working))
        case "needsInput": bus.post(.statusChanged(id, .needsInput))
        case "error":      bus.post(.statusChanged(id, .error))
        case "idle":       bus.post(.statusChanged(id, .idle)); bus.post(.markUnread(id))
        // A plain terminal's per-command lifecycle, from the injected zsh hooks (synth-hook
        // report). `term-run` greens the row while a foreground process runs; on finish a
        // long or failed command marks unread — a clean/interrupted quick one stays quiet.
        case "term-run":   bus.post(.statusChanged(id, .running))
        case "term-idle":  bus.post(.statusChanged(id, .idle));  bus.post(.markUnread(id))
        case "term-error": bus.post(.statusChanged(id, .error)); bus.post(.markUnread(id))
        default: break
        }
    }
}

/// Resolves the paths and environment that let a spawned terminal report a coding agent's
/// status back to Synth: a shim dir carrying one symlink per installed agent binary, placed
/// first on PATH, plus the correlation/callback env. Detection degrades to a no-op (the base
/// env unchanged) when `synth-hook` or every agent binary is missing — the terminal just runs.
@MainActor enum HookEnvironment {
    static let shimDir = "/tmp/synth-shims-\(getpid())"

    /// A synth-managed `$ZDOTDIR` whose startup files re-source the user's own zsh config
    /// (the VSCode/iTerm injection technique) then append a per-command status reporter — so
    /// a plain terminal reports its foreground-process lifecycle over the same hook socket
    /// Claude uses. Injected via `$ZDOTDIR` (survives TerminalLauncher's ghostty-only scrub);
    /// non-zsh shells ignore it and just run normally.
    static let zdotDir = "/tmp/synth-zdotdir-\(getpid())"

    /// `synth-hook` sits next to the app executable (SPM builds both into the same dir).
    static let hookBin: String? = {
        guard let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = exeDir.appendingPathComponent("synth-hook").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    static var available: Bool { hookBin != nil && !AgentRegistry.installed.isEmpty }

    /// Session markers a parent agent leaves in our environment when Synth is launched from
    /// inside one. A spawned agent must not see them: `CLAUDE_CODE_CHILD_SESSION` makes Claude
    /// treat the session as a subagent — no transcript on disk (unresumable), no history — and
    /// `CLAUDECODE`/`OPENCODE`-aware tools misbehave in plain shells. opencode has no
    /// child-session contract (its subagents are in-process), so the whole prefix is the safe
    /// superset rather than a known-bad list.
    static let inheritedAgentMarkers = ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION",
                                        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
                                        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SSE_PORT",
                                        "OPENCODE", "AGENT", "OPENCODE_SESSION_ID",
                                        "OPENCODE_SESSION_TITLE", "OPENCODE_CONFIG_CONTENT",
                                        "OPENCODE_PERMISSION", "OPENCODE_SERVER_USERNAME",
                                        "OPENCODE_SERVER_PASSWORD"]

    /// Create the shim dir and (re)point one symlink per installed agent at `synth-hook`. When
    /// a terminal runs `claude` or `opencode`, the shim runs `synth-hook` in its launch role.
    static func setup() {
        // Scrub at the process level, not just in decorate()'s overlay: libghostty merges
        // surface env_vars ON TOP of the app's inherited environ, so a key merely absent
        // from the overlay still reaches the PTY child. unsetenv is the only real removal.
        for key in inheritedAgentMarkers { unsetenv(key) }
        guard let hookBin else { return }
        reapStale()
        try? FileManager.default.createDirectory(atPath: shimDir, withIntermediateDirectories: true)
        for agent in AgentRegistry.installed {
            let link = shimDir + "/" + agent.binaryName
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: hookBin)
        }
        writeZDotDir()
    }

    /// Populate the injected `$ZDOTDIR`. zsh (macOS default) reads its startup files from here
    /// instead of the user's dir, so each stage file re-sources the user's real one before
    /// handing control back (`_synth_source_user`), and `.zshrc` additionally installs the
    /// preexec/precmd reporter. The `claude` command is skipped — Claude Code drives its own
    /// richer status through the hook pipeline and mustn't fight the coarse per-command dot.
    private static func writeZDotDir() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: zdotDir, withIntermediateDirectories: true)
        // Temporarily restore the real ZDOTDIR, source the user's file, then re-point ZDOTDIR
        // here so the next startup stage is read from here too (re-capturing USER_ZDOTDIR in
        // case the user's config changed it). Defined in .zshenv (always read first).
        let zshenv = """
        _synth_source_user() {
            local f="${SYNTH_USER_ZDOTDIR:-$HOME}/$1"
            [ -r "$f" ] || return 0
            local save="$ZDOTDIR"
            ZDOTDIR="${SYNTH_USER_ZDOTDIR:-$HOME}"
            source "$f"
            SYNTH_USER_ZDOTDIR="$ZDOTDIR"
            ZDOTDIR="$save"
        }
        _synth_source_user .zshenv
        """
        let reporter = """

        # --- Synth per-command status reporting ---------------------------------------------
        # Green while a foreground process runs; unread/red when a long or failing command
        # ends. No-ops unless Synth injected the correlation env, so a shell run outside Synth
        # (or without synth-hook) behaves normally. Runs on every prompt — kept to a few ms.
        if [[ -n "$SYNTH_SESSION_ID" && -n "$SYNTH_SOCKET_PATH" && -x "$SYNTH_HOOK_BIN" ]]; then
            zmodload zsh/datetime 2>/dev/null
            autoload -Uz add-zsh-hook 2>/dev/null
            _synth_report() {
                if [[ -n "$2" ]]; then
                    "$SYNTH_HOOK_BIN" report --signal "$1" --title "$2" &!
                else
                    "$SYNTH_HOOK_BIN" report --signal "$1" &!
                fi
            }
            # A background timer paints the row green only once a command outlasts ~0.5s, so
            # trivial commands (ls, cd, git status) finish first, are killed, and never strobe
            # the sidebar. The command line rides along so the row auto-names itself after the
            # thing it's running. An agent binary is left entirely to its own supervisor, whose
            # status is richer and mustn't fight the coarse per-command dot.
            _synth_preexec() {
                local cmd="${1#exec }"          # an agent is launched as `exec claude …`
                local word="${cmd%% *}"
                [[ " $SYNTH_AGENT_BINS " == *" $word "* ]] && return
                [[ -n "$_synth_run_timer" ]] && kill "$_synth_run_timer" 2>/dev/null
                _synth_cmd_start=$EPOCHREALTIME
                ( sleep 0.5; _synth_report term-run "$1" ) &!
                _synth_run_timer=$!
            }
            # Cancel a still-pending green, then classify the finished command. Exit 0 and the
            # user-interrupt signals (130 SIGINT, 143 SIGTERM) are neutral — a dev server the
            # user Ctrl-C's mustn't flash red; any other non-zero is an error. Only a command
            # that actually ran past the timer gate (or failed) clears/marks the row.
            _synth_precmd() {
                local ec=$?
                [[ -n "$_synth_run_timer" ]] && kill "$_synth_run_timer" 2>/dev/null
                _synth_run_timer=""
                [[ -z "$_synth_cmd_start" ]] && return
                local elapsed=$(( EPOCHREALTIME - _synth_cmd_start ))
                _synth_cmd_start=""
                if (( ec == 0 || ec == 130 || ec == 143 )); then
                    (( elapsed >= 0.5 )) && _synth_report term-idle
                else
                    _synth_report term-error
                fi
            }
            add-zsh-hook preexec _synth_preexec
            add-zsh-hook precmd _synth_precmd
            # The shell's exit status can't ride the PTY: libghostty wraps the child in
            # macOS `login`, which exits 0 whatever the shell exited with — so hand the
            # true code to the app over the socket. Foreground, not &!: the shell is
            # about to die.
            _synth_zshexit() { "$SYNTH_HOOK_BIN" report --exit $? }
            add-zsh-hook zshexit _synth_zshexit
        fi
        """
        try? zshenv.write(toFile: zdotDir + "/.zshenv", atomically: true, encoding: .utf8)
        try? "_synth_source_user .zprofile\n".write(toFile: zdotDir + "/.zprofile", atomically: true, encoding: .utf8)
        try? "_synth_source_user .zlogin\n".write(toFile: zdotDir + "/.zlogin", atomically: true, encoding: .utf8)
        // macOS's /etc/zshrc sets HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history, which under the
        // injected ZDOTDIR siphons history into this temp dir: ctrl+r starts empty and the
        // session's history is reaped with the dir. Re-point it at the user's real dir before
        // their .zshrc runs, so an explicit HISTFILE of their own still wins.
        let histfix = "[[ \"$HISTFILE\" == \"$ZDOTDIR\"/* ]] && HISTFILE=\"${SYNTH_USER_ZDOTDIR:-$HOME}/.zsh_history\"\n"
        // decorate() puts the shim first on PATH, but /etc/zprofile's path_helper and the
        // user's own .zshrc rebuild PATH and bury it — `claude` then resolves to the real
        // binary and sessions run without hooks (no --settings, no status signals, no
        // session id). Re-prepend after the user's config has had its say.
        let shimfix = "[[ -n \"$SYNTH_SHIM_DIR\" && -d \"$SYNTH_SHIM_DIR\" ]] && PATH=\"$SYNTH_SHIM_DIR:$PATH\"\n"
        try? (histfix + "_synth_source_user .zshrc\n" + shimfix + reporter).write(toFile: zdotDir + "/.zshrc", atomically: true, encoding: .utf8)
    }

    /// Remove `/tmp` leftovers — shim dirs, hook sockets, login scripts — keyed on a pid
    /// that is no longer alive. Each Synth process names these `synth-*-<pid>`; a crash or
    /// `SIGKILL` skips cleanup, so without this they pile up and stale shim dirs pollute the
    /// PATH of any Synth launched from inside another Synth session.
    private static func reapStale() {
        let fm = FileManager.default
        // Shim dirs + hook sockets are hardcoded under /tmp; login scripts under the
        // per-user temp dir — sweep both.
        for dir in Set(["/tmp/", NSTemporaryDirectory()]) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries {
                let pid: String?
                if name.hasPrefix("synth-shims-")        { pid = String(name.dropFirst("synth-shims-".count)) }
                else if name.hasPrefix("synth-zdotdir-") { pid = String(name.dropFirst("synth-zdotdir-".count)) }
                else if name.hasPrefix("synth-hook-"), name.hasSuffix(".sock") {
                    pid = String(name.dropFirst("synth-hook-".count).dropLast(".sock".count))
                } else if name.hasPrefix("synth-ctl-"), name.hasSuffix(".sock") {
                    pid = String(name.dropFirst("synth-ctl-".count).dropLast(".sock".count))
                } else if name.hasPrefix("synth-login-"), name.hasSuffix(".sh") {
                    pid = String(name.dropFirst("synth-login-".count).dropLast(".sh".count))
                } else { pid = nil }
                guard let pid, let n = Int32(pid), n != getpid(), !isAlive(n) else { continue }
                try? fm.removeItem(atPath: dir + name)
            }
        }
    }

    /// True when a process with `pid` still exists (`kill(pid, 0)`): 0 → alive, or EPERM
    /// (alive, not ours to signal). ESRCH means it's gone and its leftovers are reapable.
    private static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// A synth-injected `$ZDOTDIR` from ANY instance (this one or an ancestor's), never the
    /// user's own — these are per-pid temp dirs that die with their instance.
    private static func isInjectedZDotDir(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("synth-zdotdir-")
    }

    /// Overlay the hook correlation/callback env + shim PATH onto a base environment.
    static func decorate(_ base: [String: String], sessionID: UUID, socketPath: String) -> [String: String] {
        var env = base
        // Sessions inside Synth are top-level, never child sessions — drop inherited agent
        // markers from the overlay too (setup()'s unsetenv is the real removal; this guards
        // callers that pass a base env other than our own environ).
        for key in inheritedAgentMarkers { env.removeValue(forKey: key) }
        // A session Synth opens on the user's behalf — a handoff, a browser comment — has nobody
        // at the keyboard when the shell starts, so a startup file that stops to ask a question
        // strands it: the launch line waits behind a prompt the user never sees, and the seed
        // times out undelivered. oh-my-zsh's periodic update prompt is the one that reaches
        // nearly every mac; its own switch turns it off, for Synth's shells only (`omz update`
        // still works, and the user's terminals elsewhere are untouched).
        env["DISABLE_AUTO_UPDATE"] = "true"
        // Terminal per-command reporting needs only synth-hook + the socket + the injected
        // ZDOTDIR — not a real `claude` — so wire it up whenever the helper exists, so a plain
        // shell lights up even on a machine without Claude Code installed.
        if let hookBin {
            env["SYNTH_SESSION_ID"] = sessionID.uuidString
            env["SYNTH_SOCKET_PATH"] = socketPath
            env["SYNTH_HOOK_BIN"] = hookBin
            // The per-command reporter skips these words — each has its own supervisor.
            env["SYNTH_AGENT_BINS"] = AgentRegistry.installed.map(\.binaryName).joined(separator: " ")
            // Synth may itself be running inside another Synth's session (dev.sh in a claude
            // turn), so the inherited ZDOTDIR can be the *outer* instance's injected dir —
            // recording that as the user's would chase a dir that vanishes when the outer
            // instance dies (reapStale), silently skipping ~/.zshrc: a bare default zsh that
            // reads as "my config is gone". The outer instance already captured the real dir
            // in SYNTH_USER_ZDOTDIR, so take the first inherited value that isn't injected.
            env["SYNTH_USER_ZDOTDIR"] = [base["ZDOTDIR"], base["SYNTH_USER_ZDOTDIR"]]
                .compactMap { $0 }
                .first { !$0.isEmpty && !isInjectedZDotDir($0) } ?? ""
            env["ZDOTDIR"] = zdotDir
        }
        // Agent interception additionally needs the shim PATH that routes each agent's binary
        // through synth-hook's launch role, plus whatever that agent needs to report back —
        // the real binary to exec, and for opencode the port/credentials of the server its TUI
        // will serve. Every terminal gets this: any terminal may become any agent.
        guard available else { return env }
        env["PATH"] = shimDir + ":" + (base["PATH"] ?? "/usr/bin:/bin")
        env["SYNTH_SHIM_DIR"] = shimDir
        for agent in AgentRegistry.installed {
            AgentRegistry.supervisor(agent.id)?.decorate(&env, sessionID: sessionID)
        }
        return env
    }
}

extension String {
    /// The remainder after `prefix`, or nil when it doesn't match.
    func strippingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
