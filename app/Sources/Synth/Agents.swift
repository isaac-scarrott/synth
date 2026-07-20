import Foundation

/// A coding agent Synth can host inside a session. The raw value is persisted (it is a
/// `SessionKind`'s rawValue), so `claudeCode` keeps its historic spelling.
struct AgentID: Hashable, Sendable, Codable, RawRepresentable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init?(rawValue: String) { self.init(rawValue) }

    static let claudeCode = AgentID("claudeCode")
    static let opencode = AgentID("opencode")
}

/// Everything Synth needs to host one coding agent: how it's named, which binary a terminal
/// runs to become it, and which supervisor turns its firehose into derived status facts.
///
/// Adding a third agent is one descriptor here plus one `AgentSupervisor` — nothing else in
/// the app switches on a specific agent.
struct AgentDescriptor: Sendable {
    let id: AgentID
    /// The full name every user-facing surface uses, spelled the way the product spells itself:
    /// "Claude Code", "OpenCode" (the *command* stays lowercase — see `binaryName`).
    let displayName: String
    /// The subject of a notification sentence ("Claude finished", "OpenCode needs your input").
    let shortName: String
    /// The command a terminal runs to become this agent — also the name of its PATH shim.
    let binaryName: String
    /// The artwork its icon slot renders.
    let mark: AgentMark
    /// Extra install locations to search when the launch PATH is bare (Dock / `open`).
    let installHints: [String]

    /// Where this agent is really installed, resolved once on the original PATH (before the
    /// shim dir is prepended). A candidate that resolves to `synth-hook` is one of our own
    /// shims — exec'ing it would re-enter the launch role forever (E2BIG), so skip it.
    var resolvedBinary: String? {
        let home = NSHomeDirectory()
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in pathDirs + installHints.map({ $0.replacingOccurrences(of: "~", with: home) }) {
            let candidate = dir + "/" + binaryName
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)) ?? candidate
            if (resolved as NSString).lastPathComponent == "synth-hook" { continue }
            return candidate
        }
        return nil
    }

    /// The env var carrying the real binary path through to the shim ("SYNTH_REAL_CLAUDE").
    var realBinaryEnvKey: String { "SYNTH_REAL_" + binaryName.uppercased() }

    /// Shown in Settings as the "flags look like this" hint.
    var exampleFlags: String {
        switch id {
        case .claudeCode: return "--dangerously-skip-permissions --model opus"
        case .opencode: return "--model anthropic/claude-opus-4-5 --agent build"
        default: return "--help"
        }
    }
}

extension AgentDescriptor: Identifiable {}

/// The agents Synth knows how to host. Order is the order they appear in ⌘K and Settings.
@MainActor enum AgentRegistry {
    static let claudeCode = AgentDescriptor(
        id: .claudeCode,
        displayName: "Claude Code",
        shortName: "Claude",
        binaryName: "claude",
        mark: .clawd,
        installHints: ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "~/.npm-global/bin", "~/.claude/local"]
    )

    static let opencode = AgentDescriptor(
        id: .opencode,
        displayName: "OpenCode",
        shortName: "OpenCode",
        binaryName: "opencode",
        mark: .openCode,
        installHints: ["~/.opencode/bin", "~/.local/bin", "/opt/homebrew/bin",
                       "/usr/local/bin", "~/.npm-global/bin"]
    )

    static let all: [AgentDescriptor] = [claudeCode, opencode]

    static func descriptor(_ id: AgentID) -> AgentDescriptor? { all.first { $0.id == id } }

    /// Resolved once: rescanning PATH per keystroke would stat the filesystem in ⌘K's ranking.
    static let installed: [AgentDescriptor] = all.filter { $0.resolvedBinary != nil }

    static func isInstalled(_ id: AgentID) -> Bool { installed.contains { $0.id == id } }

    /// The agent a bare "new agent session" action means when the user hasn't picked one —
    /// the first installed agent, so a machine with only opencode still gets a working ⌘K.
    static var `default`: AgentDescriptor? { installed.first }

    // MARK: Supervisors

    /// One long-lived supervisor per agent, created against the store's bus.
    private(set) static var supervisors: [AgentID: any AgentSupervisor] = [:]

    static func startSupervisors(bus: EventBus) {
        supervisors = [
            .claudeCode: ClaudeCodeSupervisor(bus: bus),
            .opencode: OpencodeSupervisor(bus: bus),
        ]
    }

    static func supervisor(_ id: AgentID) -> (any AgentSupervisor)? { supervisors[id] }
}

/// The per-session watcher that consumes an agent's raw event firehose locally and emits only
/// derived status facts onto the bus (CONTEXT.md "Supervisor", docs/adr/0001). Each agent
/// brings its own transport — Claude Code pushes hook signals over a unix socket; opencode is
/// polled over its own HTTP event stream — and both land on the same `SessionEvent` seam.
@MainActor protocol AgentSupervisor: AnyObject {
    var id: AgentID { get }

    /// Overlay the env a PTY needs so a `binaryName` typed inside it reports back to Synth.
    /// Called for every terminal, because any terminal may become this agent.
    func decorate(_ env: inout [String: String], sessionID: UUID)

    /// The agent announced itself in `session` (the shim's agent-start). A transport-based
    /// supervisor connects here, and posts `.agentReady` once it actually can reach the agent.
    func attach(session: UUID)

    /// The agent left `session` (agent-end, or the PTY child exited).
    func detach(session: UUID)

    /// Deliver human text into the live agent — a browser comment, a feedback seed.
    /// False when the agent isn't reachable, so the caller never falls back to a bare shell.
    func deliver(_ text: String, to session: UUID) -> Bool

    /// The shell line a fresh PTY runs to become this agent, passed to the login shell as `-c`.
    /// `exec`, so the agent's exit is the PTY child's exit. `resume` restores a persisted
    /// conversation.
    func launchCommand(resume: String?, flags: String) -> String
}

/// Shell-quote a string for the single-quoted context the launch command types into a shell.
func shellQuoteAgentArg(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Claude Code: detected via its own hooks, which the launch shim injects with `--settings`.
/// Every status fact arrives over the hook socket (`HookServer`), so this supervisor has no
/// transport of its own.
@MainActor final class ClaudeCodeSupervisor: AgentSupervisor {
    let id = AgentID.claudeCode
    private weak var bus: EventBus?
    /// The only sessions this supervisor considers ready — those whose `attach` came from a
    /// hook, which by definition fired from inside a running claude.
    private var attached: Set<UUID> = []

    init(bus: EventBus) { self.bus = bus }

    func decorate(_ env: inout [String: String], sessionID: UUID) {
        guard let real = AgentRegistry.claudeCode.resolvedBinary else { return }
        env[AgentRegistry.claudeCode.realBinaryEnvKey] = real
    }

    /// Claude announces itself only once it is running: `attach` is driven by its SessionStart
    /// hook, executed by the live process. So attaching *is* readiness — no probe needed.
    func attach(session: UUID) {
        guard attached.insert(session).inserted else { return }
        bus?.post(.agentReady(session))
    }

    func detach(session: UUID) { attached.remove(session) }

    /// Claude Code has no injection API: the text is pasted into the TUI and submitted a beat
    /// later, so the terminal finishes ingesting the paste before it sees the Enter.
    func deliver(_ text: String, to session: UUID) -> Bool {
        TerminalManager.shared.submit(text, to: session)
    }

    func launchCommand(resume: String?, flags: String) -> String {
        let extra = flags.isEmpty ? "" : " " + flags
        if let resume { return "exec claude --resume \(shellQuoteAgentArg(resume))\(extra)" }
        return "exec claude\(extra)"
    }
}
