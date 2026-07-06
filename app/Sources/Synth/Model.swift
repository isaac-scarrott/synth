import Foundation
import Observation

/// The kind of live thing running inside a branch.
enum SessionKind: String, Codable, Sendable {
    case terminal
    case claudeCode
    case browser
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
    /// The creation label `kind` drifts from: a session spawned as Claude execs `claude`
    /// (no shell to fall back to), so its claude-end never reverts the kind — the whole
    /// session ends with the process instead (features 2026-07-06).
    let spawnedKind: SessionKind
    var title: String
    var status: SessionStatus
    var unread: Bool
    /// Set once the user renames the session by hand. Freezes the title so auto-naming —
    /// Claude Code's evolving ai-title, a terminal's running command, a browser's page
    /// title — stops overwriting a chosen name.
    var titleIsCustom: Bool
    /// Claude Code's own session id — minted by our launch shim, reported back over the hook
    /// socket (Hooks/synth-hook). A restored Claude row uses it to resume the conversation
    /// with `claude --resume <id>`. nil for terminals and not-yet-started Claude sessions.
    var claudeSessionID: String?
    /// A browser session's current page (ADR-0011). Persisted so a restored browser reopens
    /// its URL in a fresh engine; nil for non-browsers and a fresh "go to" home surface.
    var browserURL: URL?
    /// The Claude Code session that owns this browser (ADR-0011 stage four containment) —
    /// the Synth row's id, not Claude's own session id, so ownership survives claude exits
    /// and `--resume`. nil for unowned browsers and every non-browser session.
    var ownerSessionID: UUID?

    init(id: UUID = UUID(), kind: SessionKind, title: String, status: SessionStatus = .idle, unread: Bool = false, titleIsCustom: Bool = false, claudeSessionID: String? = nil, browserURL: URL? = nil, ownerSessionID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.spawnedKind = kind
        self.title = title
        self.status = status
        self.unread = unread
        self.titleIsCustom = titleIsCustom
        self.claudeSessionID = claudeSessionID
        self.browserURL = browserURL
        self.ownerSessionID = ownerSessionID
    }
}

/// One entry of a branch's browser "Recent" list (working.html BROWSER_RECENTS): the full
/// URL plus the page's last-seen title for the right-hand name column. Plain Codable value —
/// shared by the runtime model and the persisted snapshot.
struct BrowserRecent: Codable, Equatable, Sendable {
    var url: String
    var title: String
}

/// One entry of the new-worktree session template (working.html TPL_KINDS / globalTpl):
/// the kind of session a new worktree starts with plus its starting name. Plain Codable
/// value shared by the runtime store and the persisted snapshot (the BrowserRecent model).
/// `id` is encoded so a row keeps its identity across restarts and while reordering.
struct SessionTemplateEntry: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var kind: SessionKind
    var name: String
}

extension SessionKind {
    /// The name a template entry of this kind starts with (working.html TPL_KINDS.start) —
    /// the settings add-bar default, and the spawn side's "stock name" test: an entry
    /// whose name still matches spawns with auto-naming live, a differing one is
    /// hand-picked and freezes (titleIsCustom).
    var tplStart: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .terminal:   return "shell"
        case .browser:    return "Browser"
        }
    }
}

extension SessionTemplateEntry {
    /// An unknown persisted kind decodes as .terminal instead of throwing (the same guard
    /// PersistedSession applies via rawValue): PersistenceStore.load() treats ANY decode
    /// error as "snapshot unreadable", so one bad entry must never cost the whole tree.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = SessionKind(rawValue: try c.decode(String.self, forKey: .kind)) ?? .terminal
        self.name = try c.decode(String.self, forKey: .name)
    }
}

extension URL {
    /// working.html's browserNorm, shared by the omnibox and the control-socket
    /// browser.create verb: a schemeless entry gets https:// — except loopback hosts,
    /// which get http:// (the primary job is a branch's dev server, and
    /// `localhost:8733` over TLS would just fail). file:// URLs pass through — they
    /// have no host to require. nil when the text isn't navigable.
    static func fromBrowserInput(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let norm: String
        if t.contains("://") {
            norm = t
        } else if t.hasPrefix("localhost") || t.hasPrefix("127.") || t.hasPrefix("[::1]") || t.hasPrefix("0.0.0.0") {
            norm = "http://" + t
        } else {
            norm = "https://" + t
        }
        guard let url = URL(string: norm), url.host != nil || url.isFileURL else { return nil }
        return url
    }

    /// working.html's `browserHost`, tightened to host+path: what browser sessions are named
    /// by and what the omnibox pill / recents show ("localhost:8733/palette", no scheme).
    var browserHostPath: String {
        var s = (host ?? "") + (port.map { ":\($0)" } ?? "") + path
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? absoluteString : s
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
    /// The 5 most recent distinct URLs visited across this branch's browser sessions —
    /// feeds the home surface / omnibox-dropdown "Recent" list. Empty until a browser
    /// session navigates (working.html's static BROWSER_RECENTS, made real + persisted).
    var browserRecents: [BrowserRecent]
    /// True while the worktree is still being created in the background: the row is
    /// already in the tree (grayed, spinner, inert) but has no checkout to act on yet.
    /// Never persisted — a quit mid-create must not restore a half-made row.
    var isPending: Bool

    init(id: UUID = UUID(), name: String, worktreeURL: URL, sessions: [Session] = [], lastActivity: String = "", browserRecents: [BrowserRecent] = [], isPending: Bool = false) {
        self.id = id
        self.name = name
        self.worktreeURL = worktreeURL
        self.sessions = sessions
        self.lastActivity = lastActivity
        self.browserRecents = browserRecents
        self.isPending = isPending
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
