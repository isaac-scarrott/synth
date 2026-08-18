import Foundation

/// A coding agent Synth can host inside a session. The raw value is persisted (it is a
/// `SessionKind`'s rawValue), so `claudeCode` keeps its historic spelling.
struct AgentID: Hashable, Sendable, Codable, RawRepresentable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init?(rawValue: String) { self.init(rawValue) }

    static let claudeCode = AgentID("claudeCode")
    static let opencode = AgentID("opencode")
    static let antigravity = AgentID("antigravity")

    /// A user-defined agent's id is minted, not declared. It is persisted (in a `SessionKind`, in
    /// a session template entry, in a flags dictionary), so it must survive the agent being
    /// renamed or repointed at another command — which is why it is a uuid and not the command.
    var isCustom: Bool { rawValue.hasPrefix(CustomAgent.idPrefix) }
}

/// A command of the user's own, hosted by an agent Synth already knows how to read: a second
/// Claude Code with its own config, a build kept beside the release one, a wrapper script.
///
/// What it is NOT is a new kind of agent. Status, quit, paste delivery and MCP registration are
/// per-supervisor (ADR-0012 — one `AgentDescriptor` plus one `AgentSupervisor` each), and none of
/// that can be typed into a settings field. So every custom agent names a `base`: the built-in
/// whose supervisor drives it, and whose mark and notification copy it wears. Until it has both a
/// base and a command that resolves, it is simply not offered anywhere (`AgentRegistry.all`).
struct CustomAgent: Codable, Identifiable, Hashable, Sendable {
    static let idPrefix = "custom-"

    var id: String
    /// The word the user meets — in the tree, in every "New …", in Settings.
    var name: String
    /// The command Synth runs. Also the name of its PATH shim, so status reporting finds it.
    var binary: String
    /// The built-in whose supervisor drives it. Nil while the user (or the probe) hasn't said.
    var base: AgentID?
    /// Whether the name is the user's own. An unnamed agent's name follows its command as it is
    /// typed, and stops the moment a name is typed over it.
    var named: Bool = false

    var agentID: AgentID { AgentID(id) }

    static func draft() -> CustomAgent {
        CustomAgent(id: idPrefix + UUID().uuidString.lowercased(), name: "", binary: "", base: nil)
    }

    /// `claude-personal` → "Claude Personal". Only ever a seed: the row renames it.
    static func derivedName(_ binary: String) -> String {
        binary.split(whereSeparator: { "-_. ".contains($0) })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
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
    /// Substrings that identify this agent in some other command's `--version` output — how a
    /// custom command Synth has never seen is recognised as "this is Claude Code, wearing a
    /// different name". Matched case-insensitively.
    var versionMarkers: [String] = []
    /// Extra install locations to search when the launch PATH is bare (Dock / `open`).
    let installHints: [String]
    /// Path fragments that disqualify a candidate the PATH search would otherwise accept, matched
    /// against its fully resolved location. Antigravity is why this exists: the Nov-2025
    /// Antigravity IDE ships an `agy` of its own — a launcher whose "chat" drives the GUI app, not
    /// a terminal agent — and on a machine with both it sits ahead of homebrew on the login PATH,
    /// so a name match alone would hand a session the wrong program entirely.
    var rejectedPathFragments: [String] = []
    /// For a user-defined agent, the built-in whose supervisor drives it (see `CustomAgent`).
    /// Nil for a built-in: it drives itself.
    var baseID: AgentID?

    /// The program a launch must exec to become this agent, and the arguments its name already
    /// carried. The two are one answer because the name a user gives Synth need not be a program:
    /// `claude-personal` is as likely to be a shell alias (`claude-personal=claudewho-personal`,
    /// or one that pins a flag) as a file on PATH, and an alias exists only inside an interactive
    /// shell — nothing Synth spawns would ever see it. So the name is expanded first, and it is
    /// the program the alias stood for that gets located and exec'd, with the alias's own
    /// arguments handed to the shim to put back in front of the user's.
    ///
    /// Nil when nothing on the machine answers to the name — which is what "not installed" means
    /// everywhere else in the app.
    var resolvedCommand: (path: String, args: [String])? {
        guard let words = Self.expandAliases(binaryName), let head = words.first else { return nil }
        guard let path = locate(head) else { return nil }
        return (path, Array(words.dropFirst()))
    }

    /// Where this agent is really installed. Kept as its own name because most of the app only
    /// ever wants the program: `installed`, the shims, teardown.
    var resolvedBinary: String? { resolvedCommand?.path }

    /// Follow an alias to the command line it stands for, as the shell would: the first word is
    /// re-expanded while it names another alias, and the rest ride along. Returns the words of
    /// the command, or nil for an expansion Synth can't exec.
    ///
    /// What can't be exec'd is anything whose meaning comes from the shell rather than from the
    /// program: a pipe, a substitution, a second command — but also quoting, globs and brace
    /// expansion, because splitting those on whitespace and handing them to `execv` produces
    /// arguments the user's own shell would never have passed. An alias like that is a shell
    /// fragment, not a program, and the row says so rather than launching something else.
    ///
    /// A name that isn't an alias comes back as itself, so this is on the path of every agent,
    /// built-in included: a user who has aliased `claude` gets the same treatment.
    static func expandAliases(_ command: String) -> [String]? {
        let aliases = ShellEnvironment.loginAliases ?? [:]
        var words = [command]
        var seen: Set<String> = []
        while let head = words.first, let expansion = aliases[head], seen.insert(head).inserted {
            guard !expansion.contains(where: { "|&;<>()`$\n{}*?[]'\"\\".contains($0) }) else { return nil }
            let expanded = expansion.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !expanded.isEmpty else { return nil }
            words = expanded + words.dropFirst()
        }
        return words.isEmpty ? nil : words
    }

    /// Resolve one command word to a program, on the original PATH (before the shim dir is
    /// prepended). Search order matters: the login-shell PATH first (what a launched agent
    /// actually resolves, and the only place a Dock launch sees version-manager shims), then the
    /// app process's PATH, then `installHints` as a last-ditch guess. A candidate that resolves
    /// to `synth-hook` is one of our own shims — exec'ing it would re-enter the launch role
    /// forever (E2BIG), so skip it, as with anything `rejectedPathFragments` rules out.
    ///
    /// A word with a slash in it is a path already — the shell wouldn't search PATH for it, and
    /// neither does this.
    private func locate(_ command: String) -> String? {
        let home = NSHomeDirectory()
        let expandTilde = { (p: String) in p.hasPrefix("~") ? home + p.dropFirst() : p }
        let candidates: [String]
        if command.contains("/") {
            candidates = [expandTilde(command)]
        } else {
            let processDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map(String.init)
            let searchDirs = (ShellEnvironment.loginPathDirs ?? []) + processDirs
                + installHints.map(expandTilde)
            candidates = searchDirs.map { $0 + "/" + command }
        }
        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            // Resolve the whole chain, not one link: an impostor can be reached through several
            // hops (~/.antigravity/…/agy → /Applications/Antigravity.app/…/antigravity).
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            if (resolved as NSString).lastPathComponent == "synth-hook" { continue }
            if rejectedPathFragments.contains(where: { resolved.contains($0) }) { continue }
            return candidate
        }
        return nil
    }

    /// Whose machinery reads this agent: its base if it has one, else itself.
    var hostID: AgentID { baseID ?? id }
    var isCustom: Bool { baseID != nil }

    /// The env var carrying the real binary path through to the shim ("SYNTH_REAL_CLAUDE").
    /// A user's command can hold characters an env var name can't (`claude-personal`), so
    /// everything outside `[A-Z0-9_]` becomes `_` — the same transform `synth-hook` applies to
    /// the name it was invoked as, which is the only way the two ends agree on the key.
    var realBinaryEnvKey: String { "SYNTH_REAL_" + AgentDescriptor.envSuffix(binaryName) }

    /// Its companion: the arguments the command's name already carried, for a name that was a
    /// shell alias. `\u{01}`-separated because an argument may contain spaces and this is the one
    /// channel where re-quoting would have to be undone exactly right.
    var realArgsEnvKey: String { "SYNTH_REAL_ARGS_" + AgentDescriptor.envSuffix(binaryName) }

    /// Tell the shim which program to exec, and with what already in front. Every supervisor's
    /// `decorate` goes through here: the pair has to be set together or the shim runs the right
    /// program without the flags its name promised.
    func exportRealCommand(into env: inout [String: String]) {
        guard let command = resolvedCommand else { return }
        env[realBinaryEnvKey] = command.path
        if !command.args.isEmpty { env[realArgsEnvKey] = command.args.joined(separator: "\u{01}") }
    }

    static func envSuffix(_ binary: String) -> String {
        String(binary.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    /// Shown in Settings as the "flags look like this" hint. A custom agent takes its base's:
    /// the flags a second Claude Code accepts are Claude Code's.
    var exampleFlags: String {
        switch hostID {
        case .claudeCode: return "--dangerously-skip-permissions --model opus"
        case .opencode: return "--model anthropic/claude-opus-4-5 --agent build"
        case .antigravity: return "--model gemini-3.6-flash-high --mode accept-edits"
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
        versionMarkers: ["claude code"],
        installHints: ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "~/.npm-global/bin", "~/.claude/local"]
    )

    static let opencode = AgentDescriptor(
        id: .opencode,
        displayName: "OpenCode",
        shortName: "OpenCode",
        binaryName: "opencode",
        mark: .openCode,
        versionMarkers: ["opencode"],
        installHints: ["~/.opencode/bin", "~/.local/bin", "/opt/homebrew/bin",
                       "/usr/local/bin", "~/.npm-global/bin"]
    )

    static let antigravity = AgentDescriptor(
        id: .antigravity,
        displayName: "Antigravity",
        shortName: "Antigravity",
        binaryName: "agy",
        mark: .antigravity,
        versionMarkers: ["antigravity", "agy"],
        installHints: ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"],
        rejectedPathFragments: [".app/"]
    )

    /// The three Synth ships with, each one a descriptor AND a supervisor.
    static let builtIn: [AgentDescriptor] = [claudeCode, opencode, antigravity]

    /// Every agent this machine may host: the built-ins, then the user's own in the order they
    /// were added. A list rather than a constant, which is the whole of what custom agents change
    /// structurally — everything downstream already reads the registry rather than naming agents.
    static var all: [AgentDescriptor] { builtIn + customDescriptors }

    static func descriptor(_ id: AgentID) -> AgentDescriptor? { all.first { $0.id == id } }

    // MARK: User-defined agents

    /// The user's own, as Settings holds them (`AppStore.customAgents` is the owner; this is the
    /// registry's copy of the same list). Half-finished ones are kept here but never reach `all`.
    private(set) static var custom: [CustomAgent] = []
    private static var customDescriptors: [AgentDescriptor] = []

    /// Adopt the persisted list. Everything derived from the registry is rebuilt: the installed
    /// cache (so PATH is re-searched for a command that just changed), the PATH shims (a new
    /// command needs its own symlink to report status at all), and the change notification for
    /// surfaces already on screen.
    static func setCustom(_ list: [CustomAgent]) {
        guard list != custom else { return }
        custom = list
        // A custom agent with no base has no supervisor to read it, so it is not something Synth
        // can host yet — it stays in Settings and out of everything else.
        customDescriptors = list.compactMap(descriptor(for:))
        invalidateInstalled()
    }

    /// Re-search PATH for every hosted agent. Called when the registry itself changes, and when a
    /// command the user is typing starts (or stops) resolving — `installed` is otherwise only
    /// rebuilt by the login-PATH probe landing, which is a different question entirely.
    static func invalidateInstalled() {
        installedCache = nil
        HookEnvironment.setup()
        NotificationCenter.default.post(name: installedDidChange, object: nil)
    }

    /// The descriptor a custom agent stands for: its own name and command, everything else its
    /// base's. Nil until it names a base and a command.
    static func descriptor(for c: CustomAgent) -> AgentDescriptor? {
        guard let base = c.base.flatMap(builtInDescriptor), !c.binary.isEmpty else { return nil }
        return AgentDescriptor(
            id: c.agentID,
            displayName: c.name.isEmpty ? CustomAgent.derivedName(c.binary) : c.name,
            shortName: c.name.isEmpty ? base.shortName : c.name,
            binaryName: c.binary,
            mark: base.mark,
            versionMarkers: [],          // it is not something another command should be taken FOR
            installHints: base.installHints,
            rejectedPathFragments: base.rejectedPathFragments,
            baseID: base.id
        )
    }

    static func builtInDescriptor(_ id: AgentID) -> AgentDescriptor? { builtIn.first { $0.id == id } }

    private static var installedCache: [AgentDescriptor]?

    /// Posted on the main actor when `installed` changes because the login-shell PATH probe
    /// landed — the seam for a surface that must react rather than re-read on demand.
    static let installedDidChange = Notification.Name("AgentRegistry.installedDidChange")

    /// Which agents are actually installed. Cached — rescanning PATH per ⌘K keystroke would stat
    /// the filesystem inside the ranking loop. First access resolves against the process PATH and
    /// kicks off the login-shell PATH probe (off-main, timed out, see `ShellEnvironment`); when
    /// that lands, the cache is rebuilt so a version-manager install the bare Dock PATH couldn't
    /// see appears in ⌘K / Settings and gets a hook shim. Surfaces that re-read on demand (⌘K,
    /// Settings when opened) pick the change up for free; an already-onscreen one observes
    /// `installedDidChange`.
    ///
    /// Unfiltered by the Settings switches on purpose — `AppStore.availableAgents` is the set
    /// Synth may START. The PATH shims, `SYNTH_AGENT_BINS` and supervisor teardown have to keep
    /// seeing every agent on the machine, or a session still running a switched-off one loses
    /// its status seam mid-flight.
    static var installed: [AgentDescriptor] {
        if let installedCache { return installedCache }
        let snapshot = all.filter { $0.resolvedBinary != nil }
        installedCache = snapshot
        ShellEnvironment.prewarm { Task { @MainActor in refreshInstalled() } }
        return snapshot
    }

    /// Recompute `installed` against the now-known login-shell PATH. When it surfaces an agent
    /// the process PATH missed, (re)create hook shims — `HookEnvironment.setup` is idempotent, so
    /// a terminal that later runs the newly-found binary still reports status — and fire the
    /// change notification for live surfaces.
    private static func refreshInstalled() {
        let refreshed = all.filter { $0.resolvedBinary != nil }
        guard refreshed.map(\.id) != installedCache?.map(\.id) else { return }
        installedCache = refreshed
        HookEnvironment.setup()
        NotificationCenter.default.post(name: installedDidChange, object: nil)
    }

    static func isInstalled(_ id: AgentID) -> Bool { installed.contains { $0.id == id } }

    // MARK: Supervisors

    /// One long-lived supervisor per agent, created against the store's bus.
    private(set) static var supervisors: [AgentID: any AgentSupervisor] = [:]

    static func startSupervisors(bus: EventBus) {
        supervisors = [
            .claudeCode: ClaudeCodeSupervisor(bus: bus),
            .opencode: OpencodeSupervisor(bus: bus),
            .antigravity: AntigravitySupervisor(bus: bus),
        ]
    }

    /// A custom agent has no supervisor of its own — that is what "hosted by" means. It is read
    /// by its base's, which is why the base is not cosmetic: the supervisor is the machinery.
    static func supervisor(_ id: AgentID) -> (any AgentSupervisor)? {
        supervisors[descriptor(id)?.hostID ?? id]
    }
}

/// The per-session watcher that consumes an agent's raw event firehose locally and emits only
/// derived status facts onto the bus (CONTEXT.md "Supervisor", docs/adr/0001). Each agent
/// brings its own transport — Claude Code and Antigravity push hook signals over a unix socket;
/// opencode is read over its own HTTP event stream — and all land on the same `SessionEvent` seam.
@MainActor protocol AgentSupervisor: AnyObject {
    var id: AgentID { get }

    /// Overlay the env a PTY needs so a `binaryName` typed inside it reports back to Synth.
    /// Called for every terminal, because any terminal may become this agent — and once per
    /// descriptor this supervisor hosts, since a user's own command is a different binary at a
    /// different path and its env has to name that one, not the built-in's.
    func decorate(_ env: inout [String: String], sessionID: UUID, agent: AgentDescriptor)

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
    /// conversation. `binary` is the command to run — the built-in's, or the user's own command
    /// this supervisor is hosting.
    func launchCommand(binary: String, resume: String?, flags: String) -> String
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

    func decorate(_ env: inout [String: String], sessionID: UUID, agent: AgentDescriptor) {
        agent.exportRealCommand(into: &env)
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

    func launchCommand(binary: String, resume: String?, flags: String) -> String {
        let extra = flags.isEmpty ? "" : " " + flags
        if let resume { return "exec \(binary) --resume \(shellQuoteAgentArg(resume))\(extra)" }
        return "exec \(binary)\(extra)"
    }
}
