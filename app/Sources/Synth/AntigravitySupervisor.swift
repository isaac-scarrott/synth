import Foundation
import OSLog

/// Antigravity (`agy`): hosted as its own TUI in the session's PTY and supervised the way Claude
/// Code is — by instrumenting it rather than subscribing to it. `agy` reads hooks from
/// `<workspaceDir>/.agents/hooks.json` for EVERY workspace dir, including one appended with
/// `--add-dir` — so the launch shim points a Synth-owned dir at `synth-hook` and hands it over on
/// the command line, and nothing in the user's repo or their global settings is ever written. The
/// config is near Claude's but not it: each top-level key is a *named* hook (names from different
/// configs merge, so ours never displaces the user's), and tool events group their handlers under
/// a `matcher` while lifecycle events list them flat — see `writeAgyHooks` in synth-hook.
/// All five of its events then shell back over the hook socket exactly like Claude's, which is
/// why this supervisor has no transport of its own.
///
/// It has the jobs the hooks can't do, all of them the same shape — the session stopping with no
/// hook to say so. `agy`'s own CLI log does say so, so the shim points `--log-file` at a
/// Synth-owned path and this supervisor tails it, the one place a fact about Antigravity is
/// scraped rather than pushed: a tool confirmation and its answer, an interrupted turn (whose
/// `Stop` hook agy kills along with the turn), the receipt for a delivered paste (`deliver`), and
/// the two screens that stand between launch and an input box — the sign-in spinner and the
/// workspace trust prompt, which together decide readiness (`considerReady`).
@MainActor final class AntigravitySupervisor: AgentSupervisor {
    let id = AgentID.antigravity

    private weak var bus: EventBus?
    private static let log = Logger(subsystem: bundleIdentifier, category: "antigravity")
    /// The live log tail per session, cancelled on detach.
    private var tails: [UUID: AntigravityLogTail] = [:]
    /// Sessions already declared reachable, so the boot marker can't post `.agentReady` twice.
    private var ready: Set<UUID> = []
    /// The workspace `agy` opened for a session, read back out of its own log — the path whose
    /// trust decides whether the TUI is at a prompt or at its input box.
    private var workspaces: [UUID: String] = [:]
    /// When a session's account and model resolved. Readiness needs this AND a trusted
    /// workspace, and the two arrive in either order.
    private var bootedAt: [UUID: Date] = [:]
    /// When each session's log last said anything — how "still booting" is told from "waiting".
    private var lastLineAt: [UUID: Date] = [:]
    /// Sessions already reported as blocked on the trust prompt, so the re-check can't repost it.
    private var awaitingTrust: Set<UUID> = []
    /// How many prompts each session's TUI has actually taken, counted off its own log — the only
    /// acknowledgement `agy` gives that a paste became a turn (see `deliver`).
    private var promptsTaken: [UUID: Int] = [:]

    init(bus: EventBus) { self.bus = bus }

    // MARK: Launch

    /// Where the launch shim instruments this session: it writes `.agents/hooks.json` and
    /// `.agents/mcp_config.json` into the hooks dir and hands agy `--add-dir <dir> --log-file
    /// <log>` (unless the user asked for a log of their own, which wins — agy keeps only one).
    ///
    /// The log is dropped here rather than left to the shim because the tail reads each launch
    /// from the top: a relaunch of the same row reuses the path, and replayed lines would resume
    /// the *previous* conversation and raise a permission prompt nobody is looking at.
    func decorate(_ env: inout [String: String], sessionID: UUID, agent: AgentDescriptor) {
        guard agent.resolvedCommand != nil else { return }
        agent.exportRealCommand(into: &env)
        env["SYNTH_ANTIGRAVITY_HOOKS_DIR"] = Self.sessionDir(sessionID)
        env["SYNTH_ANTIGRAVITY_LOG"] = Self.logPath(sessionID)
        // An embedded agent must not self-update mid-session.
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
        // agy opens `--log-file` itself and won't dig the path out for us, so the dir has to be
        // standing before it launches.
        try? FileManager.default.createDirectory(atPath: Self.sessionDir(sessionID),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: Self.logPath(sessionID))
    }

    func launchCommand(binary: String, resume: String?, flags: String) -> String {
        let extra = flags.isEmpty ? "" : " " + flags
        if let resume { return "exec \(binary) --conversation \(shellQuoteAgentArg(resume))\(extra)" }
        return "exec \(binary)\(extra)"
    }

    // MARK: Supervision

    /// `agy` has no session-start hook — its first hook is a *turn* start — so the shim announces
    /// the launch before exec'ing, meaning attach happens while the agent is still booting.
    /// Readiness is what lets a browser comment be pasted into this PTY, and `agy` spends its
    /// first seconds showing screens that swallow a paste whole, so it is asserted only once the
    /// TUI is provably at its input box — see `considerReady`.
    func attach(session: UUID) {
        guard tails[session] == nil else { return }
        let tail = AntigravityLogTail(path: Self.logPath(session)) { line in
            Task { @MainActor [weak self] in self?.handle(line, session: session) }
        }
        tails[session] = tail
        tail.start()
        // Answering the trust prompt is a keypress, not a log event, so nothing wakes this
        // supervisor when the user finally does it. Re-ask while a session is waiting on it.
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.tails[session] != nil, !self.ready.contains(session) else { return }
                self.considerReady(session)
            }
        }
        // A user who passes their own --log-file keeps it (agy takes one), so there may be no
        // Synth log to ever read and none of the markers in `considerReady` can ever arrive.
        // Rather than leave that session permanently undeliverable, fall back to the Claude Code
        // rule — the shim only announced this after exec'ing, so by now the agent is running or
        // its row is already dying. Only for a log that never said anything at all: one that is
        // merely mid-boot is `considerReady`'s to judge, and pre-empting it here would reinstate
        // the dropped first comment this whole path exists to prevent.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.tails[session] != nil, self.lastLineAt[session] == nil else { return }
            self.markReady(session)
        }
    }

    func detach(session: UUID) {
        tails[session]?.stop()
        tails[session] = nil
        ready.remove(session)
        bootedAt.removeValue(forKey: session)
        lastLineAt.removeValue(forKey: session)
        workspaces.removeValue(forKey: session)
        awaitingTrust.remove(session)
        promptsTaken.removeValue(forKey: session)
    }

    // MARK: Delivery

    /// Like Claude Code, `agy` exposes no injection API: the text is pasted into the TUI and
    /// submitted a beat later, so the terminal finishes ingesting the paste before the Enter.
    ///
    /// Unlike Claude Code, that paste is not reliably taken. `considerReady` waits for the TUI to
    /// stop redrawing, which is the closest thing agy publishes to "the input box is live", and it
    /// is still only close: a paste in the seconds after it lands on the floor perhaps one time in
    /// two, silently — the row works, the comment simply never happened. So the paste is confirmed
    /// the way OpenCode's is, against the one acknowledgement agy gives (its own log naming the
    /// text it took), and re-sent until it takes. Never blind-retried: a paste that *did* land and
    /// is merely slow would be submitted twice, and the second copy is a whole extra turn.
    func deliver(_ text: String, to session: UUID) -> Bool {
        guard TerminalManager.shared.submit(text, to: session) else { return false }
        // No log to read the acknowledgement from (the user passed a `--log-file` of their own),
        // so there is nothing to confirm against and a retry would be the blind kind.
        guard lastLineAt[session] != nil else { return true }
        let before = promptsTaken[session] ?? 0
        Task { @MainActor [weak self] in
            await self?.resubmitUntilTaken(text, session: session, after: before)
        }
        return true
    }

    private func resubmitUntilTaken(_ text: String, session: UUID, after before: Int) async {
        for _ in 0..<Self.deliveryAttempts {
            // A submit's own Enter trails its paste by 0.35s, and agy logs the prompt as it takes
            // it, so this is the whole round trip with room to spare.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if (promptsTaken[session] ?? 0) > before { return }
            }
            guard tails[session] != nil else { return }   // the row went away mid-wait
            _ = TerminalManager.shared.submit(text, to: session)
        }
        Self.log.error("Antigravity never took the delivered text")
    }

    private static let deliveryAttempts = 6

    // MARK: Log

    /// The facts worth reading out of `agy`'s log — the ones none of its hooks carries. Everything
    /// else, status included, arrives as a hook signal through `HookServer` and never reaches
    /// this supervisor.
    private func handle(_ line: String, session: UUID) {
        if let range = line.range(of: Self.workspaceMarker) {
            let path = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Compared against the trusted list, which agy stores fully resolved.
            workspaces[session] = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        lastLineAt[session] = Date()
        if line.contains(Self.bootMarker), bootedAt[session] == nil { bootedAt[session] = Date() }
        // The TUI naming a prompt it has taken — the receipt `deliver` waits on.
        if line.contains(Self.promptTakenMarker) { promptsTaken[session, default: 0] += 1 }
        // A permission prompt is the one stop with no hook behind it, and the answer to it is
        // the resumption — both ends of the state live here because neither is an event agy
        // publishes. (Auto-approved tools never surface, so `--mode accept-edits` and
        // `--dangerously-skip-permissions` sessions raise none of this.)
        if line.contains(Self.confirmationMarker) { bus?.post(.statusChanged(session, .needsInput)) }
        if line.contains(Self.confirmationAnsweredMarker) { bus?.post(.statusChanged(session, .working)) }
        // An interrupted turn is the one *ending* with no hook behind it: agy calls its Stop hook
        // with the cancelled context, which kills our handler before it can report ("failed to
        // call custom stop hook … context canceled"). Without this the row keeps a turn's amber
        // for as long as it sits there — the agent is idle and the sidebar says it is thinking.
        if line.contains(Self.cancelMarker) { bus?.post(.statusChanged(session, .idle)) }
        // Backup for the conversation id the hook payloads carry: a session the user quits
        // before ever prompting still gets an id to resume from.
        if let id = Self.conversationID(line) { bus?.post(.agentSessionCaptured(session, id)) }
        considerReady(session)
    }

    /// The three things that have to be true before text pasted into this PTY reaches the agent
    /// rather than the floor, all learned from `agy`'s own log because it publishes no
    /// "input box is live" event of any kind:
    ///
    /// 1. **The workspace is trusted.** On a path `agy` has not seen before it opens on a modal
    ///    "do you trust the contents of this project?", which every new Synth worktree hits. Text
    ///    delivered then is swallowed and the submitting Enter answers the *prompt* instead — so
    ///    while it stands the row is `needsInput` (a human is genuinely required) and never live.
    ///    Synth only ever reads that answer: granting filesystem trust on the user's behalf is
    ///    not Synth's to do.
    /// 2. **The account and model resolved.** `agy` reaches "CLI mode" in single-digit
    ///    milliseconds and says so, but that screen is a *sign-in spinner*; the input box needs
    ///    the selected model, ~1.5s later.
    /// 3. **Its startup chatter stopped.** Even past the model, `agy` spends a further ~3s
    ///    re-resolving models, quota and slash commands, redrawing as it goes, and a paste landing
    ///    in that window is still lost. There is no event for the end of it, so the honest signal
    ///    is the log going quiet — with a cap, because a log that never does must not strand the
    ///    row. Measured on 1.1.8: gaps inside the churn stay under a second; `settle` is the
    ///    margin over that.
    private func considerReady(_ session: UUID) {
        guard !ready.contains(session) else { return }
        guard !isBlockedOnTrust(session) else {
            if awaitingTrust.insert(session).inserted {
                bus?.post(.statusChanged(session, .needsInput))
            }
            return
        }
        guard let booted = bootedAt[session] else { return }
        let quiet = Date().timeIntervalSince(lastLineAt[session] ?? booted)
        guard quiet >= Self.settle || Date().timeIntervalSince(booted) >= Self.settleCap else { return }
        markReady(session)
    }

    private static let settle: TimeInterval = 2
    private static let settleCap: TimeInterval = 20

    /// True only when the workspace is *known* and absent from `agy`'s trusted list — an unknown
    /// workspace is not evidence of a prompt, and must not strand the row.
    private func isBlockedOnTrust(_ session: UUID) -> Bool {
        guard let workspace = workspaces[session] else { return false }
        return !Self.trustedWorkspaces().contains(workspace)
    }

    private func markReady(_ session: UUID) {
        awaitingTrust.remove(session)
        guard ready.insert(session).inserted else { return }
        bus?.post(.agentReady(session))
    }

    /// The workspaces the user has already trusted, as `agy` records them. Read every time and
    /// never written: the answer changes the moment the user answers the prompt, and this is the
    /// only way Synth hears about it.
    private static func trustedWorkspaces() -> Set<String> {
        let path = NSHomeDirectory() + "/.gemini/antigravity-cli/settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["trustedWorkspaces"] as? [String] else { return [] }
        return Set(list.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    }

    /// `agy` logs this when it hands the resolved account and model to its backend — the first
    /// point at which the TUI is showing an input box rather than a sign-in spinner.
    private static let bootMarker = "Propagating selected model override to backend"
    private static let workspaceMarker = "Initializing CLI store manager for workspace "
    private static let promptTakenMarker = "HandleUserInput called with text:"
    private static let confirmationMarker = "Surfacing tool confirmation"
    private static let confirmationAnsweredMarker = "Responding to tool confirmation"
    private static let cancelMarker = "Cancelling in-progress response"
    private static let conversationMarker = "Created conversation "

    /// "…] Created conversation bb1abf61-…" → the uuid.
    private static func conversationID(_ line: String) -> String? {
        guard let range = line.range(of: conversationMarker) else { return nil }
        let id = line[range.upperBound...].prefix { !$0.isWhitespace }
        return UUID(uuidString: String(id)) != nil ? String(id) : nil
    }

    // MARK: Paths

    /// One dir per Synth process, reaped by `HookEnvironment` when a crashed instance's pid dies,
    /// with a subdir per session: the workspace `agy` is handed via `--add-dir` (its
    /// `.agents/hooks.json` is the whole instrumentation) plus the log this supervisor tails.
    static let root = "/tmp/synth-agy-\(getpid())"

    static func sessionDir(_ session: UUID) -> String { root + "/" + session.uuidString }
    static func logPath(_ session: UUID) -> String { sessionDir(session) + "/cli.log" }
}

/// Follows a text file that may not exist yet, handing over whole lines as they land.
///
/// Polled rather than watched: the file appears only once the agent launches, and a vnode source
/// needs a descriptor to watch, so it would have to be armed after the fact and re-armed whenever
/// the file is replaced — more moving parts than a quarter-second stat. A file that shrank was
/// replaced; rewind and read it from the top rather than sit past its end forever.
final class AntigravityLogTail: @unchecked Sendable {
    private let path: String
    private let onLine: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "synth.antigravity.log")
    private var timer: DispatchSourceTimer?
    private var offset: UInt64 = 0
    /// A poll can land mid-line; the remainder waits here for the rest of it.
    private var carry = Data()

    init(path: String, onLine: @escaping @Sendable (String) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return }
        if end < offset { offset = 0; carry.removeAll() }
        guard end > offset else { return }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        carry.append(data)
        while let newline = carry.firstIndex(of: 0x0A) {
            let line = Data(carry[carry.startIndex..<newline])
            carry.removeSubrange(carry.startIndex...newline)
            if let text = String(data: line, encoding: .utf8) { onLine(text) }
        }
    }
}
