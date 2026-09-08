import Foundation

/// Where errors are caught, so that almost nowhere else has to.
///
/// The first version of the spine asked every call site to describe its own failure. That does
/// not scale and it did not hold: the sweep found 151 silent failures precisely because a
/// per-site convention is a per-site decision, and most of them were decided by not deciding.
///
/// Work enters this app through a handful of doors — a bus event, a socket request, a user
/// gesture, a detached task, a subprocess — and everything else is called from one of them. So
/// the doors are guarded, and the rooms behind them are free to simply `throw`. A function that
/// can fail says `throws`; its caller says `try` and nothing else; the error travels up to the
/// door it came in through and is captured there with the context of where it actually happened.
///
/// The practical consequence, and the reason this shape is worth the change: **adding error
/// handling to new code costs zero lines**, and removing a `?` from a `try?` is a complete fix
/// rather than the start of one. The remaining `try?`s can be converted one at a time, by
/// deletion, with no matching call-site ceremony to write.
enum Guarded {

    // MARK: Doors

    /// A synchronous door — a bus event, a socket verb, a menu action. Returns nil if the body
    /// threw, so a caller that has a fallback can use one and a caller that doesn't can ignore it.
    @discardableResult
    static func run<T>(_ body: () throws -> T,
                       file: StaticString = #fileID, line: UInt = #line) -> T? {
        do { return try body() } catch { capture(error, file, line); return nil }
    }

    /// The async door. Replaces a bare `Task { }`, whose thrown errors are discarded by the
    /// language itself — 66 of those exist in this app and every one of them was a place a
    /// failure could vanish with no diagnostic anywhere.
    @discardableResult
    static func task(priority: TaskPriority? = nil,
                     file: StaticString = #fileID, line: UInt = #line,
                     _ body: @escaping @Sendable () async throws -> Void) -> Task<Void, Never> {
        Task(priority: priority) {
            do { try await body() } catch { capture(error, file, line) }
        }
    }

    /// The same door for work that must run on the main actor.
    @discardableResult
    static func mainTask(file: StaticString = #fileID, line: UInt = #line,
                         _ body: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            do { try await body() } catch { capture(error, file, line) }
        }
    }

    /// A detached thread — the socket accept loops. A thread whose body throws or returns
    /// early silently stops serving, which is indistinguishable from serving nothing.
    static func thread(file: StaticString = #fileID, line: UInt = #line,
                       _ body: @escaping @Sendable () throws -> Void) {
        Thread.detachNewThread {
            do { try body() } catch { capture(error, file, line) }
        }
    }

    // MARK: What a caught error becomes

    /// Turn any thrown value into a fault, inferring everything a call site used to spell out.
    /// A `Fault.Record` thrown from deeper down keeps its own domain, severity and copy — the
    /// door does not flatten a failure that already knows what it is.
    private static func capture(_ error: Error, _ file: StaticString, _ line: UInt) {
        if let record = error as? Fault.Record { return Fault.emitExisting(record) }
        guard let severity = severity(for: error) else { return }
        Fault.report(Fault.Domain.inferred(file), .uncaught, severity: severity,
                     details: [.posixErrno(posixCode(of: error) ?? 0)],
                     evidence: error.localizedDescription, file: file, line: line)
    }

    /// Nil means "not a failure": cancellation is how structured concurrency ends work on
    /// purpose, and counting it would bury the real faults under the app's own shutdown.
    private static func severity(for error: Error) -> Fault.Severity? {
        if error is CancellationError { return nil }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return nil }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError { return nil }
        return .degraded
    }

    private static func posixCode(of error: Error) -> Int32? {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain { return Int32(underlying.code) }
        return nil
    }
}

extension Fault.Domain {
    /// The domain a failure belongs to, from the file it happened in. This is the other half of
    /// "no ceremony at the call site": a `throw` carries its location for free, and a location
    /// is a better domain than one a developer picks under time pressure — it cannot drift from
    /// where the code actually lives, and it is never forgotten.
    ///
    /// A file nobody has classified lands in `.app`, which is the honest answer and still
    /// countable. Classify one only when its own breakdown starts mattering.
    static func inferred(_ fileID: StaticString) -> Fault.Domain {
        let base = ("\(fileID)" as NSString).lastPathComponent
        switch base {
        case "GhosttyApp.swift", "GhosttySurfaceView.swift", "GhosttySurfaceContext.swift",
             "TerminalTheme.swift", "AgentTheme.swift", "OpencodeTheme.swift":
            return .terminalEngine
        case "TerminalManager.swift", "ScratchTerminal.swift", "ShellEnvironment.swift",
             "MarkdownSession.swift":
            return .terminalSpawn
        case "Agents.swift", "AgentProbe.swift", "AgentCheck.swift", "AgentMarks.swift",
             "OpencodeSupervisor.swift", "Opencode2Supervisor.swift", "AntigravitySupervisor.swift":
            return .agentLaunch
        case "Hooks.swift":
            return .hook
        case "ControlServer.swift", "InstanceRegistry.swift", "MCPInstaller.swift",
             "Automation.swift":
            return .control
        case "Persistence.swift", "AppSupport.swift":
            return .persistence
        case "GitService.swift", "ArchiveSweeper.swift", "PRService.swift", "DiffStat.swift",
             "FolderSize.swift", "BranchHoverCard.swift":
            return .worktree
        case "BrowserPane.swift", "CEFEngine.swift", "CDPClient.swift", "BrowserCheck.swift",
             "BrowserEngine.swift", "BrowserEngineFactory.swift", "CommentMode.swift",
             "CommentDelivery.swift", "InspectPane.swift":
            return .browser
        case "CrashReporter.swift", "MachExceptionPorts.swift":
            return .crash
        default:
            return .app
        }
    }
}
