import AppKit
import Foundation
import os

/// Synth's single failure seam. Before this existed, a caught error had three possible
/// fates and two of them were silence: `NSLog` to a console no user reads, or nothing at
/// all. `Analytics.error` was written for the third and never called once.
///
/// Three things now happen to every fault, in this order:
///   1. it is written to the local log and the breadcrumb trail — synchronous, any thread,
///      on every channel including dev where analytics is silent (the fail-fast half);
///   2. it is counted in PostHog, buffered if analytics isn't live yet;
///   3. for the two loud severities only, it is said on screen through the notification
///      deck the app already has — no second toast system, no new tier, no new NotifKind.
///
/// THE REDACTION RULE, ENFORCED BY THE TYPE SYSTEM RATHER THAN BY DISCIPLINE:
///   • `details:` takes `[Detail]`, and `Detail` has no free-string case. Everything in it
///     is a number, a `StaticString` key you typed in source, or a closed enum. `details`
///     is the ONLY thing that reaches the wire — `wireProps` is the one function that
///     builds the PostHog dictionary and it takes `[Detail]`, not a `Record`.
///   • `evidence:` is free text — an errno sentence, git's `fatal:` line, a CDP message.
///     It reaches the user's card and the local log and nothing else. There is no code
///     path from `evidence` to PostHog, which is the only reason it may be a String.
/// So "is this safe to send?" is answered by which parameter it went into: if you could
/// interpolate it, it stayed on this machine.
enum Fault {

    /// The join key between a log line you grep and a dashboard row you click. Also the
    /// OSLog `category`, so `log stream --predicate 'category == "terminal.spawn"'` and
    /// PostHog's `domain` breakdown show the same population.
    enum Domain: String, Sendable, CaseIterable {
        case terminalEngine = "terminal.engine"   // ghostty_init / app_new / surface_new
        case terminalSpawn  = "terminal.spawn"    // launcher script, cwd, refused spawns
        case terminalExit   = "terminal.exit"     // deaths, codes, lifetimes
        case agentLaunch    = "agent.launch"      // the shim: not found, exec failed, serve dead
        case hook           = "hook"              // hook socket, ZDOTDIR, shims
        case control        = "control"           // control socket, instance registry, MCP
        case persistence    = "persistence"
        case worktree       = "worktree"
        case browser        = "browser"
        case crash          = "crash"
        /// Anything not yet worth its own breakdown. A door catches errors from files nobody
        /// has classified, and they are better counted here than not counted.
        case app            = "app"

        /// Every domain must name what a user reads, so adding one breaks this switch and
        /// forces the copy decision into the same diff as the failure.
        var headline: String {
            switch self {
            case .terminalEngine: return "The terminal engine didn't start"
            case .terminalSpawn:  return "Synth couldn't start the terminal"
            case .terminalExit:   return "This terminal closed as it opened"
            case .agentLaunch:    return "The agent couldn't start"
            case .hook:           return "Session tracking is off this run"
            case .control:        return "Agent tools are unavailable"
            case .persistence:    return "Synth can't save your workspaces"
            case .worktree:       return "That git operation didn't finish"
            case .browser:        return "The browser engine stopped"
            case .crash:          return "Synth recovered from a crash"
            case .app:            return "Something didn't work"
            }
        }
    }

    /// What happened. `(domain, code)` is the dashboard's primary key, so a code is added
    /// the way a migration is: deliberately, and never renamed once shipped.
    enum Code: String, Sendable {
        // terminal.engine
        case engineInitFailed            = "engine_init_failed"
        case engineAppNewFailed          = "engine_app_new_failed"
        case engineUnavailable           = "engine_unavailable"
        case surfaceNewFailed            = "surface_new_failed"
        // terminal.spawn
        case launcherScriptUnwritable    = "launcher_script_unwritable"
        case spawnRefusedNoBranch        = "spawn_refused_no_branch"
        case shellNotExecutable          = "shell_not_executable"
        case markdownRuntimeMissing      = "markdown_runtime_missing"
        case noPrompt                    = "no_prompt"
        // terminal.exit
        case instantDeath                = "instant_death"        // died before it could say why
        case exitedNonZero               = "exited_nonzero"
        // agent.launch — all three arrive from the shim over the hook socket
        case agentBinaryMissing          = "agent_binary_missing" // shim exit 127
        case agentExecFailed             = "agent_exec_failed"    // shim exit 126
        case agentServeNeverCameUp       = "agent_serve_never_came_up"
        // hook / control
        case hookSocketBindFailed        = "hook_socket_bind_failed"
        case hookEnvWriteFailed          = "hook_env_write_failed"
        case controlSocketBindFailed     = "control_socket_bind_failed"
        // persistence
        case supportDirUnwritable        = "support_dir_unwritable"
        case loadUnreadable              = "load_unreadable"
        case loadUndecodable             = "load_undecodable"
        case writeFailed                 = "write_failed"
        // browser / worktree — the sites that already tell the user, now countable too
        case worktreeOpFailed            = "worktree_op_failed"
        case gitCommandFailed            = "git_command_failed"
        case gitSpawnFailed              = "git_spawn_failed"
        case browserEngineUnavailable    = "browser_engine_unavailable"
        // crash spine
        case crashCaptureUnavailable     = "crash_capture_unavailable"
        /// An error that reached a door without anyone naming it — the default, and the one
        /// that should be most common. `site` says where; the evidence line says what.
        case uncaught                    = "uncaught"
        // Capability lifecycle — the first three are breadcrumbs, never events of their own.
        case healing                     = "healing"
        case healFailed                  = "heal_failed"
        case healed                      = "healed"
        case capabilityDown              = "capability_down"
        /// A session's whole process tree being signalled. Recorded because this is the most
        /// destructive thing the app does routinely and it did it with no record at all: the
        /// group is computed from a pid read before the surface was freed, and if that group is
        /// ever not ours, every process in somebody else's tree dies with no trace on either side.
        case reapedProcessGroup          = "reaped_process_group"

        /// The boundary parse for a slug arriving from another process (synth-hook, over the
        /// hook socket). Unknown slugs are dropped rather than forwarded as free text.
        init?(wire: String) { self.init(rawValue: wire) }

        var defaultSeverity: Severity {
            switch self {
            case .engineInitFailed, .engineAppNewFailed, .launcherScriptUnwritable,
                 .supportDirUnwritable, .writeFailed, .hookSocketBindFailed,
                 .loadUnreadable, .loadUndecodable:
                return .blocked
            case .surfaceNewFailed, .engineUnavailable, .instantDeath, .agentBinaryMissing,
                 .agentExecFailed, .agentServeNeverCameUp, .spawnRefusedNoBranch,
                 .shellNotExecutable, .markdownRuntimeMissing, .capabilityDown:
                return .failed
            default:
                return .degraded
            }
        }
    }

    /// Decides the surface, and nothing else.
    enum Severity: String, Sendable, Comparable {
        /// Breadcrumb. Never its own event, never on screen. Joins the trail so the NEXT
        /// fault — and the next crash — says what led here. Free to call in a loop.
        case note
        /// Something got worse; the user's action still worked, or they didn't take one.
        /// Log + telemetry. Silent on stable, a card on dev.
        case degraded
        /// The thing the user just asked for did not happen. Plus an ambient card — or
        /// `.error` on the row, when a session owns it.
        case failed
        /// A capability is gone for the run. Plus a sticky attention card, and Notification
        /// Center when Synth isn't frontmost.
        case blocked

        static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
        private var rank: Int {
            switch self { case .note: return 0; case .degraded: return 1
                          case .failed: return 2; case .blocked: return 3 }
        }
        /// Dev sends nothing, so the screen floor rises instead: what production counts
        /// silently, the author sees.
        var raisedForDev: Severity { self == .degraded ? .failed : self }
    }

    /// Everything that may reach the wire. There is deliberately no `case text(String)`.
    enum Detail: Sendable {
        case exitCode(Int32)
        case posixErrno(Int32)          // the number; strerror's sentence stays local
        case msAlive(Int)
        case attempt(Int)
        case count(StaticString, Int)   // key is a literal you typed; value is a number
        case flag(StaticString, Bool)
        case sessionKind(SessionKind)
        case codeSource(CodeSource)     // the fact `?? 0` used to destroy
        case stage(Stage)

        enum CodeSource: String, Sendable { case hook, pty, none }
        enum Stage: String, Sendable { case resolve, write, spawn, exec, handshake, ready, teardown }
    }

    /// The words, when a fault is allowed to speak. Required by `surface`, so nothing
    /// reaches the screen without a sentence someone wrote for it.
    struct Copy: Sendable {
        var title: String        // a verb, not a code: "Couldn't start the terminal"
        var retry: Retry = .none
    }

    /// A retry is a named action the store performs, not a closure — closures crossing
    /// actor boundaries are exactly the mess this spine exists to remove.
    enum Retry: Sendable, Equatable {
        case none
        case respawnSession(UUID)
        case restartSynth
    }

    /// An `Error`, so PostHog's `captureException` takes it and turns it into a real
    /// Error-Tracking issue. `CustomNSError` is what makes the grouping ours: the fingerprint
    /// comes from `synth` + our own `domain/code`, not from a `localizedDescription` that
    /// would scatter one failure across a dozen issues (and could carry a path).
    struct Record: Sendable, Error, CustomNSError, LocalizedError {
        let domain: Domain
        let code: Code
        let severity: Severity
        let session: UUID?
        let details: [Detail]
        let evidence: String?      // LOCAL ONLY — never reaches wireProps
        let copy: Copy?
        let site: String           // "GhosttySurfaceView.swift:257" — our source, wire-safe

        /// What PostHog puts on the issue. Without it the title is NSError's
        /// "The operation couldn't be completed. (synth error 64319.)" — the same sentence for
        /// every failure in the app. A `domain/code` pair is closed vocabulary, so this is the
        /// one place a string reaches the wire and it is still one we typed in source.
        var errorDescription: String? { "\(domain.rawValue)/\(code.rawValue)" }

        static var errorDomain: String { "synth" }
        var errorCode: Int { abs(code.rawValue.hashValue % 100_000) }
        var errorUserInfo: [String: Any] {
            var p = Fault.wireProps(details)
            p["domain"] = domain.rawValue
            p["code"] = code.rawValue
            p["severity"] = severity.rawValue
            p["site"] = site
            // NOT `evidence`. It is the reason this type can hold a String at all.
            return p
        }
    }
}

// MARK: - The three entry points

/// All `nonisolated`: a fault is raised from a libghostty C callback, a detached socket
/// thread and the main actor alike, and a seam you cannot call from where the failure
/// happened is a seam nobody calls.
extension Fault {

    /// Breadcrumb. One ring write and one log line. No event, no screen — so it is free to
    /// call on a hot path, and free to carry the numbers that make the line worth reading.
    nonisolated static func note(_ domain: Domain, _ code: Code, _ details: [Detail] = [],
                                 evidence: @autoclosure @Sendable () -> String? = nil) {
        trail.append("\(domain.rawValue)/\(code.rawValue)")
        let wire = wireProps(details).map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        let local = evidence() ?? ""
        logger(domain).notice("· \(code.rawValue, privacy: .public) \(wire, privacy: .public) \(local, privacy: .private)")
    }

    /// Telemetry + log, nothing on screen. The default rung: "we must be able to count this."
    nonisolated static func report(_ domain: Domain, _ code: Code,
                                   severity: Severity? = nil,
                                   session: UUID? = nil,
                                   details: [Detail] = [],
                                   evidence: @autoclosure @Sendable () -> String? = nil,
                                   file: StaticString = #fileID, line: UInt = #line) {
        emit(Record(domain: domain, code: code, severity: severity ?? code.defaultSeverity,
                    session: session, details: details, evidence: evidence(), copy: nil,
                    site: site(file, line)))
    }

    /// Telemetry + log + the deck. `say:` is not optional: if it shows, it says something.
    nonisolated static func surface(_ domain: Domain, _ code: Code,
                                    severity: Severity? = nil,
                                    session: UUID? = nil,
                                    say copy: Copy,
                                    details: [Detail] = [],
                                    evidence: @autoclosure @Sendable () -> String? = nil,
                                    file: StaticString = #fileID, line: UInt = #line) {
        let sev = severity ?? code.defaultSeverity
        emit(Record(domain: domain, code: code, severity: max(sev, .failed), session: session,
                    details: details, evidence: evidence(), copy: copy, site: site(file, line)))
    }

    /// Re-emit a record built earlier (a `Fallible` failure carried across a return).
    nonisolated static func emitExisting(_ r: Record) { emit(r) }

    /// Installed once, at the end of `AppStore.init`. Weak — the spine never keeps the app alive.
    @MainActor static func attach(_ store: AppStore) { presenter = store }

    /// Called by `Analytics.bootstrap` the moment it goes live, to flush faults raised during
    /// store construction. This is why the spine does not depend on launch ordering — and why
    /// `Analytics.bootstrap` did NOT have to move ahead of `GhosttyApp.start()`, which
    /// SynthApp.swift documents as load-bearing for the Mach-ports handoff.
    @MainActor static func telemetryDidGoLive() { Analytics.flushBuffered() }

    /// The last breadcrumbs, oldest first — attached to every fault event and to `app_crashed`.
    nonisolated static func recentTrail(_ limit: Int = 12) -> [String] { trail.recent(limit) }

    /// The previous run's trail, for the crash report that outlived the process.
    static func previousRunTrail() -> [String] { FaultTrail.previousRun(trailURL) }

    /// What a driven build recorded, so a headless gate can assert that opening a terminal
    /// with an unwritable launcher produced `terminal.exit/instant_death` — the shape
    /// `NotificationService.captured` already gives the notification gate.
    @MainActor private(set) static var captured: [(domain: String, code: String, site: String)] = []
}

// MARK: - Internals

extension Fault {
    private struct Key: Hashable { let domain: Domain; let code: Code; let session: UUID? }

    private static let trailURL = AppSupport.dir("crash").appendingPathComponent("trail")
    private static let trail = FaultTrail(capacity: 64, url: trailURL)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var seen: [Key: (last: Date, count: Int)] = [:]
    private nonisolated(unsafe) static var shownAt: [String: Date] = [:]
    private nonisolated(unsafe) static var sentBudget = 200
    @MainActor private static weak var presenter: AppStore?

    /// The hard fail-fast, for gates and tests: a swallowed failure cannot pass a run.
    private static var strict: Bool {
        ProcessInfo.processInfo.environment["SYNTH_FAULT_STRICT"] == "1"
    }

    private static func site(_ file: StaticString, _ line: UInt) -> String {
        "\((("\(file)") as NSString).lastPathComponent):\(line)"
    }

    private static func logger(_ d: Domain) -> Logger {
        Logger(subsystem: bundleIdentifier, category: d.rawValue)
    }

    private static func emit(_ r: Record) {
        // 1. LOCAL, SYNCHRONOUS, EVERY CHANNEL. Never depends on analytics, on a window,
        //    or on the main actor being free — this is the half that must work in dev,
        //    where nothing is ever sent.
        trail.append("\(r.domain.rawValue)/\(r.code.rawValue)")
        let wire = wireProps(r.details).map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        logger(r.domain).error("""
            \(r.code.rawValue, privacy: .public) \(wire, privacy: .public) \
            \(r.site, privacy: .public) \(r.evidence ?? "", privacy: .private)
            """)
        if isDevChannel {
            FileHandle.standardError.write(Data(
                "⚠︎ \(r.domain.rawValue)/\(r.code.rawValue) \(r.site) \(r.evidence ?? "")\n".utf8))
        }
        if strict, r.severity >= .failed {
            fatalError("Fault \(r.domain.rawValue)/\(r.code.rawValue) at \(r.site): \(r.evidence ?? "")")
        }

        guard r.severity > .note, let admitted = throttled(r) else { return }
        let record = r
        Task { @MainActor in deliver(record, repeats: admitted) }
    }

    /// Identical `(domain, code, session)` sends at most once a minute, carrying `repeats`
    /// for what it stands for — so a 4Hz readiness poll can neither mint 14k events nor
    /// collapse into one event that hides its own frequency. Returns the repeat count the
    /// admitted event speaks for, or nil when this one is folded into a pending window.
    private static func throttled(_ r: Record) -> Int? {
        let key = Key(domain: r.domain, code: r.code, session: r.session)
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        guard sentBudget > 0 else { return nil }
        if let prior = seen[key], now.timeIntervalSince(prior.last) < 60 {
            seen[key] = (prior.last, prior.count + 1)
            return nil
        }
        let folded = seen[key]?.count ?? 0
        seen[key] = (now, 0)
        sentBudget -= 1
        return folded
    }

    @MainActor private static func deliver(_ r: Record, repeats: Int) {
        captured.append((r.domain.rawValue, r.code.rawValue, r.site))
        // Dev sends nothing, so raise the screen floor instead: what is invisible in
        // production is a card on the author's machine.
        let effective = isDevChannel ? r.severity.raisedForDev : r.severity
        let shown = effective >= .failed && r.copy != nil && admitToScreen(r)
        Analytics.fault(r, repeats: repeats, surfaced: shown)
        guard shown else { return }
        presenter?.present(r, severity: effective, repeats: repeats)
    }

    /// One card per `(domain, code)` per ten minutes — except a fault a session owns, which
    /// lands on its own row rather than in the deck. Ten terminals dying in a row IS the
    /// report; the user must see ten rows go red, not one card standing for all of them.
    @MainActor private static func admitToScreen(_ r: Record) -> Bool {
        guard r.session == nil else { return true }
        let key = "\(r.domain.rawValue)/\(r.code.rawValue)"
        let now = Date()
        if let last = shownAt[key], now.timeIntervalSince(last) < 600 { return false }
        shownAt[key] = now
        return true
    }

    /// PII cannot reach here: this takes `[Detail]`, not a `Record`, so `evidence` is out of
    /// scope by construction rather than by review.
    static func wireProps(_ details: [Detail]) -> [String: Any] {
        var out: [String: Any] = [:]
        for d in details {
            switch d {
            case .exitCode(let c):     out["exit_code"] = Int(c)
            case .posixErrno(let e):   out["errno"] = Int(e)
            case .msAlive(let ms):     out["ms_alive"] = ms; out["ms_alive_bucket"] = bucket(ms)
            case .attempt(let n):      out["attempt"] = n
            case .count(let k, let n): out["\(k)"] = n
            case .flag(let k, let v):  out["\(k)"] = v
            case .sessionKind(let k):  out["session_kind"] = k.analyticsSlug
            case .codeSource(let s):   out["code_source"] = s.rawValue
            case .stage(let s):        out["stage"] = s.rawValue
            }
        }
        return out
    }

    private static func bucket(_ ms: Int) -> String {
        switch ms {
        case ..<1_000: return "<1s"
        case ..<5_000: return "<5s"
        case ..<60_000: return "<60s"
        case ..<3_600_000: return "<1h"
        default: return "1h+"
        }
    }
}

/// A session kind as the wire may see it. A custom agent's id is minted from the user's own
/// command, so it is a name, not a category — it reports as "custom".
extension SessionKind {
    var analyticsSlug: String {
        if let agent = agentID { return agent.isCustom ? "custom" : agent.rawValue }
        return rawValue
    }
}

// MARK: - Fallible

/// A seam that can refuse. `Result` is not `@discardableResult`, so *dropping one is a
/// compiler warning at the call site* — which is the whole regression story: a future
/// contributor cannot reintroduce a silent swallow on an instrumented path without the
/// build saying so. Used on the terminal-spawn seams only; everything else keeps its shape.
typealias Fallible<T> = Result<T, Fault.Record>

extension Result where Failure == Fault.Record {
    /// The only sanctioned way to discard a failure: it is reported first, and every
    /// deliberate drop in the codebase is one `grep -rn "\.reported()"` away.
    @discardableResult func reported() -> Success? {
        switch self {
        case .success(let v): return v
        case .failure(let r): Fault.emitExisting(r); return nil
        }
    }

    var failure: Fault.Record? {
        if case .failure(let r) = self { return r }
        return nil
    }
}
