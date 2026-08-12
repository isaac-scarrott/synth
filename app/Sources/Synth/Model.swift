import Foundation
import Observation

/// The kind of live thing running inside a branch. `agent` carries *which* coding agent, so
/// every surface renders any agent without switching on a specific one (see Agents.swift).
enum SessionKind: Codable, Sendable, Hashable {
    case terminal
    case agent(AgentID)
    case browser
    case simulator
    /// A markdown document, read and edited in the bundled synth-md TUI (ADR-0016). Like an
    /// agent row it is a terminal session whose launch command is fixed; unlike one it carries
    /// no liveness of its own — the row is `.idle` for life.
    case markdown

    /// The agent hosted by this session, if it is one.
    var agentID: AgentID? {
        if case let .agent(id) = self { return id }
        return nil
    }

    var isAgent: Bool { agentID != nil }
}

extension SessionKind: RawRepresentable {
    /// Persisted verbatim (ADR-0010). An agent's rawValue is its `AgentID` — so snapshots
    /// written before agents were generalised, whose sessions say `"claudeCode"`, still decode.
    var rawValue: String {
        switch self {
        case .terminal: return "terminal"
        case .browser: return "browser"
        case .simulator: return "simulator"
        case .markdown: return "markdown"
        case .agent(let id): return id.rawValue
        }
    }

    init?(rawValue: String) {
        // Every non-agent kind needs its own arm: the default is "anything unrecognised is an
        // agent id", so a missing case doesn't fail loudly — it decodes the kind as a bogus agent.
        switch rawValue {
        case "terminal": self = .terminal
        case "browser": self = .browser
        case "simulator": self = .simulator
        case "markdown": self = .markdown
        default: self = .agent(AgentID(rawValue))
        }
    }
}

extension SessionKind {
    /// Encoded as the bare rawValue string, not the keyed container Swift would synthesise for
    /// a case with an associated value — snapshots store `"claudeCode"` / `"terminal"`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionKind(rawValue: raw) ?? .terminal
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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

    /// Busy: an agent mid-turn or a process up (ADR-0013). Close wears red and confirms
    /// only while this is true; needs-input is a request, not busy, and closes quietly.
    var isBusy: Bool {
        switch self {
        case .running, .working: return true
        case .idle, .exited, .error, .needsInput: return false
        }
    }
}

@Observable final class Session: Identifiable {
    /// Stable across restarts: restored from disk (ADR-0010) so persisted expansion and
    /// selection, which key off this id, keep pointing at the same row.
    let id: UUID
    /// Mutable: a terminal that runs an agent's binary is detected and upgraded to
    /// `.agent(id)` (and reverts when it exits) — the kind reflects what's running, not a
    /// creation label.
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
    /// The agent's own session id — Claude Code's is minted by our launch shim and reported
    /// over the hook socket; opencode's is minted by its server and read off `session.created`.
    /// A restored agent row uses it to resume the conversation. nil for terminals, browsers,
    /// and not-yet-started agent sessions.
    var agentSessionID: String?
    /// A browser session's current page (ADR-0011). Persisted so a restored browser reopens
    /// its URL in a fresh engine; nil for non-browsers and a fresh "go to" home surface.
    var browserURL: URL?
    /// The Claude Code session that owns this browser (ADR-0011 stage four containment) —
    /// the Synth row's id, not Claude's own session id, so ownership survives claude exits
    /// and `--resume`. nil for unowned browsers and every non-browser session.
    var ownerSessionID: UUID?
    /// The simulator device this session drives, by UDID — what a simulator session *is*
    /// (ADR-0015), the analogue of a browser's `browserURL`. Persisted, so a restored row
    /// reclaims the same device; a UDID rather than a model name so cloning a device per
    /// branch stays possible later. nil for non-simulators and for a simulator session
    /// spawned from a template, which has no device to name yet.
    var simulatorUDID: String?
    /// The file a markdown session is showing — what that kind of session *is*, the analogue
    /// of a browser's `browserURL` (ADR-0016). Persisted, so a restored row reopens the same
    /// document. nil for every other kind, and for a markdown row spawned from a template,
    /// which has no document to name yet.
    var markdownPath: String?

    init(id: UUID = UUID(), kind: SessionKind, title: String, status: SessionStatus = .idle, unread: Bool = false, titleIsCustom: Bool = false, agentSessionID: String? = nil, browserURL: URL? = nil, ownerSessionID: UUID? = nil, simulatorUDID: String? = nil, markdownPath: String? = nil) {
        self.id = id
        self.kind = kind
        self.spawnedKind = kind
        self.title = title
        self.status = status
        self.unread = unread
        self.titleIsCustom = titleIsCustom
        self.agentSessionID = agentSessionID
        self.browserURL = browserURL
        self.ownerSessionID = ownerSessionID
        self.simulatorUDID = simulatorUDID
        self.markdownPath = markdownPath
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
    @MainActor var tplStart: String {
        switch self {
        case .agent(let id): return AgentRegistry.descriptor(id)?.displayName ?? id.rawValue
        case .terminal:      return "shell"
        case .browser:       return "Browser"
        case .simulator:     return "Simulator"
        case .markdown:      return "Document"
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

    /// A dev server on this machine — the one web target that belongs in Synth's own browser
    /// (no login to lose, and the agent can drive the exact page). Everything else is the
    /// user's real browser's job. Mirrors fromBrowserInput's loopback set.
    var isLoopbackHost: Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "localhost" || h == "127.0.0.1" || h == "0.0.0.0"
            || h == "::1" || h == "[::1]" || h.hasSuffix(".localhost")
    }
}

@Observable final class Branch: Identifiable {
    let id: UUID
    var name: String
    /// The real checkout folder this row maps to — every branch row is backed by a
    /// worktree on disk (the repo root for the main checkout). Sessions run here.
    var worktreeURL: URL
    var sessions: [Session]
    /// A git-derived age string for a dormant branch ("2h" from the curated add); once the branch
    /// sees real activity `lastActivityAt` supersedes it (see `activityLabel`).
    var lastActivity: String
    /// When this branch last saw activity (a session or worktree created). The source of truth for
    /// the sidebar's relative timestamp; nil until the first activity, then it decays live.
    var lastActivityAt: Date?
    /// The 5 most recent distinct URLs visited across this branch's browser sessions —
    /// feeds the home surface / omnibox-dropdown "Recent" list. Empty until a browser
    /// session navigates (working.html's static BROWSER_RECENTS, made real + persisted).
    var browserRecents: [BrowserRecent]
    /// True while the worktree is still being created in the background: the row is
    /// already in the tree (grayed, spinner, inert) but has no checkout to act on yet.
    /// Never persisted — a quit mid-create must not restore a half-made row.
    var isPending: Bool
    /// This branch's GitHub pull request, if any (PRService). Derived like session status,
    /// not persisted: nil until the first `gh` read fills it, refreshed on activation.
    var pr: PRInfo?
    /// This branch's remembered pane layout (ADR-0014): the durable split it owns, restored on
    /// relaunch. nil = a single pane (no split to remember). Kept in step with the on-screen tree
    /// by the store (syncBranchLayout) and serialized to disk (slice 014).
    var layout: PaneNode?
    /// When the user archived this row. Non-nil is the whole archive state: the row leaves the
    /// sidebar, keeps its folder, and starts the clock the sweeper measures against. Set at
    /// undo-commit, not at the gesture — the 8s window must change nothing, and a row hidden
    /// by an archive the user then undid would be unreachable.
    var archivedAt: Date?
    /// When the sweeper last found this branch clean on every condition. Two clean readings a
    /// day apart are required before it acts, which is what makes a transient — mid-rebase,
    /// briefly offline — unable to authorise a delete on its own.
    var lastCleanSweepEval: Date?

    init(id: UUID = UUID(), name: String, worktreeURL: URL, sessions: [Session] = [], lastActivity: String = "", lastActivityAt: Date? = nil, browserRecents: [BrowserRecent] = [], isPending: Bool = false, archivedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.worktreeURL = worktreeURL
        self.sessions = sessions
        self.lastActivity = lastActivity
        self.lastActivityAt = lastActivityAt
        self.browserRecents = browserRecents
        self.isPending = isPending
        self.archivedAt = archivedAt
    }

    /// A branch with sessions is a live "branch group": expandable, with a roll-up.
    var isLive: Bool { !sessions.isEmpty }

    /// Archived rows are out of the sidebar, out of ⌘K's branch lists, and out of every
    /// count — reachable only through the workspace's Archived list. A row still visible in
    /// the tree is not archived.
    var isArchived: Bool { archivedAt != nil }

    /// Stamp "activity happened now" — a session or worktree was created. Drives the relative
    /// timestamp, which then decays on its own.
    func markActivity() { lastActivityAt = Date() }

    /// The sidebar's relative timestamp: the real elapsed age once the branch has seen activity,
    /// else the git-derived age string (a dormant branch's commit age). Empty when neither exists.
    func activityLabel(now: Date) -> String {
        guard let at = lastActivityAt else { return lastActivity }
        return relativeAge(at, now: now)
    }
}

/// A compact elapsed-time label: `now` under a minute, then `Nm` / `Nh` / `Nd`.
func relativeAge(_ date: Date, now: Date) -> String {
    let s = max(0, now.timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    return "\(Int(s / 86400))d"
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

    /// The branches the tree shows. Archived rows stay in `branches` — that array is what the
    /// Archived list reads, what restore puts back, and what persists — so every surface that
    /// means "the rows the user has" must ask for these, not for `branches`.
    var liveBranches: [Branch] { branches.filter { !$0.isArchived } }
}
