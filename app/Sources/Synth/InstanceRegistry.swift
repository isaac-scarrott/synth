import AppKit
import Foundation

/// Stage-two discovery (ADR-0011): every running Synth advertises itself as
/// ~/Library/Application Support/Synth/instances/<pid>.json —
/// { pid, cdpPort, createdAt, worktreePaths, controlSocket } — so the bundled MCP
/// server can find the instance managing $CLAUDE_PROJECT_DIR. Written at launch
/// (cdpPort 0 until the CEF runtime binds one: the port exists only once the first
/// browser engine spins up, but list/create must work before that), refreshed as
/// workspaces/branches change, removed on clean quit, and dead-pid leftovers are
/// swept at launch (the BrowserProcessSupervisor.sweepDeadInstances pattern).
@MainActor final class InstanceRegistry {
    static let shared = InstanceRegistry()

    /// The control socket's path is derived from the pid (ControlServer binds it);
    /// recorded in the JSON so clients never hardcode the convention.
    static let controlSocketPath = "/tmp/synth-ctl-\(getpid()).sock"

    private static let dir = AppSupport.dir("instances")

    private let createdAt = ISO8601DateFormatter().string(from: Date())
    private var cdpPort: UInt16 = 0
    private var worktreePaths: [String] = []
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        sweepDeadInstances()
        write()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { InstanceRegistry.shared.removeFile() }
            // The control socket file outlives close(fd); a clean quit shouldn't
            // litter /tmp (the next bind unlinks its own path, but stale socks confuse
            // humans and sweeps).
            unlink(Self.controlSocketPath)
        }
    }

    /// Every branch worktree this instance manages, canonicalized so the MCP server's
    /// realpath($CLAUDE_PROJECT_DIR) comparison holds. Skips the rewrite when unchanged
    /// (called on the autosave cadence).
    func update(worktreePaths raw: [String]) {
        let canonical = raw.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }
        guard canonical != worktreePaths else { return }
        worktreePaths = canonical
        write()
    }

    /// The CEF runtime bound its per-instance CDP port (BrowserProcessSupervisor).
    func setCDPPort(_ port: UInt16) {
        guard port != cdpPort else { return }
        cdpPort = port
        write()
    }

    private var fileURL: URL {
        Self.dir.appendingPathComponent("\(getpid()).json")
    }

    private func write() {
        // `started` gates check-mode (`--browser-check` inits CEF without the app
        // lifecycle) from registering an instance it will never clean up.
        guard started else { return }
        let payload: [String: Any] = [
            "pid": Int(getpid()),
            "cdpPort": Int(cdpPort),
            "createdAt": createdAt,
            "worktreePaths": worktreePaths,
            "controlSocket": Self.controlSocketPath,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func removeFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Instance files whose owning pid is gone — crashed / SIGKILLed instances
    /// never removed their advertisement.
    private func sweepDeadInstances() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.pathExtension == "json" {
            guard let pid = Int32(entry.deletingPathExtension().lastPathComponent),
                  pid != getpid() else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
