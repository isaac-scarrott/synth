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

    /// `synth-hook` sits next to the app executable (SPM builds both into the same dir).
    static let hookBin: String? = {
        guard let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = exeDir.appendingPathComponent("synth-hook").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    /// The real `claude`, resolved once on the original PATH (before our shim is prepended).
    static let realClaude: String? = {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            let candidate = dir + "/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }()

    static var available: Bool { hookBin != nil && realClaude != nil }

    /// Create the shim dir and (re)point its `claude` symlink at `synth-hook`. When Claude
    /// execs `claude`, the shim runs `synth-hook` in its launch role.
    static func setup() {
        guard let hookBin else { return }
        try? FileManager.default.createDirectory(atPath: shimDir, withIntermediateDirectories: true)
        let link = shimDir + "/claude"
        try? FileManager.default.removeItem(atPath: link)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: hookBin)
    }

    /// Overlay the hook correlation/callback env + shim PATH onto a base environment.
    static func decorate(_ base: [String: String], sessionID: UUID, socketPath: String) -> [String: String] {
        guard available, let hookBin, let realClaude else { return base }
        var env = base
        env["PATH"] = shimDir + ":" + (base["PATH"] ?? "/usr/bin:/bin")
        env["SYNTH_SHIM_DIR"] = shimDir
        env["SYNTH_SESSION_ID"] = sessionID.uuidString
        env["SYNTH_SOCKET_PATH"] = socketPath
        env["SYNTH_HOOK_BIN"] = hookBin
        env["SYNTH_REAL_CLAUDE"] = realClaude
        return env
    }
}
