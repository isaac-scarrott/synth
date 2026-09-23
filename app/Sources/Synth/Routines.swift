import Foundation

/// A saved prompt Synth hands to an agent on a schedule — on this Mac, only while Synth is open
/// (docs/features/2026-09-23.md). Durable: rides `state.json` beside the workspaces, history and
/// all, so a relaunch knows what already fired and what it missed.
///
/// Everything that creates, edits, deletes or fires a routine goes through the `AppStore` API at
/// the bottom of this file — the board is one caller, and a future synth-app `routine_create` /
/// `routine_update` control verb is meant to be another, so no rule or default may live only in
/// the UI.
struct Routine: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// The project (`Workspace.id`) it belongs to. A routine never outlives its project: removing
    /// the project removes its routines.
    var workspaceID: UUID
    var prompt: String
    var agent: AgentID
    var target: RoutineTarget
    /// What `.same` / `.fresh` branches are cut from. Nil means the project's default branch
    /// (`AppStore.routineBase`).
    var base: String?
    /// Appended after the project's own flags for `agent`, for this routine only.
    var extraFlags: String
    var schedule: RoutineSchedule
    /// Newest first, at most `Routine.historyLimit`.
    var runs: [RoutineRun]
    /// A run didn't start and nobody has opened this routine since. Drives the sidebar dot.
    var failureUnseen: Bool
    /// The last slot the scheduler has accounted for (fired, queued or skipped). Catch-up and
    /// the next slot are both measured from here, so nothing fires twice across a relaunch.
    var lastSlot: Date?

    static let historyLimit = 20
}

/// Where a run happens.
enum RoutineTarget: Codable, Equatable {
    /// A new session on a branch row the project already has (including the repo-root checkout).
    case existing(branch: String)
    /// `routine/<slug>` — one worktree reused by every run; commits accumulate.
    case same
    /// `routine/<slug>-YYYY-MM-DD-HHmm` — a fresh worktree per run.
    case fresh

    /// Closed enum for analytics.
    var kind: String {
        switch self {
        case .existing: "existing"
        case .same: "same"
        case .fresh: "fresh"
        }
    }
}

/// Presets only — no cron (docs/features/2026-09-23.md).
struct RoutineSchedule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case hourly, daily, weekdays, weekly, once }
    var kind: Kind
    var hour: Int = 9
    var minute: Int = 0
    /// `Calendar` weekday, 1 = Sunday … 7 = Saturday. Weekly only.
    var weekday: Int = 2
    /// The day a `.once` fires (its time comes from hour/minute).
    var date: Date?

    /// How stale a missed slot may be and still catch up on launch or wake: one period.
    var catchUpWindow: TimeInterval {
        switch kind {
        case .hourly: 3600
        case .daily, .weekdays: 86_400
        case .weekly: 7 * 86_400
        case .once: .infinity   // a missed Once always runs
        }
    }

    /// `catchUpWindow` in words.
    var catchUpSpan: String {
        switch kind {
        case .hourly: "an hour"
        case .daily, .weekdays: "a day"
        case .weekly: "a week"
        case .once: "any time"
        }
    }

    /// What the editor says about a slot missed while Synth was closed.
    var catchUpWords: String {
        kind == .once
            ? "Missed while Synth was closed? It runs when Synth opens."
            : "Missed while Synth was closed? It runs once when Synth opens, if the slot is within \(catchUpSpan)."
    }

    /// The moment a `.once` fires, or nil for any other kind.
    func onceSlot(calendar: Calendar = .current) -> Date? {
        guard kind == .once, let date else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }

    /// The first slot strictly after `date`, or nil (a Once already past `date`).
    func slot(after date: Date, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .once:
            guard let at = onceSlot(calendar: calendar) else { return nil }
            return at > date ? at : nil
        case .hourly:
            return calendar.nextDate(after: date, matching: DateComponents(minute: 0, second: 0),
                                     matchingPolicy: .nextTime)
        case .daily:
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                     matchingPolicy: .nextTime)
        case .weekly:
            return calendar.nextDate(after: date,
                                     matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                                     matchingPolicy: .nextTime)
        case .weekdays:
            var from = date
            for _ in 0..<8 {
                guard let next = calendar.nextDate(after: from, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                                   matchingPolicy: .nextTime) else { return nil }
                if !calendar.isDateInWeekend(next) { return next }
                from = next
            }
            return nil
        }
    }

    /// The most recent slot in `(after, upTo]`, or nil — what a relaunch or wake has missed.
    func latestSlot(after: Date, upTo: Date, calendar: Calendar = .current) -> Date? {
        var cursor = after
        var latest: Date?
        // Bounded: a routine asleep for a year is still one catch-up, found in ≤ 400 steps
        // for anything coarser than hourly; hourly is capped by its one-hour window anyway.
        // Three days past the window, not one: Weekdays' latest slot can sit a whole weekend
        // back, and a floor that cut it off answered nil — so a stale Friday was never recorded
        // as skipped.
        let floor = kind == .once ? after : max(after, upTo.addingTimeInterval(-catchUpWindow - 3 * 86_400))
        cursor = floor
        for _ in 0..<400 {
            guard let next = slot(after: cursor, calendar: calendar), next <= upTo else { break }
            latest = next
            cursor = next
        }
        return latest
    }

    /// "Weekdays 09:00", "Mondays 07:00", "Once, 24 Sep 14:00".
    var words: String {
        let t = RoutineWords.time(hour: hour, minute: minute)
        switch kind {
        case .hourly: return "Hourly"
        case .daily: return "Daily \(t)"
        case .weekdays: return "Weekdays \(t)"
        case .weekly: return "\(RoutineWords.weekday(weekday))s \(t)"
        case .once:
            guard let date else { return "Once \(t)" }
            return "Once, \(RoutineWords.day(date)) \(t)"
        }
    }
}

/// Every routine date and weekday in one voice — the board, the sidebar mark, the schedule's
/// words and the agent's preamble — pinned to en_GB so "24 Sep 14:00" reads the same on every Mac.
enum RoutineWords {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = format
        return f
    }
    private static let hhmm = formatter("HH:mm")
    private static let dayMonth = formatter("d MMM")
    private static let shortDay = formatter("EEE")
    private static let names = formatter("EEEE")

    static func time(_ d: Date) -> String { hhmm.string(from: d) }
    static func time(hour: Int, minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
    /// "24 Sep".
    static func day(_ d: Date) -> String { dayMonth.string(from: d) }
    /// "Mon 24 Sep 14:00".
    static func dayAndTime(_ d: Date) -> String { "\(shortDay.string(from: d)) \(day(d)) \(time(d))" }
    /// `Calendar` weekday 1…7 → "Sunday"…"Saturday".
    static func weekday(_ w: Int) -> String { names.weekdaySymbols[((w - 1) % 7 + 7) % 7] }

    /// working.html `rtWhen`: "Today 09:00", "Tomorrow 09:00", "Yesterday 09:00", a weekday
    /// within five days, else "21 Sep 09:00".
    static func when(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let diff = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: d)).day ?? 0
        let t = time(d)
        switch diff {
        case 0: return "Today \(t)"
        case 1: return "Tomorrow \(t)"
        case -1: return "Yesterday \(t)"
        case -5...5: return "\(shortDay.string(from: d)) \(t)"
        default: return "\(day(d)) \(t)"
        }
    }
}

enum RoutineTrigger: String, Codable {
    /// The scheduler, on time — and a slot recorded as skipped.
    case schedule
    case catchUp, runNow, test
}

struct RoutineRun: Codable, Identifiable, Equatable {
    enum Outcome: String, Codable {
        /// Fired and handed to an agent. Whether the agent is still busy is derived live from
        /// `sessionID`, never stored.
        case started
        /// Waiting behind a busy run. At most one per routine, carrying the latest slot.
        case queued
        case skipped
        /// Didn't start — the one outcome that speaks up by itself.
        case failed
    }
    /// Closed enum for analytics (`routine_skipped`); the sentence rides in `reason`.
    enum SkipReason: String, Codable {
        /// The slot was missed while Synth was closed or the Mac asleep, and is older than the
        /// schedule's catch-up window.
        case missedTooOld
    }

    let id: UUID
    var firedAt: Date
    /// The slot it was for — differs from `firedAt` on catch-up. Nil for Run now / Test.
    var slot: Date?
    var trigger: RoutineTrigger
    var outcome: Outcome
    var skipReason: SkipReason?
    /// Why it skipped or failed, or a note on a run that started ("Fetch failed, so it started
    /// from your local main."). Local only — never an analytics property.
    var reason: String?
    var branch: String?
    var sessionID: UUID?

    init(firedAt: Date, slot: Date? = nil, trigger: RoutineTrigger, outcome: Outcome,
         skipReason: SkipReason? = nil, reason: String? = nil, branch: String? = nil, sessionID: UUID? = nil) {
        self.id = UUID()
        self.firedAt = firedAt
        self.slot = slot
        self.trigger = trigger
        self.outcome = outcome
        self.skipReason = skipReason
        self.reason = reason
        self.branch = branch
        self.sessionID = sessionID
    }
}

/// The mark a run leaves on a row it created: every session a run spawns, and a branch a run
/// cut (same-each-run, new-each-run, a Test) — never an existing branch it merely ran on.
/// Persisted on the row itself, so it names the routine that made the row even after the
/// routine is edited, loses the run from its 20, or is deleted.
struct RoutineMark: Codable, Equatable {
    var name: String
    var firedAt: Date
    /// A Test's throwaway worktree, which archives when its session is closed.
    var test: Bool
}

/// What a caller supplies to create or update a routine — the board's editor, and later an
/// agent over MCP.
struct RoutineDraft: Equatable {
    var name: String
    var workspaceID: UUID
    var prompt: String
    var agent: AgentID
    var target: RoutineTarget
    var base: String?
    var extraFlags: String = ""
    var schedule: RoutineSchedule
}

extension RoutineDraft {
    /// The editable half of a saved routine.
    init(_ r: Routine) {
        self.init(name: r.name, workspaceID: r.workspaceID, prompt: r.prompt, agent: r.agent,
                  target: r.target, base: r.base, extraFlags: r.extraFlags, schedule: r.schedule)
    }
}

/// A draft that can't become a routine. `message` is written for the person (or agent) who
/// supplied it.
struct RoutineError: Error, Equatable {
    let message: String
}

extension Routine {
    /// `routine/<slug>` — shared by `.same`, the `.fresh` prefix and the `-test` worktree.
    var slug: String {
        let s = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "routine" : s
    }

    /// The branch a run of `trigger` at `date` lands on.
    func branchName(for trigger: RoutineTrigger, at date: Date) -> String {
        if trigger == .test { return "routine/\(slug)-test" }
        switch target {
        case .existing(let branch): return branch
        case .same: return "routine/\(slug)"
        case .fresh: return "routine/\(slug)-\(Self.stamp(date, "yyyy-MM-dd-HHmm"))"
        }
    }

    /// A branch-name stamp — an identifier, so POSIX rather than the display locale.
    static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }

    /// The next slot the scheduler owes, or nil once a Once has fired. A Once missed while Synth
    /// was closed is still owed — possibly in the past — until the next tick fires it.
    func nextSlot(after now: Date = Date()) -> Date? {
        if schedule.kind == .once {
            guard let at = schedule.onceSlot(), at > (lastSlot ?? .distantPast) else { return nil }
            return at
        }
        return schedule.slot(after: max(now, lastSlot ?? .distantPast))
    }

    mutating func apply(_ d: RoutineDraft) {
        name = d.name.trimmingCharacters(in: .whitespaces); workspaceID = d.workspaceID; prompt = d.prompt
        agent = d.agent; target = d.target; base = d.base; extraFlags = d.extraFlags; schedule = d.schedule
    }
}

// MARK: - The one API (board today, synth-app MCP later)

extension AppStore {
    func routine(_ id: UUID) -> Routine? { routines.first { $0.id == id } }

    // MARK: Defaults

    /// The agent a new routine in `ws` starts with: the first enabled agent in the project's
    /// session template, else the first available agent anywhere.
    func defaultRoutineAgent(in ws: Workspace?) -> AgentID {
        let available = Set(availableAgents.map(\.id))
        return sessionTemplate(for: ws).lazy.compactMap(\.kind.agentID).first(where: available.contains)
            ?? availableAgents.first?.id ?? .claudeCode
    }

    /// Where Existing points when nothing better is known: the repo-root checkout's branch, else
    /// the project's first live branch.
    func defaultExistingBranch(in ws: Workspace) -> String? {
        let root = ws.url.standardizedFileURL
        return ws.liveBranches.first { $0.worktreeURL.standardizedFileURL == root }?.name
            ?? ws.liveBranches.first?.name
    }

    /// `preferred` while it is still a live branch of `ws`, else `defaultExistingBranch`.
    func existingBranch(preferring preferred: String?, in ws: Workspace) -> String {
        if let preferred, ws.liveBranches.contains(where: { $0.name == preferred }) { return preferred }
        return defaultExistingBranch(in: ws) ?? ""
    }

    /// A new routine's starting point — what the board's editor opens with and what a caller
    /// that leaves a field out gets.
    func defaultDraft(in workspaceID: UUID) -> RoutineDraft {
        let ws = workspaces.first { $0.id == workspaceID }
        return RoutineDraft(name: "", workspaceID: workspaceID, prompt: "",
                            agent: defaultRoutineAgent(in: ws), target: .fresh, base: nil,
                            schedule: RoutineSchedule(kind: .weekdays, hour: 9, minute: 0))
    }

    /// Move a draft to another project: what only made sense in the old one resets — Base to the
    /// new project's default, an existing branch to the new project's default branch.
    func reproject(_ d: inout RoutineDraft, to workspaceID: UUID) {
        guard d.workspaceID != workspaceID, let ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
        d.workspaceID = workspaceID
        d.base = nil
        if case .existing = d.target { d.target = .existing(branch: existingBranch(preferring: nil, in: ws)) }
    }

    // MARK: Base

    /// What a `.same` / `.fresh` branch is cut from — the routine's own base, else the project's
    /// default. The runner cuts from exactly this; off the main thread, it may ask the remote.
    nonisolated static func routineBase(_ base: String?, repo: URL) -> String {
        base ?? GitService.defaultBase(at: repo)
    }

    /// The base the editor shows: the draft's own, else the project's default once
    /// `loadRoutineProjectBase` has resolved it.
    func effectiveBase(_ d: RoutineDraft) -> String? {
        d.base ?? routineProjectBases[d.workspaceID]
    }

    func loadRoutineProjectBase(_ workspaceID: UUID) async {
        guard let repo = workspaces.first(where: { $0.id == workspaceID })?.url else { return }
        let base = await runGit(repo: repo) { Self.routineBase(nil, repo: repo) }
        routineProjectBases[workspaceID] = base
    }

    // MARK: Rules

    /// Check a draft against the live tree. Every rule a caller could break is here, so an agent
    /// creating or updating a routine gets the same answer the editor would. `keeping` is the
    /// schedule already saved: a Once that has passed may keep its time, it just can't be given one.
    func validate(_ draft: RoutineDraft, keeping saved: RoutineSchedule? = nil, now: Date = Date()) throws {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw RoutineError(message: "A routine needs a name.") }
        guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RoutineError(message: "A routine needs a prompt.") }
        guard let ws = workspaces.first(where: { $0.id == draft.workspaceID })
        else { throw RoutineError(message: "That project isn't in Synth.") }
        guard availableAgents.contains(where: { $0.id == draft.agent })
        else { throw RoutineError(message: "That agent isn't available.") }
        if case .existing(let branch) = draft.target,
           !ws.liveBranches.contains(where: { $0.name == branch }) {
            throw RoutineError(message: "\(branch) isn't a branch in \(ws.name).")
        }
        let s = draft.schedule
        guard (0...23).contains(s.hour) else { throw RoutineError(message: "The hour has to be 0–23.") }
        guard (0...59).contains(s.minute) else { throw RoutineError(message: "The minute has to be 0–59.") }
        guard (1...7).contains(s.weekday)
        else { throw RoutineError(message: "The weekday has to be 1–7 (Sunday is 1).") }
        if s.kind == .once {
            guard let at = s.onceSlot() else { throw RoutineError(message: "A Once routine needs a date.") }
            if at <= now, s != saved { throw RoutineError(message: "That time has already passed.") }
        }
    }

    // MARK: Create, update, delete

    @discardableResult
    func createRoutine(_ draft: RoutineDraft) throws -> Routine {
        try validate(draft)
        var r = Routine(id: UUID(), name: "", workspaceID: draft.workspaceID, prompt: "", agent: draft.agent,
                        target: draft.target, base: nil, extraFlags: "", schedule: draft.schedule,
                        runs: [], failureUnseen: false, lastSlot: Date())
        r.apply(draft)
        routines.append(r)
        Analytics.capture("routine_created", [
            "target": r.target.kind,
            "schedule": r.schedule.kind.rawValue,
            "agent": r.agent.isCustom ? "custom" : r.agent.rawValue,
        ])
        return r
    }

    /// Edits apply from the next run: a queued run holds a slot, not a snapshot. Refused whole,
    /// with the rule it broke, when the result isn't a routine `createRoutine` would accept.
    func updateRoutine(_ id: UUID, _ change: (inout RoutineDraft) -> Void) throws {
        guard let i = routines.firstIndex(where: { $0.id == id }) else {
            throw RoutineError(message: "That routine isn't in Synth.")
        }
        var r = routines[i]
        var d = RoutineDraft(r)
        change(&d)
        try validate(d, keeping: r.schedule)
        let schedule = r.schedule
        r.apply(d)
        // A new schedule starts counting from now — it never owes runs for slots under the old one.
        if r.schedule != schedule { r.lastSlot = Date() }
        routines[i] = r
    }

    /// Someone has looked at the routine: its unseen failure dot goes.
    func markRoutineSeen(_ id: UUID) {
        guard let i = routines.firstIndex(where: { $0.id == id }), routines[i].failureUnseen else { return }
        routines[i].failureUnseen = false
    }

    /// Removes the routine and its history. Never its branches — those have Archive — and never
    /// the marks its runs left on their rows.
    func deleteRoutine(_ id: UUID) {
        routines.removeAll { $0.id == id }
    }

    /// A run that started and whose agent is still mid-turn — "Running" on the board, and what
    /// makes the next firing queue and Delete ask.
    func isBusy(_ run: RoutineRun) -> Bool {
        guard run.outcome == .started else { return false }
        // Still cutting its branch or waiting on its agent: no session to ask yet, but a second
        // firing mustn't slip in underneath it.
        if routineRunsPending.contains(run.id) { return true }
        guard let id = run.sessionID, let s = session(id) else { return false }
        return s.status.isBusy
    }
}
