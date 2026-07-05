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
            if let claude = obj["claudeSession"] as? String, !claude.isEmpty {
                Task { @MainActor in bus?.post(.claudeSessionCaptured(id, claude)) }
            }
        }
    }

    /// Map a signal to bus events. Status maps 1:1 onto `SessionStatus`; the terracotta
    /// Claude visual is switched on/off by flipping the session's kind on start/end.
    @MainActor static func apply(signal: String, session id: UUID, bus: EventBus?) {
        guard let bus else { return }
        switch signal {
        case "working":    bus.post(.statusChanged(id, .working))
        case "needsInput": bus.post(.statusChanged(id, .needsInput))
        case "error":      bus.post(.statusChanged(id, .error))
        case "idle":       bus.post(.statusChanged(id, .idle)); bus.post(.markUnread(id))
        case "claude-start": bus.post(.kindChanged(id, .claudeCode)); bus.post(.statusChanged(id, .idle))
        case "claude-end":   bus.post(.kindChanged(id, .terminal));   bus.post(.statusChanged(id, .idle))
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

/// Resolves the paths and environment that let a spawned terminal report Claude Code
/// status back to Synth: a shim dir with a `claude` symlink placed first on PATH, plus the
/// correlation/callback env. Detection is a no-op (returns the base env unchanged) when
/// either `synth-hook` or a real `claude` can't be found — the terminal just runs normally.
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

    /// The real `claude`, resolved once on the original PATH (before our shim is prepended).
    /// Skips any `claude` that resolves to a `synth-hook` shim — when Synth is launched from
    /// inside another Synth session its PATH already carries a `synth-shims-*` dir, and
    /// handing that shim to a spawned terminal as SYNTH_REAL_CLAUDE makes synth-hook exec
    /// itself in a loop until the argv blows past ARG_MAX (E2BIG, "Argument list too long").
    static let realClaude: String? = {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            let candidate = dir + "/claude"
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)) ?? candidate
            if (resolved as NSString).lastPathComponent == "synth-hook" { continue }
            return candidate
        }
        return nil
    }()

    static var available: Bool { hookBin != nil && realClaude != nil }

    /// Create the shim dir and (re)point its `claude` symlink at `synth-hook`. When Claude
    /// execs `claude`, the shim runs `synth-hook` in its launch role.
    static func setup() {
        guard let hookBin else { return }
        reapStale()
        try? FileManager.default.createDirectory(atPath: shimDir, withIntermediateDirectories: true)
        let link = shimDir + "/claude"
        try? FileManager.default.removeItem(atPath: link)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: hookBin)
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
            # thing it's running. `claude` is left entirely to Claude's own pipeline.
            _synth_preexec() {
                [[ "${1%% *}" == claude ]] && return
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
        fi
        """
        try? zshenv.write(toFile: zdotDir + "/.zshenv", atomically: true, encoding: .utf8)
        try? "_synth_source_user .zprofile\n".write(toFile: zdotDir + "/.zprofile", atomically: true, encoding: .utf8)
        try? "_synth_source_user .zlogin\n".write(toFile: zdotDir + "/.zlogin", atomically: true, encoding: .utf8)
        try? ("_synth_source_user .zshrc\n" + reporter).write(toFile: zdotDir + "/.zshrc", atomically: true, encoding: .utf8)
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

    /// Overlay the hook correlation/callback env + shim PATH onto a base environment.
    static func decorate(_ base: [String: String], sessionID: UUID, socketPath: String) -> [String: String] {
        var env = base
        // Synth itself may have been launched from inside a Claude Code session (dev.sh in a
        // claude turn), and these markers make Claude treat every claude spawned here as a
        // nested "child session": no transcript on disk, no ai-title, so row auto-naming
        // starves — and CLAUDECODE-aware tools misbehave in plain shells. Sessions inside
        // Synth are top-level, so drop the inherited markers.
        for key in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID",
                    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SSE_PORT"] {
            env.removeValue(forKey: key)
        }
        // Terminal per-command reporting needs only synth-hook + the socket + the injected
        // ZDOTDIR — not a real `claude` — so wire it up whenever the helper exists, so a plain
        // shell lights up even on a machine without Claude Code installed.
        if let hookBin {
            env["SYNTH_SESSION_ID"] = sessionID.uuidString
            env["SYNTH_SOCKET_PATH"] = socketPath
            env["SYNTH_HOOK_BIN"] = hookBin
            env["SYNTH_USER_ZDOTDIR"] = base["ZDOTDIR"] ?? ""
            env["ZDOTDIR"] = zdotDir
        }
        // Claude interception additionally needs a real `claude` to exec and the shim PATH
        // that routes `claude` through synth-hook's launch role.
        guard available, let realClaude else { return env }
        env["PATH"] = shimDir + ":" + (base["PATH"] ?? "/usr/bin:/bin")
        env["SYNTH_SHIM_DIR"] = shimDir
        env["SYNTH_REAL_CLAUDE"] = realClaude
        return env
    }
}
