import Foundation

/// What the Routines board is showing (working.html `rtView`).
enum RoutinesView: Equatable {
    case list
    case detail(UUID)
    /// A routine not yet saved. `pristine` until its first edit — the starters show only then.
    case draft(RoutineDraft, pristine: Bool)
}

/// An editor row that holds a control of its own.
enum RoutineField: Hashable {
    case name, project, prompt, agent, branch, schedule, base, flags

    /// ↵ on these opens a menu rather than placing a caret.
    var isPopUp: Bool { [.project, .agent, .schedule, .base].contains(self) }
}

/// A row the board's keyboard cursor can rest on (working.html `rtRows`).
enum RoutineRow: Hashable {
    case routine(UUID)
    case starter(Int)
    case field(RoutineField)
    case more
    case run(UUID)
    case noRuns
}

/// Prefilled text and nothing else: picking one fills the editor, it never saves.
struct RoutineStarter {
    let name: String
    let prompt: String
    let schedule: RoutineSchedule
    let target: RoutineTarget

    static let all: [RoutineStarter] = [
        RoutineStarter(name: "Review my open PRs",
                       prompt: "Look at every open pull request I authored in this repo. For each one, check CI, unresolved review comments and merge conflicts. Fix what you can on the PR branch and push. End with a short list of what still needs me.",
                       schedule: RoutineSchedule(kind: .weekdays, hour: 9, minute: 0), target: .fresh),
        RoutineStarter(name: "Bump dependencies",
                       prompt: "Update outdated dependencies one at a time and run the tests after each. Keep the bumps that pass, revert the ones that don't, and commit each bump on its own. Finish with what you skipped and why.",
                       schedule: RoutineSchedule(kind: .weekly, hour: 7, minute: 0, weekday: 2), target: .same),
        RoutineStarter(name: "Hunt a flaky test",
                       prompt: "Run the test suite five times. If any test both passes and fails across the runs, find out why and fix the cause. If everything is stable, say so and stop.",
                       schedule: RoutineSchedule(kind: .daily, hour: 2, minute: 0), target: .fresh),
        RoutineStarter(name: "Morning brief",
                       prompt: "Summarise what changed on main since yesterday morning: merged PRs, who touched what, and anything that looks risky. Don't change any files.",
                       schedule: RoutineSchedule(kind: .weekdays, hour: 8, minute: 30), target: .existing(branch: "main")),
    ]
}

extension RoutineTarget {
    /// The segmented control's three choices (the stored `.existing` carries its branch).
    enum Choice: CaseIterable { case existing, same, fresh
        var label: String {
            switch self {
            case .existing: "Existing branch"
            case .same: "Same each run"
            case .fresh: "New each run"
            }
        }
        var desc: String {
            switch self {
            case .existing: "A new session on a branch you already have, alongside whatever is there."
            case .same: "One branch, kept between runs — each run picks up where the last left off."
            case .fresh: "A fresh branch from Base every run."
            }
        }
    }
    var choice: Choice {
        switch self {
        case .existing: .existing
        case .same: .same
        case .fresh: .fresh
        }
    }
}

extension RoutineSchedule.Kind {
    var label: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        case .once: "Once"
        }
    }
}

extension RoutineWords {
    static func target(_ t: RoutineTarget, slug: String) -> String {
        switch t {
        case .existing(let branch): "on \(branch)"
        case .same: "routine/\(slug)"
        case .fresh: "new branch each run"
        }
    }

    @MainActor static func agent(_ id: AgentID) -> String { AgentRegistry.descriptor(id)?.displayName ?? id.rawValue }
}

/// The outcome of a firing as the board says it — "didn't start" is the only red one.
enum RoutineOutcomeWord {
    case ran, running, queued, skipped, failed

    var word: String {
        switch self {
        case .ran: "Ran"
        case .running: "Running"
        case .queued: "Queued"
        case .skipped: "Skipped"
        case .failed: "Didn't start"
        }
    }
}

extension RoutineTrigger {
    /// The badge a run row wears; a scheduled firing needs none.
    var badge: String? {
        switch self {
        case .schedule: nil
        case .catchUp: "Catch-up"
        case .runNow: "Run now"
        case .test: "Test"
        }
    }
}

// MARK: - Board state and navigation

extension AppStore {
    func outcome(_ run: RoutineRun) -> RoutineOutcomeWord {
        switch run.outcome {
        case .started: isBusy(run) ? .running : .ran
        case .queued: .queued
        case .skipped: .skipped
        case .failed: .failed
        }
    }

    /// The sidebar entry's one signal.
    var routineFailureUnseen: Bool { routines.contains { $0.failureUnseen } }

    /// Routines grouped by project, in tree order.
    var routineGroups: [(workspace: Workspace, routines: [Routine])] {
        workspaces.compactMap { ws in
            let own = routines.filter { $0.workspaceID == ws.id }
            return own.isEmpty ? nil : (ws, own)
        }
    }

    /// The draft or routine the editor is showing — a saved routine's refused edit included.
    var boardDraft: RoutineDraft? {
        switch routinesView {
        case .list: nil
        case .detail(let id): routineEdit ?? routine(id).map(RoutineDraft.init)
        case .draft(let d, _): d
        }
    }

    /// Every row the cursor walks, top to bottom, for what the board shows now.
    var routineRows: [RoutineRow] {
        switch routinesView {
        case .list:
            if routines.isEmpty { return RoutineStarter.all.indices.map(RoutineRow.starter) }
            return routineGroups.flatMap { $0.routines.map { RoutineRow.routine($0.id) } }
        case .detail(let id):
            guard let r = routine(id) else { return [] }
            return editorRows(r.target)
                + (r.runs.isEmpty ? [.noRuns] : r.runs.map { .run($0.id) })
        case .draft(let d, let pristine):
            return (pristine ? RoutineStarter.all.indices.map(RoutineRow.starter) : [])
                + editorRows(d.target)
        }
    }

    private func editorRows(_ target: RoutineTarget) -> [RoutineRow] {
        var rows: [RoutineRow] = [.field(.name), .field(.project), .field(.prompt), .field(.agent),
                                  .field(.branch), .field(.schedule), .more]
        if routineMoreOpen {
            if target.choice != .existing { rows.append(.field(.base)) }
            rows.append(.field(.flags))
        }
        return rows
    }

    func enterRoutines(_ id: UUID? = nil) {
        activeMenu = nil
        closePalette()
        shortcutsOpen = false
        sidebarCollapsed = false
        openSetupBranchID = nil
        settingsOpen = false
        usageOpen = false
        routinesOpen = true
        routinesView = .list
        routineConfirmDelete = nil
        resetRoutineEditor()
        routineFocus = nil
        navCursor = NavID.routinesFoot
        focusSidebar()
        if let id { openRoutine(id); return }
        keyboardActive = true
        routineCursor = routineRows.first
    }

    /// Straight to one routine's detail — the failure card's View, ⌘K, and a list row.
    func openRoutine(_ id: UUID) {
        guard routine(id) != nil else { return }
        if !routinesOpen { enterRoutines() }
        markRoutineSeen(id)
        if let r = routine(id) { resolveRoutineProjectBase(r.workspaceID) }
        routinesView = .detail(id)
        routineMoreOpen = false
        routineConfirmDelete = nil
        resetRoutineEditor()
        routineFocus = nil
        keyboardActive = true
        routineCursor = routineRows.first
    }

    /// Board state goes with the board; every surface that takes the pane calls this.
    func leaveRoutines() {
        guard routinesOpen else { return }
        routinesOpen = false
        routinesView = .list
        routineConfirmDelete = nil
        resetRoutineEditor()
        routineFocus = nil
        routineCursor = nil
    }

    /// The editor names the base a run would cut from; resolving it can touch git, so off-main.
    private func resolveRoutineProjectBase(_ wsID: UUID) {
        Guarded.mainTask { [weak self] in await self?.loadRoutineProjectBase(wsID) }
    }

    /// What the editor holds for the routine or draft on screen goes when that screen does.
    private func resetRoutineEditor() {
        routineDraftError = nil
        routineEdit = nil
        routineExistingMemory = nil
    }

    func exitRoutines() {
        guard routinesOpen else { return }
        leaveRoutines()
        let visible = visibleRows.map(\.id)
        navCursor = openSessionID.flatMap { visible.contains($0) ? $0 : nil } ?? NavID.routinesFoot
    }

    func toggleRoutines() { routinesOpen ? exitRoutines() : enterRoutines() }

    /// One layer back: detail or draft → the list, the list → off the board.
    func routineBack() {
        let from: UUID? = if case .detail(let id) = routinesView { id } else { nil }
        guard routinesView != .list else { exitRoutines(); return }
        routinesView = .list
        routineConfirmDelete = nil
        resetRoutineEditor()
        routineFocus = nil
        let rows = routineRows
        routineCursor = from.map(RoutineRow.routine).flatMap { rows.contains($0) ? $0 : nil } ?? rows.first
    }

    /// A new draft in the project you're in, prefilled from `starter` when one was picked.
    func newRoutineDraft(_ starter: RoutineStarter? = nil) {
        let ws = openSession.flatMap { branch(of: $0) }.flatMap { workspace(of: $0) } ?? workspaces.first
        guard let ws else { return }
        var draft = defaultDraft(in: ws.id)
        if let starter {
            draft.name = starter.name
            draft.prompt = starter.prompt
            draft.schedule = starter.schedule
            draft.target = starter.target
            if case .existing(let b) = starter.target {
                draft.target = .existing(branch: existingBranch(preferring: b, in: ws))
            }
        }
        resolveRoutineProjectBase(ws.id)
        routinesView = .draft(draft, pristine: starter == nil)
        routineMoreOpen = false
        resetRoutineEditor()
        if starter == nil {
            routineFocus = .name
            keyboardActive = false
        } else {
            routineFocus = nil
            keyboardActive = true
        }
        routineCursor = starter == nil ? .field(.name) : routineRows.first
    }

    /// Every edit lands here: a draft changes in place (and stops being pristine); a saved
    /// routine autosaves through `updateRoutine`, so it applies from the next run. An edit
    /// `updateRoutine` refuses stays on screen with the rule it broke, and saves once it's valid.
    func editBoardRoutine(_ change: (inout RoutineDraft) -> Void) {
        guard let before = boardDraft else { return }
        var d = before
        change(&d)
        // A field writing back what it already holds (focus does this) is not an edit.
        guard d != before else { return }
        if case .existing(let b) = before.target, d.target.choice != .existing { routineExistingMemory = b }
        switch routinesView {
        case .list: return
        case .draft:
            routinesView = .draft(d, pristine: false)
            routineDraftError = nil
        case .detail(let id):
            do {
                try updateRoutine(id) { $0 = d }
                routineEdit = nil
                routineDraftError = nil
            } catch {
                // Not a fault: the rule the edit broke, said to the person making it.
                routineEdit = d
                routineDraftError = (error as? RoutineError)?.message ?? "\(error)"
            }
        }
    }

    func setBoardProject(_ wsID: UUID) {
        routineExistingMemory = nil
        resolveRoutineProjectBase(wsID)
        editBoardRoutine { reproject(&$0, to: wsID) }
    }

    /// Existing comes back to the branch it last held, while that branch is still here.
    func setBoardTarget(_ choice: RoutineTarget.Choice) {
        guard let d = boardDraft, let ws = workspaces.first(where: { $0.id == d.workspaceID }) else { return }
        let remembered = routineExistingMemory
        editBoardRoutine { d in
            switch choice {
            case .existing:
                if case .existing = d.target { return }
                d.target = .existing(branch: existingBranch(preferring: remembered, in: ws))
            case .same: d.target = .same
            case .fresh: d.target = .fresh
            }
        }
    }

    func setBoardScheduleKind(_ kind: RoutineSchedule.Kind) {
        editBoardRoutine { d in
            guard d.schedule.kind != kind else { return }
            d.schedule.kind = kind
            if kind == .once, d.schedule.date == nil {
                d.schedule.date = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
            }
        }
    }

    /// Save the draft; with `thenTest`, hand it straight to a Test run as well.
    func saveRoutineDraft(thenTest: Bool) {
        guard case .draft(let d, _) = routinesView else { return }
        let r: Routine
        do {
            r = try createRoutine(d)
        } catch {
            // Not a fault: the rule the draft broke, said to the person who just pressed Save.
            routineDraftError = (error as? RoutineError)?.message ?? "\(error)"
            return
        }
        if thenTest { fireRoutine(r.id, trigger: .test) }
        routinesView = .detail(r.id)
        routineDraftError = nil
        routineFocus = nil
        routineCursor = routineRows.first
    }

    /// Delete is immediate unless a run is still busy — then it asks, on the actions row.
    func requestDeleteRoutine(_ id: UUID) {
        guard let r = routine(id) else { return }
        if r.runs.contains(where: isBusy), routineConfirmDelete != id {
            routineConfirmDelete = id
            return
        }
        deleteRoutine(id)
        routineConfirmDelete = nil
        routineBack()
    }

    /// A run row jumps to the session it started, leaving the board — if that session is still here.
    func jumpToRoutineRun(_ run: RoutineRun) {
        guard let sid = run.sessionID, let s = session(sid) else { return }
        jump(to: s)
    }

    // MARK: Keyboard

    func moveRoutineCursor(_ delta: Int) {
        keyboardActive = true
        let rows = routineRows
        guard !rows.isEmpty else { return }
        let i = routineCursor.flatMap { rows.firstIndex(of: $0) } ?? -1
        routineCursor = rows[min(max(i + delta, 0), rows.count - 1)]
    }

    /// ↵ / l / → on a board row drives the row's own thing (working.html `activateRoutineRow`).
    func activateRoutineRow() {
        keyboardActive = true
        guard let row = routineCursor ?? routineRows.first else { return }
        routineCursor = row
        switch row {
        case .routine(let id): openRoutine(id)
        case .starter(let i): newRoutineDraft(RoutineStarter.all[i])
        case .run(let runID):
            if case .detail(let id) = routinesView, let run = routine(id)?.runs.first(where: { $0.id == runID }) {
                jumpToRoutineRun(run)
            }
        case .more: routineMoreOpen.toggle()
        case .noRuns: break
        case .field(.branch):
            guard let t = boardDraft?.target.choice else { return }
            let all = RoutineTarget.Choice.allCases
            setBoardTarget(all[(all.firstIndex(of: t)! + 1) % all.count])
        case .field(let f):
            keyboardActive = false
            routineFocus = f
        }
    }

    /// Esc: leave the field you're in, then the routine, then the board — one layer a press.
    func routineEscape() {
        if let f = routineFocus {
            routineFocus = nil
            focusSidebar()
            keyboardActive = true
            routineCursor = .field(f)
            return
        }
        routineBack()
    }
}
