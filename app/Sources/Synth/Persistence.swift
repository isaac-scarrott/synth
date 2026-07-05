import Foundation

/// Plain Codable snapshot of the durable tree (ADR-0010). Kept deliberately separate from
/// the @Observable runtime models so the on-disk format is explicit and runtime-only facts —
/// live status, unread, keyboard selection, the terminal process itself — never reach disk.
/// Restore is reconstruction: respawn a shell in the worktree, and for a Claude row resume
/// its conversation with `claude --resume`. No live process survives a restart (see cmux,
/// which converges on the same model).
struct PersistedState: Codable {
    var version: Int
    var workspaces: [PersistedWorkspace]
    /// Ids of expanded rows (workspaces/branches), so the tree reopens as the user left it.
    var expanded: [UUID]
    /// Settings (ADR-0010): the global setup script + Claude flags. Optional so a snapshot
    /// written before settings were persisted still decodes — a nil just keeps the default.
    var globalScript: String?
    var globalClaudeFlags: String?
}

struct PersistedWorkspace: Codable {
    var id: UUID
    var name: String
    var url: URL
    var colorIndex: Int
    var branches: [PersistedBranch]
    /// Per-workspace settings, carried with the workspace so they drop when it's removed.
    /// Optional/omitted when the workspace has no custom value (see PersistedState).
    var setupScript: String?
    var claudeFlags: String?
}

struct PersistedBranch: Codable {
    var id: UUID
    var name: String
    var worktreeURL: URL
    var lastActivity: String
    var sessions: [PersistedSession]
    /// The branch's browser "Recent" list (≤5). Optional/omitted when empty so pre-browser
    /// snapshots decode and an untouched branch adds no keys.
    var browserRecents: [BrowserRecent]?
}

struct PersistedSession: Codable {
    var id: UUID
    var kind: String            // SessionKind.rawValue
    var title: String
    var titleIsCustom: Bool
    var claudeSessionID: String?
    /// A browser session's current page — a restored row reopens it in a fresh engine
    /// (ADR-0011; same reconstruction model as `claude --resume`).
    var browserURL: URL?
}

/// Reads and writes the state snapshot under Application Support. Atomic writes with a
/// primary + `-previous` backup and a version gate, so a truncated or format-shifted file
/// can't wedge launch — a bad primary falls back to the backup, a bad backup to a clean start.
enum PersistenceStore {
    static let schemaVersion = 1

    static var fileURL: URL {
        // Harness isolation (like SYNTH_AUTOMATION): a driven test instance must never share
        // state with the user's live one — Application Support resolves the real user home
        // regardless of $HOME, and concurrent instances are last-writer-wins (ADR-0010).
        if let dir = ProcessInfo.processInfo.environment["SYNTH_STATE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("state.json")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Synth", isDirectory: true)
                      .appendingPathComponent("state.json")
    }
    static var backupURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("state-previous.json")
    }

    /// The most recent readable, version-matching snapshot (primary, else backup), or nil.
    static func load() -> PersistedState? {
        for url in [fileURL, backupURL] {
            guard let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(PersistedState.self, from: data),
                  state.version == schemaVersion
            else { continue }
            return state
        }
        return nil
    }

    /// Write `state`, rotating the current file to `-previous` first. Returns the encoded
    /// bytes so the caller can skip an unchanged rewrite (the encoder sorts keys, so equal
    /// trees encode to equal bytes). Returns `lastBytes` unchanged on an encode failure or
    /// when nothing changed — nothing is written in those cases.
    @discardableResult
    static func save(_ state: PersistedState, lastBytes: Data?) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return lastBytes }
        if let lastBytes, lastBytes == data { return lastBytes }

        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let existing = try? Data(contentsOf: fileURL) {
            try? existing.write(to: backupURL, options: .atomic)
        }
        try? data.write(to: fileURL, options: .atomic)
        return data
    }
}
