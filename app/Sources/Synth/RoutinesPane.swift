import SwiftUI
import AppKit

/// The Routines board (working.html `renderRoutines`): one board for every project, in the
/// content pane. It borrows Settings' cards and rows outright; what it adds is only what a
/// schedule needs to say — when next, and how the last firing went. This surface answers "did it
/// fire"; the run's branch row answers "what did it find".
struct RoutinesPane: View {
    @Environment(AppStore.self) private var store
    @FocusState private var focus: RoutineField?

    var body: some View {
        VStack(spacing: 0) {
            head
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .frame(maxWidth: 700, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 44)
                }
                .onChange(of: store.routineCursor) { _, row in
                    guard let row, store.keyboardActive else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(row) }
                }
                .onChange(of: store.routinesView.kind) { _, _ in proxy.scrollTo(RtAnchor.top, anchor: .top) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onContinuousHover { phase in
            if case .active = phase, !store.pointerStale { store.keyboardActive = false }
        }
        // The caret follows the store (↵ on a row, Esc, a new draft) and the store follows the
        // caret (a click into a field). Deferred a turn: the field may only be arriving now.
        .onChange(of: store.routineFocus) { _, f in
            guard focus != f else { return }
            DispatchQueue.main.async { focus = f.flatMap { $0.isPopUp ? nil : $0 } }
        }
        .onChange(of: focus) { _, f in
            if store.routineFocus != f, !(store.routineFocus.map(\.isPopUp) ?? false) { store.routineFocus = f }
        }
        .onAppear { DispatchQueue.main.async { focus = store.routineFocus } }
    }

    // MARK: Head (working.html .pane__head)

    private var editing: RoutineDraft? { store.boardDraft }

    private var head: some View {
        HStack(spacing: 10) {
            if store.sidebarCollapsed { SidebarToggle().padding(.trailing, 2) }
            if editing != nil { RtBackButton { store.routineBack() }.padding(.trailing, -4) }
            Phos(path: Phosphor.routine, size: 16).foregroundStyle(Theme.inkMuted).frame(width: 18)
            Text("Routines")
                .font(.sans(13, 600))
                .foregroundStyle(Theme.ink)
            if let d = editing {
                let project = store.workspaces.first { $0.id == d.workspaceID }?.name ?? ""
                (Text(project).foregroundColor(Theme.inkMuted).fontWeight(.medium)
                 + Text(" / \(d.name.isEmpty ? "New routine" : d.name)").foregroundColor(Theme.inkFaint))
                    .font(.mono(11))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 2)
            }
            Spacer(minLength: 0)
            if store.routinesView == .list, !store.routines.isEmpty, !store.workspaces.isEmpty {
                RtButton(title: "New routine", icon: Phosphor.plus) { store.newRoutineDraft() }
            }
        }
        .padding(.leading, store.sidebarCollapsed ? Theme.trafficLightsClearance : 18)
        .padding(.trailing, 18)
        .frame(height: Theme.titlebarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        Color.clear.frame(height: 0).id(RtAnchor.top)
        switch store.routinesView {
        case .list:
            if store.routines.isEmpty { empty } else { list }
        case .detail(let id):
            if let r = store.routine(id) { detail(r) }
        case .draft(let d, let pristine):
            draft(d, pristine: pristine)
        }
    }

    private func selected(_ row: RoutineRow) -> Bool { store.keyboardActive && store.routineCursor == row }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(store.routineGroups, id: \.workspace.id) { group in
                RtSection(label: group.workspace.name) {
                    ForEach(Array(group.routines.enumerated()), id: \.element.id) { i, r in
                        RtItemRow(routine: r, first: i == 0, selected: selected(.routine(r.id)))
                            .id(RoutineRow.routine(r.id))
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Phos(path: Phosphor.routine, size: 26).foregroundStyle(Theme.inkFaint)
                Text("No routines yet")
                    .font(.sans(13, 600)).foregroundStyle(Theme.ink).padding(.top, 10)
                Text("A routine hands an agent the same prompt on a schedule. It runs on this Mac while Synth is open.")
                    .font(.sans(12)).foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center).padding(.top, 4)
                RtButton(title: "New routine", icon: Phosphor.plus, style: .primary) { store.newRoutineDraft() }
                    .padding(.top, 14)
                    .disabled(store.workspaces.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30).padding(.horizontal, 20).padding(.bottom, 22)
            starters.padding(.top, 28)
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 0) {
            RtGroupLabel(text: "Start from")
            let all = Array(RoutineStarter.all.enumerated())
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<(all.count + 1) / 2, id: \.self) { row in
                    GridRow {
                        ForEach(all[(row * 2)..<min(row * 2 + 2, all.count)], id: \.offset) { i, s in
                            RtStarterCard(starter: s, selected: selected(.starter(i))) {
                                store.newRoutineDraft(s)
                            }
                            .id(RoutineRow.starter(i))
                        }
                    }
                }
            }
        }
    }

    // MARK: Detail + draft

    private func detail(_ r: Routine) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailActions(r).padding(.bottom, 18)
            editor(store.boardDraft ?? RoutineDraft(r), next: r.nextSlot(), isDraft: false)
            runs(r).padding(.top, 28)
        }
    }

    private func draft(_ d: RoutineDraft, pristine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                RtButton(title: "Save", style: .primary) { store.saveRoutineDraft(thenTest: false) }
                RtButton(title: "Save and test") { store.saveRoutineDraft(thenTest: true) }
                editorError
                Spacer(minLength: 8)
                RtButton(title: "Cancel") { store.routineBack() }
            }
            .padding(.bottom, 18)
            if pristine { starters.padding(.bottom, 18) }
            editor(d, next: nil, isDraft: true)
        }
    }

    @ViewBuilder private func detailActions(_ r: Routine) -> some View {
        HStack(spacing: 6) {
            if store.routineConfirmDelete == r.id {
                Text("A run is still busy. It carries on; only the routine goes.")
                    .font(.sans(12)).foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RtButton(title: "Delete", style: .danger) { store.requestDeleteRoutine(r.id) }
                RtButton(title: "Cancel") { store.routineConfirmDelete = nil }
            } else {
                RtButton(title: "Run now", style: .primary, kbd: "⌘R") { store.fireRoutine(r.id, trigger: .runNow) }
                RtButton(title: "Test") { store.fireRoutine(r.id, trigger: .test) }
                editorError
                Spacer(minLength: 8)
                RtButton(title: "Delete", style: .danger) { store.requestDeleteRoutine(r.id) }
            }
        }
    }

    /// Why the draft or the edit on screen isn't saved, beside the buttons that act on it.
    @ViewBuilder private var editorError: some View {
        if let err = store.routineDraftError {
            Text(err).font(.sans(12)).foregroundStyle(Theme.danger)
                .lineLimit(1).truncationMode(.tail).padding(.leading, 6)
        }
    }

    private func editor(_ d: RoutineDraft, next: Date?, isDraft: Bool) -> some View {
        let ws = store.workspaces.first { $0.id == d.workspaceID }
        let branches = ws?.liveBranches.map(\.name) ?? []
        let agentName = RoutineWords.agent(d.agent)
        let schedDesc = isDraft
            ? d.schedule.catchUpWords
            : next.map { "Next: \(RoutineWords.when($0))" } ?? "Ran — it won't fire again."
        return RtCard {
            RtRow("Name", row: .field(.name), first: true, selected: selected(.field(.name))) {
                TextField("", text: bind(d, \.name), prompt: Text("Morning brief"))
                    .rtInput(width: 260, focused: focus == .name)
                    .focused($focus, equals: .name)
            }
            RtRow("Project", row: .field(.project), selected: selected(.field(.project))) {
                RtPop(field: .project,
                      options: store.workspaces.map { ($0.id, $0.name) },
                      selection: d.workspaceID) { store.setBoardProject($0) }
            }
            RtRow("Prompt", row: .field(.prompt),
                  desc: "Handed to the agent every run, after one line from Synth naming the routine and when it was meant to run.",
                  selected: selected(.field(.prompt))) {
                EmptyView()
            } body: {
                RtPromptEditor(text: bind(d, \.prompt), focused: focus == .prompt)
                    .focused($focus, equals: .prompt)
                    .padding(.top, 9)
            }
            RtRow("Agent", row: .field(.agent), selected: selected(.field(.agent))) {
                let agents = store.availableAgents.map { ($0.id, $0.displayName) }
                RtPop(field: .agent,
                      options: agents.contains { $0.0 == d.agent } ? agents : [(d.agent, agentName)] + agents,
                      selection: d.agent) { a in store.editBoardRoutine { $0.agent = a } }
            }
            RtRow("Branch", row: .field(.branch), desc: d.target.choice.desc, selected: selected(.field(.branch))) {
                RtSeg(selection: d.target.choice) { store.setBoardTarget($0) }
            } body: {
                HStack(spacing: 8) {
                    if case .existing(let b) = d.target {
                        RtPop(field: .branch,
                              options: (branches.contains(b) ? branches : [b] + branches).map { ($0, $0) },
                              selection: b) { name in store.editBoardRoutine { $0.target = .existing(branch: name) } }
                    } else {
                        Text(d.previewRoutine.branchName(for: .schedule, at: Date()))
                            .font(.mono(11)).foregroundStyle(Theme.ink3)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.top, 8)
            }
            RtRow("Schedule", row: .field(.schedule), desc: schedDesc, selected: selected(.field(.schedule))) {
                scheduleControls(d.schedule)
            }
            RtMoreRow(open: store.routineMoreOpen, selected: selected(.more)) { store.routineMoreOpen.toggle() }
                .id(RoutineRow.more)
            if store.routineMoreOpen {
                if d.target.choice != .existing {
                    let base = store.effectiveBase(d)
                    RtRow("Base", row: .field(.base),
                          desc: "What each new branch is cut from. Fetched first; if the fetch fails, the local copy is used and the run says so.",
                          selected: selected(.field(.base))) {
                        RtPop(field: .base,
                              options: (base.map { branches.contains($0) ? branches : [$0] + branches } ?? branches).map { ($0, $0) },
                              selection: base ?? "") { b in store.editBoardRoutine { $0.base = b } }
                    }
                }
                RtRow("Extra flags", row: .field(.flags),
                      desc: "Added after \(ws?.name ?? "the project")'s own flags for \(agentName), for this routine only. The model goes here too.",
                      selected: selected(.field(.flags))) {
                    EmptyView()
                } body: {
                    RtFlagsBox(binary: AgentRegistry.descriptor(d.agent)?.binaryName ?? d.agent.rawValue,
                               text: bind(d, \.extraFlags), focused: focus == .flags)
                        .focused($focus, equals: .flags)
                        .padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder private func scheduleControls(_ s: RoutineSchedule) -> some View {
        HStack(spacing: 8) {
            RtPop(field: .schedule, options: RoutineSchedule.Kind.allCases.map { ($0, $0.label) },
                  selection: s.kind) { store.setBoardScheduleKind($0) }
            if s.kind == .weekly {
                RtPop(field: nil, options: (1...7).map { ($0, RoutineWords.weekday($0)) },
                      selection: s.weekday) { w in store.editBoardRoutine { $0.schedule.weekday = w } }
            }
            if s.kind == .once {
                DatePicker("", selection: Binding(
                    get: { s.date ?? Date() },
                    set: { v in store.editBoardRoutine { $0.schedule.date = Calendar.current.startOfDay(for: v) } }),
                           displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden().fixedSize()
                    .rtFieldBox()
            }
            if s.kind != .hourly {
                DatePicker("", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: Date()) ?? Date() },
                    set: { v in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: v)
                        store.editBoardRoutine { $0.schedule.hour = c.hour ?? 9; $0.schedule.minute = c.minute ?? 0 }
                    }),
                           displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field).labelsHidden().fixedSize()
                    .rtFieldBox()
            }
        }
    }

    @ViewBuilder private func runs(_ r: Routine) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RtGroupLabel(text: "Runs")
            RtCard {
                if r.runs.isEmpty {
                    let next = r.nextSlot()
                    RtRow("No runs yet", row: .noRuns,
                          desc: next.map { "The first one is \(RoutineWords.when($0)). Run now or Test to see it sooner." }
                              ?? "Run now or Test to see one.",
                          first: true, selected: selected(.noRuns)) { EmptyView() }
                } else {
                    ForEach(Array(r.runs.enumerated()), id: \.element.id) { i, run in
                        RtRunRow(run: run, first: i == 0, selected: selected(.run(run.id)))
                            .id(RoutineRow.run(run.id))
                    }
                }
            }
        }
    }

    private func bind(_ d: RoutineDraft, _ key: WritableKeyPath<RoutineDraft, String>) -> Binding<String> {
        Binding(get: { store.boardDraft?[keyPath: key] ?? d[keyPath: key] },
                set: { v in store.editBoardRoutine { $0[keyPath: key] = v } })
    }
}

private enum RtAnchor: Hashable { case top }

private extension RoutinesView {
    /// Which screen, ignoring what's typed into it — a scroll reset per screen, not per keystroke.
    var kind: Int {
        switch self {
        case .list: 0
        case .detail: 1
        case .draft: 2
        }
    }
}

extension RoutineDraft {
    /// A throwaway routine carrying the draft's fields, so a branch name is previewed by the same
    /// rule a run will cut it by.
    var previewRoutine: Routine {
        Routine(id: UUID(), name: name, workspaceID: workspaceID, prompt: prompt, agent: agent, target: target,
                base: base, extraFlags: extraFlags, schedule: schedule, runs: [], failureUnseen: false, lastSlot: nil)
    }
}

// MARK: - Tokens the board adds (working.html --on-accent / --tui-red / --set-inherit)

private enum RtInk {
    static let onAccent = Theme.dyn(0xFFFFFF, 0x191B1F)
    static let danger = Theme.dyn(0xA2241A, 0xFF8A80)
    static let setInherit = Color(hex: 0x8B8E96)
    static let lineSoft = Theme.mono(0.06, 0.07)
}

// MARK: - Cards, rows, labels (working.html .set-grp / .set-card / .set-row)

private struct RtGroupLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.sans(10, 600)).kerning(0.6)
            .foregroundStyle(Theme.navLabel)
            .padding(.leading, 2).padding(.bottom, 10)
    }
}

private struct RtCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
    }
}

private struct RtSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RtGroupLabel(text: label)
            RtCard { content }
        }
    }
}

/// The keyboard ring and hover fill every board row shares — Settings' row chrome, clipped by the
/// card rather than rounded itself.
private struct RtRowChrome: ViewModifier {
    let first: Bool
    let selected: Bool
    var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.rowSelected : (hovering ? Theme.rowHover : Color.clear))
            .overlay(Rectangle().strokeBorder(Theme.selRing, lineWidth: 1.5).opacity(selected ? 1 : 0))
            .overlay(alignment: .top) { if !first { Rectangle().fill(RtInk.lineSoft).frame(height: 0.5) } }
    }
}

/// One editor row: label and control on a line, the description under it, a full-width body
/// beneath both (working.html `row()`).
private struct RtRow<Control: View, Body: View>: View {
    let label: String
    let row: RoutineRow
    var desc: String? = nil
    var first = false
    let selected: Bool
    @ViewBuilder var control: Control
    @ViewBuilder var rowBody: Body

    init(_ label: String, row: RoutineRow, desc: String? = nil, first: Bool = false, selected: Bool,
         @ViewBuilder control: () -> Control, @ViewBuilder body: () -> Body = { EmptyView() }) {
        self.label = label; self.row = row; self.desc = desc; self.first = first; self.selected = selected
        self.control = control(); self.rowBody = body()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(label).font(.sans(13, 550)).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                control
            }
            .frame(minHeight: 24)
            if let desc {
                Text(desc).font(.sans(12)).foregroundStyle(Theme.inkMuted)
                    .lineSpacing(2.4).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            rowBody
        }
        .modifier(RtRowChrome(first: first, selected: selected))
        .id(row)
    }
}

private struct RtMoreRow: View {
    let open: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Phos(path: Phosphor.caret, size: 11).foregroundStyle(Theme.inkFaint)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.185), value: open)
                Text("More").font(.sans(13, 550)).foregroundStyle(Theme.ink3)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)
            .modifier(RtRowChrome(first: false, selected: selected, hovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - List row

private struct RtItemRow: View {
    @Environment(AppStore.self) private var store
    let routine: Routine
    let first: Bool
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        Button { store.openRoutine(routine.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Text(routine.name).font(.sans(13, 550)).foregroundStyle(Theme.ink)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(routine.nextSlot().map { "Next \(RoutineWords.when($0))" } ?? "Ran")
                        .font(.mono(11)).foregroundStyle(Theme.inkMeta).monospacedDigit()
                    Phos(path: Phosphor.caret, size: 11).foregroundStyle(Theme.inkFaint)
                }
                .frame(minHeight: 24)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text([routine.schedule.words, RoutineWords.target(routine.target, slug: routine.slug),
                          RoutineWords.agent(routine.agent)].joined(separator: " · "))
                        .font(.sans(12)).foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let last = routine.runs.first {
                        let o = store.outcome(last)
                        RtOutcome(outcome: o, text: o == .ran ? "Ran \(RoutineWords.when(last.firedAt))" : o.word, small: true)
                    }
                }
            }
            .modifier(RtRowChrome(first: first, selected: selected, hovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Run row

private struct RtRunRow: View {
    @Environment(AppStore.self) private var store
    let run: RoutineRun
    let first: Bool
    let selected: Bool
    @State private var hovering = false

    private var live: Bool { run.sessionID.flatMap { store.session($0) } != nil }

    var body: some View {
        Button { store.jumpToRoutineRun(run) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    RtOutcome(outcome: store.outcome(run), text: store.outcome(run).word)
                    if let badge = run.trigger.badge {
                        Text(badge).font(.sans(10, 600)).kerning(0.2).foregroundStyle(Theme.inkFaint)
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.rowSelected))
                    }
                    Text(run.branch ?? "").font(.mono(11)).foregroundStyle(Theme.ink4)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    when
                }
                .frame(minHeight: 24)
                if let reason = run.reason {
                    Text(reason).font(.sans(12)).foregroundStyle(Theme.inkMuted)
                        .lineSpacing(2.4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .modifier(RtRowChrome(first: first, selected: selected, hovering: hovering && live))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(live)
        .onHover { hovering = $0 }
    }

    /// When it fired, and the slot it was for when those differ. A skip never fired: it shows
    /// the slot it let go.
    private var when: some View {
        let skipped = run.outcome == .skipped
        let at = skipped ? run.slot ?? run.firedAt : run.firedAt
        let forSlot = skipped ? nil : run.slot.flatMap { RoutineWords.time($0) != RoutineWords.time(at) ? $0 : nil }
        return (Text(RoutineWords.when(at)).foregroundColor(Theme.inkMeta)
                + Text(forSlot.map { " for \(RoutineWords.time($0))" } ?? "").foregroundColor(Theme.inkFaint))
            .font(.mono(11)).monospacedDigit()
    }
}

/// Outcome of a firing, not of the work: green only means "it started".
private struct RtOutcome: View {
    let outcome: RoutineOutcomeWord
    let text: String
    var small = false

    var body: some View {
        HStack(spacing: 6) {
            dot.frame(width: 7, height: 7)
            Text(text).font(.sans(small ? 11 : 12, small ? 500 : 550))
                .foregroundStyle(outcome == .failed ? Theme.danger : Theme.ink3)
                .lineLimit(1)
        }
        .fixedSize()
    }

    @ViewBuilder private var dot: some View {
        switch outcome {
        case .ran: Circle().fill(Theme.run)
        case .running: Circle().fill(Theme.working)
        case .queued: Circle().strokeBorder(Theme.working, lineWidth: 1.5)
        case .skipped: Circle().strokeBorder(Theme.inkMeta, lineWidth: 1.5)
        case .failed: Circle().fill(Theme.danger)
        }
    }
}

// MARK: - Starters

private struct RtStarterCard: View {
    let starter: RoutineStarter
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(starter.name).font(.sans(13, 550)).foregroundStyle(Theme.ink)
                Text("\(starter.schedule.words) · \(starter.target.choice.label.lowercased())")
                    .font(.sans(11)).foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11)
                .fill(selected ? Theme.rowSelected : (hovering ? Theme.rowHover : Theme.raised)))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .strokeBorder(selected ? Theme.selRing : (hovering ? Theme.mono(0.16, 0.2) : Theme.border),
                              lineWidth: selected ? 1.5 : 0.5))
            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Controls

/// working.html `.tpl-add__btn`, plus the board's primary and red variants.
private struct RtButton: View {
    enum Style { case plain, primary, danger }
    let title: String
    var icon: String? = nil
    var style: Style = .plain
    var kbd: String? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Phos(path: icon, size: 12).foregroundStyle(style == .primary ? RtInk.onAccent : Theme.inkFaint) }
                Text(title).font(.sans(12, style == .primary ? 600 : 550)).foregroundStyle(ink)
                if let kbd {
                    Text(kbd).font(.sans(11, 500)).foregroundStyle(ink.opacity(0.7)).padding(.leading, 3)
                }
            }
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(stroke, lineWidth: 0.5))
            .brightness(style == .primary && hovering ? 0.04 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(RtPressStyle())
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }

    private var ink: Color {
        switch style {
        case .primary: RtInk.onAccent
        case .danger: RtInk.danger
        case .plain: hovering ? Theme.ink : Theme.ink3
        }
    }
    private var fill: Color {
        switch style {
        case .primary: Theme.accent
        case .danger: hovering ? Theme.danger.opacity(0.08) : Theme.raised
        case .plain: hovering ? Theme.rowHover : Theme.raised
        }
    }
    private var stroke: Color {
        switch style {
        case .primary: .clear
        case .danger: hovering ? Theme.danger.opacity(0.35) : Theme.line
        case .plain: hovering ? Theme.mono(0.16, 0.2) : Theme.line
        }
    }
}

private struct RtPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct RtBackButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Phos(path: Phosphor.caret, size: 12)
                .rotationEffect(.degrees(180))
                .foregroundStyle(hovering ? Theme.ink : Theme.inkMeta)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.rowSelected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("All routines (Esc)")
        .onHover { hovering = $0 }
    }
}

/// Three targets as one pick. Plain buttons rather than Settings' sliding seg: on this board h
/// is "back", so the control can't also claim it.
private struct RtSeg: View {
    let selection: RoutineTarget.Choice
    let pick: (RoutineTarget.Choice) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(RoutineTarget.Choice.allCases, id: \.self) { c in
                let on = c == selection
                Button { pick(c) } label: {
                    Text(c.label).font(.sans(12, 550))
                        .foregroundStyle(on ? Theme.ink : Theme.ink4)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.raised : .clear)
                            .shadow(color: on ? .black.opacity(0.08) : .clear, radius: 1, y: 1)
                            .overlay(on ? RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.mono(0.06, 0.08), lineWidth: 0.5) : nil))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.rowHover)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RtInk.lineSoft, lineWidth: 0.5)))
    }
}

/// A pop-up button (working.html `.set-pop`): the closed button is ours, the menu is the system's,
/// so it sizes, scrolls and takes arrow keys itself. ↵ on the row opens it from the keyboard.
struct RtPop<Value: Hashable>: View {
    @Environment(AppStore.self) private var store
    /// The editor row whose ↵ opens this one; nil for a second pop-up on the same row.
    let field: RoutineField?
    let options: [(Value, String)]
    let selection: Value
    let pick: (Value) -> Void
    @State private var anchor = RtAnchorBox()
    @State private var hovering = false

    var body: some View {
        Button(action: show) {
            HStack(spacing: 0) {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                    .font(.sans(12, 550)).foregroundStyle(hovering ? Theme.ink : Theme.ink3)
                    .lineLimit(1)
                Phos(path: Phosphor.caret, size: 11).foregroundStyle(Theme.inkFaint)
                    .rotationEffect(.degrees(90)).padding(.leading, 6)
            }
            .fixedSize()
            .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.rowHover : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(hovering ? Theme.mono(0.16, 0.2) : Theme.line, lineWidth: 0.5))
            .background(RtAnchorView(box: anchor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onChange(of: opening) { _, now in if now { openFromKeyboard() } }
    }

    /// The branch row's ↵ cycles the segmented control, so its branch pop-up never opens by key.
    private var opening: Bool { field?.isPopUp == true && store.routineFocus == field }

    private func openFromKeyboard() {
        store.routineFocus = nil
        store.keyboardActive = true
        show()
    }

    private func show() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        let target = RtMenuTarget()
        for (i, (value, label)) in options.enumerated() {
            let item = NSMenuItem(title: label, action: #selector(RtMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = i
            item.state = value == selection ? .on : .off
            menu.addItem(item)
        }
        let current = options.firstIndex { $0.0 == selection }.flatMap { menu.item(at: $0) }
        menu.popUp(positioning: current, at: NSPoint(x: 0, y: view.isFlipped ? 0 : view.bounds.height), in: view)
        if let i = target.picked { pick(options[i].0) }
    }
}

final class RtAnchorBox { weak var view: NSView? }

private struct RtAnchorView: NSViewRepresentable {
    let box: RtAnchorBox
    func makeNSView(context: Context) -> NSView { let v = NSView(); box.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { box.view = v }
}

private final class RtMenuTarget: NSObject {
    var picked: Int?
    @objc func pick(_ sender: NSMenuItem) { picked = sender.tag }
}

// MARK: - Fields

private extension View {
    /// working.html `.rt-input`, with its accent focus ring.
    func rtInput(width: CGFloat, focused: Bool) -> some View {
        self.textFieldStyle(.plain)
            .font(.sans(13)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent.opacity(0.22), lineWidth: 2.5)
                .padding(-1.25).opacity(focused ? 1 : 0))
    }
}

private extension View {
    /// The date and time pickers draw no box of their own; this is `.rt-input`'s.
    func rtFieldBox() -> some View {
        padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

private struct RtPromptEditor: View {
    @Binding var text: String
    let focused: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("What should the agent do each time?")
                    .font(.sans(13)).foregroundStyle(Theme.inkFaint)
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.sans(13)).foregroundStyle(Theme.ink)
                .lineSpacing(13 * 0.55 - 3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8).padding(.vertical, 11)
        }
        .frame(minHeight: 112)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(focused ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 0.5))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.22), lineWidth: 2.5)
            .padding(-1.25).opacity(focused ? 1 : 0))
    }
}

/// The routine's own flags on the dark launch line Settings uses for an agent's flags.
private struct RtFlagsBox: View {
    let binary: String
    @Binding var text: String
    let focused: Bool
    private static let ink = Color(hex: 0xD4D6DC)
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("$").foregroundStyle(RtInk.setInherit)
            Text(binary).foregroundStyle(RtInk.setInherit)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("--model opus").foregroundStyle(Self.ink.opacity(0.30)).allowsHitTesting(false)
                }
                TextField("", text: $text).textFieldStyle(.plain).foregroundStyle(Self.ink)
            }
        }
        .font(.mono(12))
        .padding(.horizontal, 15).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.termBg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.22), lineWidth: 2.5)
            .padding(-1.25).opacity(focused ? 1 : 0))
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
    }
}
