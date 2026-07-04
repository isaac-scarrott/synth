import Foundation
import Observation

/// The kind of live thing running inside a branch. working.html's focused subset
/// has exactly these two (browser/simulator are big-picture only).
enum SessionKind: String, Sendable {
    case terminal
    case claudeCode
}

/// A session's derived status fact — the only session-level thing that reaches the
/// global store (see docs/adr/0001). A terminal is idle at a prompt and exited/error
/// when its process ends; running is reserved for one actively running a process.
enum SessionStatus: Equatable, Sendable {
    case running          // a live process — drives the green liveness dot
    case idle             // alive but nothing happening
    case exited(Int32?)   // process ended
    case error            // process failed
    case needsInput       // reserved for Claude Code (?)
    case working          // reserved for Claude Code (amber)

    var isLive: Bool {
        switch self {
        case .running, .working, .needsInput: return true
        case .idle, .exited, .error: return false
        }
    }
}

@Observable final class Session: Identifiable {
    /// Stable across restarts: restored from disk (ADR-0010) so persisted expansion and
    /// selection, which key off this id, keep pointing at the same row.
    let id: UUID
    /// Mutable: a terminal that runs `claude` is detected and upgraded to `.claudeCode`
    /// (and reverts when it exits) — the kind reflects what's running, not a creation label.
    var kind: SessionKind
    var title: String
    var status: SessionStatus
    var unread: Bool
    /// Set once the user renames the session by hand. Freezes the title so Claude Code's
    /// evolving ai-title (arriving as `.titleChanged`) stops overwriting a chosen name.
    var titleIsCustom: Bool
    /// Claude Code's own session id — minted by our launch shim, reported back over the hook
    /// socket (Hooks/synth-hook). A restored Claude row uses it to resume the conversation
    /// with `claude --resume <id>`. nil for terminals and not-yet-started Claude sessions.
    var claudeSessionID: String?

    init(id: UUID = UUID(), kind: SessionKind, title: String, status: SessionStatus = .idle, unread: Bool = false, titleIsCustom: Bool = false, claudeSessionID: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.unread = unread
        self.titleIsCustom = titleIsCustom
        self.claudeSessionID = claudeSessionID
    }
}

@Observable final class Branch: Identifiable {
    let id: UUID
    var name: String
    /// The real checkout folder this row maps to — every branch row is backed by a
    /// worktree on disk (the repo root for the main checkout). Sessions run here.
    var worktreeURL: URL
    var sessions: [Session]
    var lastActivity: String   // cosmetic for now ("2h", "now")

    init(id: UUID = UUID(), name: String, worktreeURL: URL, sessions: [Session] = [], lastActivity: String = "") {
        self.id = id
        self.name = name
        self.worktreeURL = worktreeURL
        self.sessions = sessions
        self.lastActivity = lastActivity
    }

    /// A branch with sessions is a live "branch group": expandable, with a roll-up.
    var isLive: Bool { !sessions.isEmpty }
}

@Observable final class Workspace: Identifiable {
    let id: UUID
    var name: String
    var url: URL
    var branches: [Branch]
    var colorIndex: Int

    init(id: UUID = UUID(), name: String, url: URL, branches: [Branch] = [], colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.url = url
        self.branches = branches
        self.colorIndex = colorIndex
    }

    var monogram: String { String(name.first ?? "?").uppercased() }
}
