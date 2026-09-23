import Foundation

/// A saved prompt Synth hands to an agent on a schedule — on this Mac, only while Synth is open
/// (docs/features/2026-09-23.md). Durable: rides `state.json` beside the workspaces, history and
/// all, so a relaunch knows what already fired and what it missed.
///
/// Everything that creates, edits, deletes or fires a routine goes through the `AppStore` API at
/// the bottom of this file — the board is one caller, and a future synth-app `routine_create`
/// control verb is meant to be another, so no rule may live only in the UI.
struct Routine: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// The project (`Workspace.id`) it belongs to. A routine never outlives its project: removing
    /// the project removes its routines.
    var workspaceID: UUID
    var prompt: String
    var agent: AgentID
    var target: RoutineTarget
    /// What `.same` / `.fresh` branches are cut from. Nil means the project's default branch.
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

    /// How stale a missed slot may be and still catch up on launch or wake.
    var catchUpWindow: TimeInterval {
        switch kind {
        case .hourly: 3600
        case .daily, .weekdays: 86_400
        case .weekly: 7 * 86_400
        case .once: .infinity   // a missed Once always runs
        }
    }

    /// The first slot strictly after `date`, or nil (a Once already past `date`).
    func slot(after date: Date, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .once:
            guard let day = self.date,
                  let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            else { return nil }
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
        let floor = kind == .once ? after : max(after, upTo.addingTimeInterval(-catchUpWindow - 86_400))
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
        let t = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .hourly: return "Hourly"
        case .daily: return "Daily \(t)"
        case .weekdays: return "Weekdays \(t)"
        case .weekly: return "\(Calendar.current.weekdaySymbols[(weekday - 1 + 7) % 7])s \(t)"
        case .once:
            guard let date else { return "Once \(t)" }
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("d MMM")
            return "Once, \(f.string(from: date)) \(t)"
        }
    }
}

enum RoutineTrigger: String, Codable {
    case schedule, catchUp, runNow, test
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

/// What a caller supplies to create a routine — the board's editor, and later an agent over MCP.
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
        case .fresh:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd-HHmm"
            return "routine/\(slug)-\(f.string(from: date))"
        }
    }

    /// The next slot the scheduler will fire, or nil (a Once that has fired).
    func nextSlot(after now: Date = Date()) -> Date? {
        schedule.slot(after: max(now, lastSlot ?? .distantPast))
    }
}

// MARK: - The one API (board today, synth-app MCP later)

extension AppStore {
    func routine(_ id: UUID) -> Routine? { routines.first { $0.id == id } }

    /// Check a draft against the live tree. Every rule a caller could break is here, so an agent
    /// creating a routine gets the same answer the editor would.
    func validate(_ draft: RoutineDraft) throws {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw RoutineError(message: "A routine needs a name.") }
        guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RoutineError(message: "A routine needs a prompt.") }
        guard let ws = workspaces.first(where: { $0.id == draft.workspaceID })
        else { throw RoutineError(message: "That project isn't in Synth.") }
        guard availableAgents.contains(where: { $0.id == draft.agent })
        else { throw RoutineError(message: "That agent isn't available.") }
        if case .existing(let branch) = draft.target,
           !ws.branches.contains(where: { $0.name == branch && $0.archivedAt == nil }) {
            throw RoutineError(message: "\(branch) isn't a branch in \(ws.name).")
        }
        if draft.schedule.kind == .once, draft.schedule.date == nil {
            throw RoutineError(message: "A Once routine needs a date.")
        }
    }

    @discardableResult
    func createRoutine(_ draft: RoutineDraft) throws -> Routine {
        try validate(draft)
        let r = Routine(id: UUID(), name: draft.name.trimmingCharacters(in: .whitespaces),
                        workspaceID: draft.workspaceID, prompt: draft.prompt, agent: draft.agent,
                        target: draft.target, base: draft.base, extraFlags: draft.extraFlags,
                        schedule: draft.schedule, runs: [], failureUnseen: false, lastSlot: Date())
        routines.append(r)
        Analytics.capture("routine_created", [
            "target": r.target.kind,
            "schedule": r.schedule.kind.rawValue,
            "agent": r.agent.isCustom ? "custom" : r.agent.rawValue,
        ])
        return r
    }

    /// Edits apply from the next run: a queued run holds a slot, not a snapshot.
    func updateRoutine(_ id: UUID, _ change: (inout Routine) -> Void) {
        guard let i = routines.firstIndex(where: { $0.id == id }) else { return }
        var r = routines[i]
        let schedule = r.schedule
        change(&r)
        // A new schedule starts counting from now — it never owes runs for slots under the old one.
        if r.schedule != schedule { r.lastSlot = Date() }
        routines[i] = r
    }

    /// Removes the routine and its history. Never its branches — those have Archive.
    func deleteRoutine(_ id: UUID) {
        routines.removeAll { $0.id == id }
    }

    /// The routine run that spawned `sessionID`, for the row mark and its tooltip.
    func routineRun(forSession sessionID: UUID) -> (routine: Routine, run: RoutineRun)? {
        for r in routines { if let run = r.runs.first(where: { $0.sessionID == sessionID }) { return (r, run) } }
        return nil
    }

    /// The routine whose runs cut `branch` in `workspaceID` (a `.same`, `.fresh` or test branch —
    /// never an existing branch it merely ran on), for the branch row's mark.
    func routineRun(forBranch branch: String, in workspaceID: UUID) -> (routine: Routine, run: RoutineRun)? {
        for r in routines where r.workspaceID == workspaceID {
            if case .existing = r.target, r.runs.first(where: { $0.branch == branch })?.trigger != .test { continue }
            if let run = r.runs.first(where: { $0.branch == branch }) { return (r, run) }
        }
        return nil
    }

    /// A run that started and whose agent is still mid-turn — "Running" on the board, and what
    /// makes the next firing queue and Delete ask.
    func isBusy(_ run: RoutineRun) -> Bool {
        guard run.outcome == .started, let id = run.sessionID, let s = session(id) else { return false }
        return s.status.isBusy
    }
}
