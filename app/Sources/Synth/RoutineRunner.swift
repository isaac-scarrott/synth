import AppKit

// The engine half of Routines (docs/features/2026-09-23.md): the in-process scheduler, catch-up,
// the one-deep queue, and a run itself — a quiet branch cut, a headless agent spawn and a seeded
// prompt. Everything a caller can do to a routine still enters through Routines.swift's API;
// this file is what happens after `fireRoutine`.
//
// A run never takes the pane, the focus, the sidebar cursor, the open session or a keystroke.
// Rows appear in the tree (pending, then ready) and that is all anyone sees until the agent
// finishes and the ordinary background routing marks it unread. Anything a person is holding —
// the open session, a pane, the row under the cursor — a run leaves exactly where it is.

/// A start that couldn't happen, in words for the run's history and the one card it raises.
private struct RoutineDidNotStart: Error {
    let reason: String
    /// False when the user's own gesture ended it — a new Test replacing one still booting.
    /// Recorded, but no card and no dot for something they just did.
    var speaks = true
    /// Set when the cause is a real fault rather than an expected state; the run's door counts it.
    var fault: Fault.Record?
}

extension AppStore {
    /// Fire a routine now. Every trigger — the scheduler, catch-up, Run now, Test, and a future
    /// synth-app verb — enters here. While a run of it is busy, anything but a Test waits: at
    /// most one run waits per routine, and a later firing moves it to the latest slot rather
    /// than stacking a second.
    func fireRoutine(_ id: UUID, trigger: RoutineTrigger, slot: Date? = nil) {
        guard let r = routine(id) else { return }
        let now = Date()
        if trigger != .test, r.runs.contains(where: isBusy) {
            queueRoutineRun(id, trigger: trigger, slot: slot, at: now)
            return
        }
        startRoutineRun(id, trigger: trigger, slot: slot, at: now)
    }

    /// Start whatever is waiting behind a run that has settled. Called when a session leaves
    /// busy, when a start finishes (either way), and on every scheduler tick as a backstop.
    func drainRoutineQueues() {
        for r in routines {
            guard let q = r.runs.first(where: { $0.outcome == .queued }),
                  !r.runs.contains(where: isBusy) else { continue }
            editRoutine(r.id) { $0.runs.removeAll { $0.id == q.id } }
            startRoutineRun(r.id, trigger: q.trigger, slot: q.slot, at: Date())
        }
    }

    // MARK: Queue and record

    private func queueRoutineRun(_ id: UUID, trigger: RoutineTrigger, slot: Date?, at: Date) {
        editRoutine(id) { r in
            if let i = r.runs.firstIndex(where: { $0.outcome == .queued }) {
                r.runs[i].firedAt = at
                r.runs[i].slot = slot
                r.runs[i].trigger = trigger
            } else {
                r.runs.insert(RoutineRun(firedAt: at, slot: slot, trigger: trigger, outcome: .queued,
                                         reason: "Waiting for the run before it to finish."), at: 0)
            }
            Self.account(slot, trigger: trigger, in: &r)
        }
    }

    /// Mutate a routine in place, trimming its history. A no-op once the routine is deleted —
    /// a run already under way carries on, it just has nowhere left to be written down.
    private func editRoutine(_ id: UUID, _ change: (inout Routine) -> Void) {
        guard let i = routines.firstIndex(where: { $0.id == id }) else { return }
        change(&routines[i])
        if routines[i].runs.count > Routine.historyLimit {
            routines[i].runs.removeLast(routines[i].runs.count - Routine.historyLimit)
        }
    }

    private func editRun(_ routineID: UUID, _ runID: UUID, _ change: (inout RoutineRun) -> Void) {
        editRoutine(routineID) { r in
            guard let i = r.runs.firstIndex(where: { $0.id == runID }) else { return }
            change(&r.runs[i])
        }
    }

    /// A firing has accounted for its slot, whatever it goes on to do. Any run of a Once but a
    /// Test uses it up — Run now included — so it reads "Ran" and never fires again.
    private static func account(_ slot: Date?, trigger: RoutineTrigger, in r: inout Routine) {
        var at = trigger == .schedule || trigger == .catchUp ? slot : nil
        if trigger != .test, let once = r.schedule.onceSlot() { at = max(at ?? once, once) }
        guard let at else { return }
        r.lastSlot = max(r.lastSlot ?? at, at)
    }

    /// The form a routine takes on disk. A start still in flight is written down as what it
    /// becomes if Synth quits now — a start cut off before the agent took the text is history,
    /// never a card — and the next save, once it lands, writes what it really became.
    func persistedRoutine(_ r: Routine) -> Routine {
        var r = r
        for i in r.runs.indices where routineRunsPending.contains(r.runs[i].id) {
            r.runs[i].outcome = .failed
            r.runs[i].reason = "Synth quit before the agent took the text."
        }
        return r
    }

    // MARK: A run

    /// A new-each-run branch is stamped to the minute, so two runs in the same minute (Run now
    /// twice, a catch-up beside a Run now) would land on one branch. The second gets `-2`, `-3`….
    private func freshBranchName(_ r: Routine, trigger: RoutineTrigger, at: Date) -> String {
        let name = r.branchName(for: trigger, at: at)
        guard trigger != .test, r.target == .fresh,
              let ws = workspaces.first(where: { $0.id == r.workspaceID }) else { return name }
        let taken = Set(ws.branches.map(\.name))
        var candidate = name, n = 2
        while taken.contains(candidate) { candidate = "\(name)-\(n)"; n += 1 }
        return candidate
    }

    private func startRoutineRun(_ id: UUID, trigger: RoutineTrigger, slot: Date?, at: Date) {
        guard let r = routine(id) else { return }
        let project = workspaces.first { $0.id == r.workspaceID }?.name ?? "Its project"
        let run = RoutineRun(firedAt: at, slot: slot, trigger: trigger, outcome: .started,
                             branch: freshBranchName(r, trigger: trigger, at: at))
        editRoutine(id) { r in
            r.runs.insert(run, at: 0)
            Self.account(slot, trigger: trigger, in: &r)
        }
        routineRunsPending.insert(run.id)
        Analytics.capture("routine_fired", [
            "trigger": trigger.rawValue,
            "target": r.target.kind,
            "agent": r.agent.isCustom ? "custom" : r.agent.rawValue,
        ])
        Guarded.mainTask { [weak self] in
            guard let self else { return }
            defer {
                self.routineRunsPending.remove(run.id)
                self.saveNow()
                self.drainRoutineQueues()
            }
            do {
                try await self.carryOut(r, run: run, project: project)
            } catch let failure as RoutineDidNotStart {
                self.failRoutineRun(r, runID: run.id, reason: failure.reason, speaks: failure.speaks)
                if let fault = failure.fault { throw fault }
            } catch {
                // Anything else is a fault the door counts; the run still has to say it didn't start.
                self.failRoutineRun(r, runID: run.id, reason: error.localizedDescription, speaks: true)
                throw error
            }
        }
    }

    /// Branch, session, prompt. `r` is the routine as it stood when it fired — an edit made
    /// mid-start applies from the next run, and a delete mid-start lets this one finish.
    private func carryOut(_ r: Routine, run: RoutineRun, project: String) async throws {
        guard let ws = workspaces.first(where: { $0.id == r.workspaceID }) else {
            throw RoutineDidNotStart(reason: "\(project) is no longer in Synth.")
        }
        let agentName = AgentRegistry.descriptor(r.agent)?.displayName ?? "The agent"
        guard availableAgents.contains(where: { $0.id == r.agent }) else {
            throw RoutineDidNotStart(reason: AgentRegistry.installed.contains { $0.id == r.agent }
                ? "\(agentName) is switched off in Settings."
                : "\(agentName) isn't available on this Mac.")
        }
        let test = run.trigger == .test
        let mark = RoutineMark(name: r.name, firedAt: run.firedAt, test: test)
        let (row, note) = try await routineBranch(r, run: run, mark: mark, in: ws)
        editRun(r.id, run.id) { $0.branch = row.name; if let note { $0.reason = note } }

        // Claude Code and Antigravity stop a folder they have never seen at a trust prompt no one
        // is there to answer. A folder Synth cut for this routine inherits the repo's trust — only
        // if the user already gave it. An existing branch's folder is theirs, and stays as they left it.
        let cutHere = test || r.target == .same || r.target == .fresh
        let trust = trustKept(by: r.agent)
        if let trust, cutHere { try trust.inherit(row.worktreeURL, from: ws.url) }
        let stalled = trust.flatMap { trust in
            trust.isTrusted(ws.url) ? nil
                : "\(ws.name) isn't trusted in \(trust.agentName) yet, so it stopped at the trust prompt. "
                  + "Open \(trust.agentName) in \(ws.name) once, accept the prompt, then run it again."
        }

        if !test, r.target != .fresh { closeSettledRun(of: r, on: row) }

        // Idle until it has its prompt: a spawn row starts `.working`, and the agent's own
        // start signal settling it to idle would read as "done" before anything was asked.
        guard let session = spawnAgent(r.agent, in: row) else {
            throw RoutineDidNotStart(reason: "\(row.name) was still being set up.")
        }
        session.status = .idle
        session.title = r.name
        session.titleIsCustom = true
        session.routineMark = mark
        editRun(r.id, run.id) { $0.sessionID = session.id }

        let flags = [agentFlags(r.agent, for: ws), r.extraFlags.trimmingCharacters(in: .whitespaces)]
            .filter { !$0.isEmpty }.joined(separator: " ")
        if case .failure(let fault) = TerminalManager.shared.boot(session, cwd: row.worktreeURL, agentFlags: flags) {
            closeSession(session)
            throw RoutineDidNotStart(reason: "Its terminal couldn't start.", fault: fault)
        }
        try await seed(session, of: r.id, run: run, on: row,
                       with: Self.seedText(r, run: run, branch: row.name), agentName: agentName,
                       stalled: stalled)
    }

    /// Hand the prompt over. SECURITY (CommentMode): only ever to a supervisor-confirmed-live
    /// agent — one that never started leaves a bare shell, and Claude Code's delivery is a paste
    /// plus Enter, i.e. arbitrary execution. Nobody is waiting on a routine, so it waits longer
    /// than `seedAgent` does, and gives up at once on a session that has already ended.
    private func seed(_ session: Session, of routineID: UUID, run: RoutineRun, on row: Branch,
                      with text: String, agentName: String, stalled: String?) async throws {
        let seconds = ProcessInfo.processInfo.environment["SYNTH_ROUTINE_SEED_SECONDS"]
            .flatMap(Double.init) ?? 60
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(0.5))
            guard let live = self.session(session.id) else {
                let replaced = routine(routineID)?.runs.contains { $0.trigger == .test && $0.firedAt > run.firedAt }
                if run.trigger == .test, replaced == true {
                    throw RoutineDidNotStart(reason: "A newer Test replaced it before the agent took the text.",
                                             speaks: false)
                }
                throw RoutineDidNotStart(reason: "\(agentName) quit before it took the text.")
            }
            if case .exited = live.status {
                throw RoutineDidNotStart(reason: "\(agentName) quit before it took the text.")
            }
            if live.status == .error {
                throw RoutineDidNotStart(reason: "\(agentName) stopped with an error before it took the text.")
            }
            guard isLiveAgent(session.id) else { continue }
            try await Task.sleep(for: .seconds(1))
            guard isLiveAgent(session.id), let supervisor = liveSupervisor(for: session) else { continue }
            if supervisor.deliver(text, to: session.id) {
                // Busy from the hand-over, not from the agent's first hook a beat later — the
                // gap is exactly where a queued run would otherwise slip in.
                session.status = .working
                return
            }
        }
        // A folder the agent hasn't been told to trust is an expected stop, said in history
        // only; an agent that never came up anywhere else is a fault worth counting.
        if let stalled { throw RoutineDidNotStart(reason: stalled) }
        Fault.report(.agentLaunch, .agentDeliveryNeverTaken, severity: .degraded, session: session.id,
                     details: [.stage(.ready)], evidence: "A routine's agent never reported itself live.")
        throw RoutineDidNotStart(reason: "The agent never took the text — \(agentName) didn't come up in time.")
    }

    /// The trust list `agent` stops at: its own, or its base's for a command of the user's that
    /// a built-in's supervisor hosts. Nil for an agent that asks nothing of a new folder.
    private func trustKept(by agent: AgentID) -> AgentTrust? {
        switch customAgents.first(where: { $0.agentID == agent })?.base ?? agent {
        case .claudeCode: .claude
        case .antigravity: .antigravity
        default: nil
        }
    }

    /// `[Synth routine "Name" — scheduled for 09:00, started 09:04 on routine/foo. …]`, then the
    /// prompt. The scheduled-vs-actual pair is the part that matters on a catch-up.
    static func seedText(_ r: Routine, run: RoutineRun, branch: String) -> String {
        let cal = Calendar.current
        func time(_ d: Date, dayToo: Bool) -> String {
            dayToo ? RoutineWords.dayAndTime(d) : RoutineWords.time(d)
        }
        let when: String
        switch run.trigger {
        case .schedule, .catchUp:
            if let slot = run.slot {
                let dayToo = !cal.isDate(slot, inSameDayAs: run.firedAt)
                when = "scheduled for \(time(slot, dayToo: dayToo)), started \(time(run.firedAt, dayToo: dayToo))"
            } else {
                when = "started \(time(run.firedAt, dayToo: false))"
            }
        case .runNow: when = "run by hand at \(time(run.firedAt, dayToo: false))"
        case .test: when = "test run, started \(time(run.firedAt, dayToo: false))"
        }
        return "[Synth routine \"\(r.name)\" — \(when) on \(branch). Nobody is watching; finish on your own.]\n\n"
            + r.prompt
    }

    /// Whether a person is holding this session: it is open, in a pane (on screen or in a
    /// branch's remembered split), or under the sidebar cursor. A run never touches one.
    private func heldByUser(_ sessionID: UUID) -> Bool {
        openSessionID == sessionID || navCursor == sessionID || leaf(of: sessionID) != nil || inSplit(sessionID)
    }

    private func heldByUser(_ branch: Branch) -> Bool {
        cursorInside(.branch(branch)) || openSetupBranchID == branch.id
            || branch.sessions.contains { heldByUser($0.id) }
    }

    /// Every run is a new session. On a branch the routine reuses, the last run's session goes
    /// first — only once it's idle, read and nobody is holding it, so nothing unseen is lost.
    /// The cursor on the branch row holds it too: in tabs mode that row is all the tree shows.
    private func closeSettledRun(of r: Routine, on row: Branch) {
        guard navCursor != row.id else { return }
        for past in routine(r.id)?.runs ?? [] {
            guard let id = past.sessionID, let s = session(id), branch(of: s)?.id == row.id,
                  !s.status.isBusy, s.status != .needsInput, !s.unread, !heldByUser(id) else { continue }
            closeSession(s)
        }
    }

    /// A Test's worktree is throwaway: once its last session is closed, the branch archives
    /// quietly — restorable from ⌘K → Archived like any other archive.
    func archiveClosedTest(_ branch: Branch) {
        guard branch.routineMark?.test == true, branch.sessions.isEmpty, !branch.isArchived,
              !branch.isPending, workspace(of: branch) != nil else { return }
        archiveBranchQuietly(branch)
    }

    // MARK: The branch

    /// The ready row this run lands on, and a note for its history (a fetch that failed).
    private func routineBranch(_ r: Routine, run: RoutineRun, mark: RoutineMark,
                               in ws: Workspace) async throws -> (Branch, String?) {
        let name = run.branch ?? r.branchName(for: run.trigger, at: run.firedAt)
        if run.trigger == .test {
            let fresh = try await retireTestBranch(name, in: ws)
            return try await cutRoutineBranch(fresh, base: r.base, mark: mark, in: ws)
        }
        switch r.target {
        case .existing:
            guard let row = ws.branches.first(where: { $0.name == name && !$0.isArchived }) else {
                throw RoutineDidNotStart(reason: "\(name) isn't a branch in \(ws.name) any more.")
            }
            try await waitReady(row, name: name)
            return (row, nil)
        case .same, .fresh:
            if let row = ws.branches.first(where: { $0.name == name && !$0.isArchived }) {
                try await waitReady(row, name: name)
                return (row, nil)
            }
            if let row = ws.branches.first(where: { $0.name == name && $0.isArchived }) {
                return try await reviveRoutineBranch(row, base: r.base, in: ws)
            }
            return try await cutRoutineBranch(name, base: r.base, mark: mark, in: ws)
        }
    }

    /// A row that is still materialising — cut by an earlier run.
    private func waitReady(_ row: Branch, name: String) async throws {
        let deadline = Date().addingTimeInterval(180)
        while row.isPending, Date() < deadline { try await Task.sleep(for: .seconds(0.25)) }
        guard !row.isPending, workspace(of: row) != nil else {
            throw RoutineDidNotStart(reason: "\(name) couldn't be checked out.")
        }
    }

    /// Cut `name` into a worktree WITHOUT the setup skeleton or the session template: the create
    /// flows move the pane because a person just asked for a worktree, and a routine asked for
    /// nothing. The row lands pending in the tree and the pane, cursor and focus stay put; a cut
    /// that fails takes its row back out and becomes the run's one "didn't start" reason.
    private func cutRoutineBranch(_ name: String, base: String?, mark: RoutineMark,
                                  in ws: Workspace) async throws -> (Branch, String?) {
        let repo = ws.url
        let planned = GitService.plannedWorktreePath(repo: repo, branch: name)
        let row = Branch(name: name, worktreeURL: planned, isPending: true, routineMark: mark)
        ws.branches.append(row)
        expanded.insert(ws.id)
        let cut = await runGit(repo: repo) { Self.cutWorktree(repo: repo, name: name, base: base, path: planned) }
        if let error = cut.error {
            // The cursor stays wherever it is — unless it went onto this row, which then hands
            // it to the project (`removeBranch`).
            removeBranch(row, deleteWorktree: false)
            throw RoutineDidNotStart(reason: "Couldn't create its worktree: \(Self.gitReason(error))")
        }
        row.worktreeURL = cut.path
        row.isPending = false
        row.markActivity()
        saveNow()
        return (row, cut.note)
    }

    /// The same-each-run branch archived by hand comes back for its next run, so its history and
    /// its row stay one — quietly: the row returns to the tree, checked out again if the clean-up
    /// took its folder, and nothing else moves. (`restoreArchivedBranch` is the person's path; its
    /// failure offers a Retry that opens the setup skeleton.)
    private func reviveRoutineBranch(_ row: Branch, base: String?,
                                     in ws: Workspace) async throws -> (Branch, String?) {
        let archivedAt = row.archivedAt
        let repo = ws.url, name = row.name, path = row.worktreeURL
        row.archivedAt = nil
        row.isPending = true
        let cut = await runGit(repo: repo) { () -> (path: URL, error: String?, note: String?) in
            if FileManager.default.fileExists(atPath: path.path) { return (path, nil, nil) }
            return Self.cutWorktree(repo: repo, name: name, base: base, path: path)
        }
        row.isPending = false
        if let error = cut.error {
            if cursorInside(.branch(row)) { navCursor = ws.id }
            row.archivedAt = archivedAt
            throw RoutineDidNotStart(reason: "Couldn't check out \(name) again: \(Self.gitReason(error))")
        }
        row.worktreeURL = cut.path
        row.markActivity()
        saveNow()
        return (row, cut.note)
    }

    /// The git half of a cut, off the main thread. An existing branch (a same-each-run branch
    /// whose row went) is checked out as it is; a new one is cut from Base after a fetch — and
    /// if the fetch fails, from the local base, because for an unattended job a stale start
    /// beats no start.
    private nonisolated static func cutWorktree(repo: URL, name: String, base: String?,
                                                path: URL) -> (path: URL, error: String?, note: String?) {
        if let wt = GitService.liveWorktree(repo: repo, branch: name) { return (wt.path, nil, nil) }
        let path = freePath(path)
        if GitService.branchExists(name, at: repo) {
            return (path, GitService.addWorktree(repo: repo, path: path, branch: name), nil)
        }
        let baseRef = routineBase(base, repo: repo)
        var from = baseRef
        var note: String?
        let remotes = GitService.remotes(at: repo).value ?? []
        if !remotes.isEmpty {
            let named = remotes.first { baseRef.hasPrefix($0 + "/") }
            let remote = named ?? (remotes.contains("origin") ? "origin" : remotes[0])
            if GitService.fetch(remote, at: repo) {
                // A bare "main" means the shared one once it's fresh.
                if named == nil, let fresh = GitService.resolvableRef([baseRef], at: repo) { from = fresh }
            } else {
                note = "Fetch failed, so it started from your local \(GitService.baseDisplayName(baseRef))."
            }
        }
        return (path, GitService.addWorktree(repo: repo, path: path, newBranch: name, base: from), note)
    }

    /// The planned folder, or a dated sibling when something already sits there — the last
    /// Test's archived folder, a stray. Never write into a folder another row may own.
    private nonisolated static func freePath(_ path: URL) -> URL {
        guard FileManager.default.fileExists(atPath: path.path) else { return path }
        return path.deletingLastPathComponent()
            .appendingPathComponent(path.lastPathComponent + "-" + Routine.stamp(Date(), "yyyyMMdd-HHmmss"),
                                    isDirectory: true)
    }

    /// A new Test replaces the last one: its row is archived (quietly — nobody asked to archive
    /// anything) and its branch renamed aside to `…-test-<stamp>`, so the archived row stays
    /// restorable with its commits and the name is free for the fresh cut. A last Test someone
    /// is holding stays exactly as it is, and the new one is cut beside it under a dated name.
    /// Returns the name the new Test is cut on.
    private func retireTestBranch(_ name: String, in ws: Workspace) async throws -> String {
        let stamped = "\(name)-\(Routine.stamp(Date(), "yyyy-MM-dd-HHmmss"))"
        let holders = ws.branches.filter { $0.name == name }
        if holders.contains(where: { !$0.isArchived && heldByUser($0) }) { return stamped }
        for row in holders where !row.isArchived { archiveBranchQuietly(row) }
        let repo = ws.url
        let error = await runGit(repo: repo) { () -> String? in
            guard GitService.branchExists(name, at: repo) else { return nil }
            return GitService.renameBranch(name, to: stamped, at: repo)
        }
        // A rename git refused is already counted at the git seam (`GitService.runChecked`).
        if let error {
            throw RoutineDidNotStart(reason: "Couldn't put the last test away: \(Self.gitReason(error))")
        }
        for row in holders { row.name = stamped }
        return name
    }

    /// git's fatal line, not its progress chatter (the same rule `raiseWorktreeError` uses).
    private static func gitReason(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.last ?? output
    }

    // MARK: Didn't start

    /// The one outcome that speaks up by itself: the run records why, the routine carries the
    /// unseen dot, and one sticky card says so. Unattended, so Notification Center hears it too
    /// when Synth isn't in front.
    private func failRoutineRun(_ r: Routine, runID: UUID, reason: String, speaks: Bool) {
        editRoutine(r.id) { r in
            if speaks { r.failureUnseen = true }
            guard let i = r.runs.firstIndex(where: { $0.id == runID }) else { return }
            r.runs[i].outcome = .failed
            r.runs[i].reason = reason
        }
        guard speaks else { return }
        notifSeq += 1
        let id = UUID()
        notifs.append(InAppNotif(id: id, kind: .error, seq: notifSeq, sessionKind: .terminal,
                                 title: r.name, colorIndex: nil, outlivesSession: true,
                                 message: "Routine didn't start", iconPath: Phosphor.routine,
                                 tier: .attention, sub: reason,
                                 action: NotifAction(label: "View"), drains: false))
        let routineID = r.id
        notifActions[id] = { [weak self] in self?.openRoutine(routineID) }
        let toNC = automationNotifRoute.map { $0 == .notificationCenter } ?? !NSApp.isActive
        if toNC {
            NotificationService.shared.postSystemError(title: "Routine didn't start",
                                                       body: "\(r.name)\n\(reason)")
        }
    }
}

// MARK: - The scheduler

/// Why a tick is looking — only the words of a skip depend on it.
enum RoutineTickCause { case launch, wake, tick }

/// In-process only, like the archive sweep: no launchd, no background activity scheduler, no
/// daemon. Routines run while Synth is open; a slot missed while it was closed or the Mac slept
/// is caught up (or recorded as skipped) by the first tick that sees it.
@MainActor final class RoutineClock {
    static let shared = RoutineClock()
    fileprivate var task: Task<Void, Never>?
    fileprivate var wake: NSObjectProtocol?

    /// Seconds between ticks, or nil when the scheduler doesn't tick. A driven instance never
    /// ticks on its own — a gate would find runs it didn't ask for — unless the gate turns the
    /// clock on with `SYNTH_ROUTINE_TICK_SECONDS`.
    static var interval: TimeInterval? {
        if let raw = ProcessInfo.processInfo.environment["SYNTH_ROUTINE_TICK_SECONDS"],
           let secs = TimeInterval(raw), secs > 0 { return secs }
        return Automation.isDriven ? nil : 30
    }
}

extension AppStore {
    func startRoutineScheduler() {
        let interval = RoutineClock.interval
        let clock = RoutineClock.shared
        clock.task?.cancel()
        clock.task = Guarded.mainTask { [weak self] in
            // A beat after launch: the restore has landed and the terminal engine is up.
            try await Task.sleep(for: .seconds(min(interval ?? 5, 5)))
            self?.settleRestoredQueues()
            guard let interval else { return }
            self?.routineTick(cause: .launch)
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(interval))
                self?.routineTick(cause: .tick)
            }
        }
        if interval != nil, clock.wake == nil {
            clock.wake = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.routineTick(cause: .wake) }
            }
        }
    }

    /// A run left waiting when Synth quit is judged again at launch like any missed slot: within
    /// the schedule's window it fires as a catch-up; older, it is recorded as skipped.
    func settleRestoredQueues(now: Date = Date()) {
        for r in routines {
            guard let q = r.runs.first(where: { $0.outcome == .queued }) else { continue }
            editRoutine(r.id) { $0.runs.removeAll { $0.id == q.id } }
            let slot = q.slot ?? q.firedAt
            if now.timeIntervalSince(slot) <= r.schedule.catchUpWindow {
                fireRoutine(r.id, trigger: .catchUp, slot: slot)
            } else {
                skipRoutineSlot(r, slot: slot, now: now, cause: .launch)
            }
        }
    }

    /// One look at every routine: the latest slot since the last one it accounted for fires
    /// (on time, or as a catch-up within the schedule's window) or is recorded as skipped.
    /// Either way the slot is accounted for, so nothing fires twice — across ticks or launches.
    func routineTick(now: Date = Date(), cause: RoutineTickCause, only: UUID? = nil) {
        drainRoutineQueues()
        // "On time" is anything a couple of ticks late; later than that, something held it up.
        let onTime = 2 * (RoutineClock.interval ?? 30)
        for r in routines where only == nil || r.id == only {
            guard let from = r.lastSlot else {
                editRoutine(r.id) { $0.lastSlot = now }
                continue
            }
            guard let slot = r.schedule.latestSlot(after: from, upTo: now) else { continue }
            editRoutine(r.id) { $0.lastSlot = slot }
            let age = now.timeIntervalSince(slot)
            if age <= onTime {
                fireRoutine(r.id, trigger: .schedule, slot: slot)
            } else if age <= r.schedule.catchUpWindow {
                fireRoutine(r.id, trigger: .catchUp, slot: slot)
            } else {
                skipRoutineSlot(r, slot: slot, now: now, cause: cause)
            }
        }
    }

    /// A slot the scheduler owed and let go: recorded at the look that found it, as the
    /// schedule's own firing (no trigger badge), and shown at the slot's time.
    private func skipRoutineSlot(_ r: Routine, slot: Date, now: Date, cause: RoutineTickCause) {
        let away = cause == .wake ? "The Mac was asleep" : "Synth was closed"
        let back = cause == .wake ? "woke" : "opened"
        editRoutine(r.id) { r in
            r.runs.insert(RoutineRun(firedAt: now, slot: slot, trigger: .schedule, outcome: .skipped,
                                     skipReason: .missedTooOld,
                                     reason: "\(away), and the slot was more than \(r.schedule.catchUpSpan) old by the time it \(back)."),
                          at: 0)
        }
        Analytics.capture("routine_skipped", ["reason": RoutineRun.SkipReason.missedTooOld.rawValue])
    }
}

// MARK: - Automation (SYNTH_AUTOMATION=1 only)

extension AppStore {
    /// The routine verbs a gate drives. Each maps onto the public API — `routineCreate` and
    /// `routineUpdate` rehearse the synth-app `routine_create` / `routine_update` verbs, so they
    /// go through `defaultDraft`, `createRoutine` and `updateRoutine` and nothing else. Nil for a
    /// verb that isn't one of these.
    func routineAutomation(_ verb: String, _ request: [String: Any], branch: Branch) -> [String: Any]? {
        func uuid(_ key: String) -> UUID? { (request[key] as? String).flatMap(UUID.init(uuidString:)) }
        func date(_ key: String) -> Date? {
            (request[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        }
        func reply(_ body: () throws -> [String: Any]) -> [String: Any] {
            do { return try body() } catch let e as RoutineError {
                return ["ok": false, "error": e.message]
            } catch {
                return ["ok": false, "error": String(describing: error)]
            }
        }
        switch verb {
        case "automation.routines":
            return ["ok": true, "routines": routines.map(routineJSON)]

        case "automation.routineCreate":
            // An unknown `workspaceId` is passed through on purpose: refusing it is `validate`'s job.
            var draft = defaultDraft(in: uuid("workspaceId") ?? workspace(of: branch)?.id ?? UUID())
            Self.applyRoutineFields(request, to: &draft)
            return reply { ["ok": true, "id": try createRoutine(draft).id.uuidString] }

        case "automation.routineUpdate":
            guard let id = uuid("id") else { return ["ok": false, "error": "need id"] }
            return reply {
                try updateRoutine(id) { Self.applyRoutineFields(request, to: &$0) }
                return ["ok": true]
            }

        case "automation.routineFire":
            guard let id = uuid("id"), routine(id) != nil,
                  let trigger = RoutineTrigger(rawValue: request["trigger"] as? String ?? "runNow") else {
                return ["ok": false, "error": "need id + trigger"]
            }
            fireRoutine(id, trigger: trigger, slot: date("slot"))
            return ["ok": true]

        // A tick at a pretend `now` (epoch seconds) — how a gate reaches catch-up and a stale
        // slot without waiting a day. `cause` picks the skip's words; `id` keeps the pretend
        // clock off every other routine.
        case "automation.routineTick":
            let cause: RoutineTickCause = request["cause"] as? String == "wake" ? .wake
                : request["cause"] as? String == "tick" ? .tick : .launch
            routineTick(now: date("now") ?? Date(), cause: cause, only: uuid("id"))
            return ["ok": true]

        case "automation.routineDelete":
            guard let id = uuid("id") else { return ["ok": false, "error": "need id"] }
            deleteRoutine(id)
            return ["ok": true]

        default:
            return nil
        }
    }

    /// The fields a request names, over whatever the draft already holds.
    private static func applyRoutineFields(_ request: [String: Any], to d: inout RoutineDraft) {
        if let v = request["name"] as? String { d.name = v }
        if let v = request["prompt"] as? String { d.prompt = v }
        if let v = request["agent"] as? String { d.agent = AgentID(v) }
        if let v = request["base"] as? String { d.base = v }
        if let v = request["extraFlags"] as? String { d.extraFlags = v }
        switch request["target"] as? String {
        case "existing": d.target = .existing(branch: request["branch"] as? String ?? "")
        case "same": d.target = .same
        case "fresh": d.target = .fresh
        default: break
        }
        guard let s = request["schedule"] as? [String: Any] else { return }
        if let k = (s["kind"] as? String).flatMap(RoutineSchedule.Kind.init(rawValue:)) { d.schedule.kind = k }
        if let h = s["hour"] as? Int { d.schedule.hour = h }
        if let m = s["minute"] as? Int { d.schedule.minute = m }
        if let w = s["weekday"] as? Int { d.schedule.weekday = w }
        if let t = s["date"] as? NSNumber { d.schedule.date = Date(timeIntervalSince1970: t.doubleValue) }
    }

    private func routineJSON(_ r: Routine) -> [String: Any] {
        var target: [String: Any] = ["kind": r.target.kind]
        if case .existing(let b) = r.target { target["branch"] = b }
        return [
            "id": r.id.uuidString,
            "name": r.name,
            "workspaceId": r.workspaceID.uuidString,
            "agent": r.agent.rawValue,
            "target": target,
            "base": r.base ?? "",
            "effectiveBase": effectiveBase(RoutineDraft(r)) ?? "",
            "extraFlags": r.extraFlags,
            "schedule": r.schedule.kind.rawValue,
            "scheduleWords": r.schedule.words,
            "lastSlot": r.lastSlot?.timeIntervalSince1970 ?? 0,
            "nextSlot": r.nextSlot()?.timeIntervalSince1970 ?? 0,
            "failureUnseen": r.failureUnseen,
            "runs": r.runs.map { run -> [String: Any] in
                ["id": run.id.uuidString,
                 "firedAt": run.firedAt.timeIntervalSince1970,
                 "slot": run.slot?.timeIntervalSince1970 ?? 0,
                 "trigger": run.trigger.rawValue,
                 "outcome": run.outcome.rawValue,
                 "skipReason": run.skipReason?.rawValue ?? "",
                 "reason": run.reason ?? "",
                 "branch": run.branch ?? "",
                 "sessionId": run.sessionID?.uuidString ?? "",
                 "busy": isBusy(run),
                 "worktreePath": run.branch.flatMap { name in
                     workspaces.first { $0.id == r.workspaceID }?.branches
                         .first { $0.name == name && !$0.isArchived }?.worktreeURL.path } ?? "",
                 "pending": routineRunsPending.contains(run.id)]
            },
        ]
    }
}
