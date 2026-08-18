import SwiftUI

/// The full-screen Settings content pane (working.html renderSettings). It fills the content
/// pane while the sidebar tree stays live. Two tabs in the head — `Synth` (the app itself,
/// plus the defaults every project starts from) and the project you're currently in. A
/// project holds only its DELTA, shown layered on the shared base in run order: setup script
/// after a collapsible shared strip, flags as an inline `$ claude <shared> <yours>` line,
/// sessions added below the locked shared ones. Empty delta = pure inheritance.
struct SettingsPane: View {
    @Environment(AppStore.self) private var store

    private var tab: SettingsTab { store.settingsTab }
    private var project: Workspace? { store.settingsProject }

    var body: some View {
        VStack(spacing: 0) {
            head
            ScrollView {
                Group {
                    // No project tab without a project — fall through to the Synth tab, which
                    // itself carries the "add a project" prompt when there are none.
                    if tab == .project, let ws = project {
                        projectTab(ws)
                    } else {
                        appTab
                    }
                }
                .frame(maxWidth: 660, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Head — title + tab strip (working.html .pane__head + .set-tabs)

    private var head: some View {
        HStack(spacing: 10) {
            if store.sidebarCollapsed { SidebarToggle().padding(.trailing, 2) }
            Phos(path: Phosphor.gear, size: 16).foregroundStyle(Theme.inkMuted).frame(width: 18)
            Text("Settings")
                .font(.sans(13, 600))
                .foregroundStyle(Theme.ink)
            tabStrip.padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .padding(.leading, store.sidebarCollapsed ? Theme.trafficLightsClearance : 18)
        .padding(.trailing, 18)
        .frame(height: Theme.titlebarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            SetTab(label: "Synth", on: tab == .app || project == nil) { store.settingsTab = .app }
            if let ws = project {
                SetTab(label: ws.name, workspace: ws, on: tab == .project) { store.settingsTab = .project }
            }
        }
        .frame(height: Theme.titlebarHeight, alignment: .bottom)
    }

    // MARK: App tab — app settings + the shared defaults every project layers on

    @ViewBuilder private var appTab: some View {
        VStack(alignment: .leading, spacing: 28) {
            SetSection(label: "Appearance") {
                SetToggleRow(label: "Theme", desc: "Follows macOS unless you pin it.") { ThemeSeg() }
            }
            SetSection(label: "Markdown") {
                SetToggleRow(label: "Open .md in",
                             desc: "Clicking a markdown link, and the `synth` command.") {
                    MarkdownOpenSeg()
                }
            }
            SetSection(label: "Notification sounds") {
                switchRow("Session finished", "A background agent stopped working.", bind(\.soundDone))
                SetDivider()
                switchRow("Needs input", "An agent is waiting on you.", bind(\.soundNeedsInput))
                SetDivider()
                switchRow("Command failed", "A terminal command exited non-zero.", bind(\.soundError))
            }
            SetSection(label: "MCP servers") {
                // No tool counts in these lines: the browser row claimed 13 for months while the
                // server grew past 20, and a number nobody can see is wrong is worse than none.
                switchRow("Browser", "Lets an agent drive and inspect browser sessions.",
                          bind(\.mcpBrowserEnabled))
                SetDivider()
                switchRow("Simulator", "Lets an agent drive simulator sessions — tap, type, screenshot.",
                          bind(\.mcpSimulatorEnabled))
                SetDivider()
                switchRow("Synth app", "Lets an agent create worktrees.", bind(\.mcpAppEnabled))
            }
            SetSection(label: "New worktree defaults") {
                SetEditorRow(label: "Setup script", desc: "Runs once in each new worktree, after it's created.") {
                    ScriptEditor(caption: "setup.sh",
                                 note: "$SYNTH_MAIN = primary checkout · 5 min limit",
                                 text: bind(\.globalScript),
                                 placeholder: "# bash. Runs in the new worktree.")
                }
                SetDivider()
                SetEditorRow(label: "Sessions", desc: "Every new worktree opens with these. The first one opens.") {
                    VStack(alignment: .leading, spacing: 8) {
                        TplList(entries: bind(\.globalSessionTemplate),
                                emptyText: "No sessions — new worktrees open empty.",
                                opensIndex: store.templateOpensAt(store.globalSessionTemplate))
                        TplAddBar(entries: bind(\.globalSessionTemplate))
                    }
                }
            }
            // The flags you'd set for an agent are exactly what you don't need once it's off, so
            // the switch and the field live on one row: off greys the row and takes the field
            // with it. The row itself stays, at the same height — the switch that brings the
            // agent back has to be somewhere you can find it, and a collapsing row would shove
            // everything below it.
            // A built-in row leads with its binary, because the binary is the whole identity. The
            // user's own agents follow, each stating the three things a built-in never has to:
            // what it is called, what Synth runs, and whose machinery reads it.
            SetSection(label: "Agents") {
                let builtIns = AgentRegistry.installed.filter { !$0.isCustom }
                ForEach(Array(builtIns.enumerated()), id: \.element.id) { i, agent in
                    if i > 0 { SetDivider() }
                    let on = store.isAgentEnabled(agent.id)
                    SetEditorRow(label: agent.binaryName,
                                 desc: "Flags added to every \(agent.binaryName) launch.",
                                 dimmed: !on,
                                 // A switch has no text baseline, so the row's firstTextBaseline
                                 // HStack would fall back to its bottom edge and sit it low —
                                 // pin its centre to the label's baseline instead.
                                 trailing: {
                                     switchControl(agentEnabledBinding(agent))
                                         .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                 }) {
                        FlagField(text: globalFlagsBinding(agent), placeholder: agent.exampleFlags,
                                  enabled: on)
                    }
                    .animation(.easeOut(duration: 0.15), value: on)
                }
                ForEach(store.customAgents) { agent in
                    if !builtIns.isEmpty || agent.id != store.customAgents.first?.id { SetDivider() }
                    CustomAgentRow(agent: agent)
                }
                SetDivider()
                SetToggleRow(label: "Add an agent", desc: store.customAgents.isEmpty
                    ? "Point Synth at a command of your own — a second Claude Code with its own config, say. It runs as one of the agents above, and looks like it."
                    : "Another command Synth runs as one of the agents above.") {
                    AddAgentButton()
                }
            }
            SetSection(label: "Privacy") {
                SetToggleRow(label: "Anonymous analytics", desc: "Usage counts only. No code, prompts or paths.") {
                    switchControl(bind(\.analyticsEnabled))
                }
            }
            // Only the switch carries a description, and only the half of it you can't read off
            // the controls: that the sweep touches nothing unrecoverable. Each picker states its
            // own rule — a sentence under "Never · 7 · 14 · 30 days" would say it again, slower.
            //
            // Every row after the switch folds away when it's off: what remains has nothing to
            // configure, and unlike the agent rows there's no field here whose absence would hide
            // the way back.
            SetSection(label: "Archived worktrees") {
                switchRow("Clean up archived worktrees",
                          "Only once the work is safely on a remote. The git branch is never deleted.",
                          bind(\.archiveSweepEnabled))
                if store.archiveSweepEnabled {
                    SetDivider()
                    SetToggleRow(label: "Wait before cleaning up") {
                        SetSeg(options: [(0, "Never"), (7, "7 days"), (14, "14 days"), (30, "30 days")],
                               selection: bind(\.archiveGraceDays), width: SegWidth.four)
                    }
                    SetDivider()
                    // A budget can only bring an unblocked folder's turn forward — it never lets
                    // one through a gate. That fact is carried by the verdicts on the Archived
                    // rows, where it is about a folder you can see, rather than asserted here as
                    // a caption nobody reads twice.
                    SetToggleRow(label: "Most worktrees archived") {
                        SetSeg(options: [(10, "10"), (25, "25"), (50, "50"), (0, "No cap")],
                               selection: bind(\.archiveMaxCount), width: SegWidth.four)
                    }
                    SetDivider()
                    SetToggleRow(label: "Most disk archived") {
                        SetSeg(options: [(20, "20 GB"), (50, "50 GB"), (100, "100 GB"), (0, "No cap")],
                               selection: bind(\.archiveMaxGB), width: SegWidth.four)
                    }
                }
            }
            SetSection(label: "Experimental") {
                switchRow("Tabs", "Two-level sidebar with a tab strip of the branch's sessions. A work-in-progress preview.", bind(\.tabsMode))
                switchRow("Simulator sessions",
                          "Run an iOS simulator as a session: its live screen in a pane, tappable, and drivable by Claude. Needs a full Xcode. Uses Apple's private simulator frameworks, so a future Xcode can degrade it — it will say so rather than fail quietly.",
                          bind(\.simulatorSessionsEnabled))
            }
            SetSection(label: "About") { aboutRow }
            if store.workspaces.isEmpty { emptyProject }
        }
    }

    private var aboutRow: some View {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        return AboutRow(version: "Synth \(short)\(build)")
    }

    // MARK: Project tab — deltas layered on the shared base

    @ViewBuilder private func projectTab(_ ws: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            SetSection(label: "New worktree") {
                SetEditorRow(label: "Setup script",
                             desc: skipScript(ws) ? "Runs instead of the shared setup." : "Runs after the shared setup.",
                             trailing: { if hasScriptDelta(ws) { ClearButton { clearScript(ws) } } }) {
                    VStack(spacing: 0) {
                        SharedSetupStrip(base: store.globalScript, skip: skipBinding(ws), projectName: ws.name,
                                         editInSynth: { store.settingsTab = .app })
                        ProjectScriptEditor(text: scriptBinding(ws), projectName: ws.name)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                SetDivider()
                SetEditorRow(label: "Sessions", desc: "Opens after the shared sessions.",
                             trailing: { if hasSessionsDelta(ws) { ClearButton { clearSessions(ws) } } }) {
                    LayeredSessions(shared: store.globalSessionTemplate, own: sessionsBinding(ws))
                }
            }
            // A switched-off agent drops out here entirely rather than greying: the switch is
            // app-level, so repeating a dead row in every project is the clutter this removes.
            // The project's flags for it stay in the delta, waiting.
            let agents = store.availableAgents
            if !agents.isEmpty {
                SetSection(label: "Agents") {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { i, agent in
                        if i > 0 { SetDivider() }
                        let shared = (store.globalAgentFlags[agent.id] ?? "").trimmingCharacters(in: .whitespaces)
                        SetEditorRow(label: agent.binaryName,
                                     desc: shared.isEmpty ? "Flags for \(agent.binaryName) launches." : "Added after the shared \(agent.binaryName) flags.",
                                     trailing: { if hasFlagsDelta(ws, agent) { ClearButton { clearFlags(ws, agent) } } }) {
                            FlagLineField(binary: agent.binaryName, shared: shared,
                                          tail: wsFlagsBinding(ws, agent), placeholder: agent.exampleFlags)
                        }
                    }
                }
            }
            SetSection(label: "Browser") { BrowsingData(workspace: ws) }
            SetSection(label: "Archived") { ArchivedWorktrees(workspace: ws) }
        }
    }

    private var emptyProject: some View {
        SetSection(label: "Projects") {
            VStack(spacing: 0) {
                Phos(path: Phosphor.folder, size: 26).foregroundStyle(Theme.inkFaint)
                Text("No projects yet")
                    .font(.sans(13, 600))
                    .foregroundStyle(Theme.ink).padding(.top, 10)
                Text("Add a project to set what its worktrees open with.")
                    .font(.sans(12)).foregroundStyle(Theme.inkMuted).padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34).padding(.horizontal, 20)
        }
    }

    // MARK: Row helpers

    private func switchRow(_ label: String, _ desc: String, _ binding: Binding<Bool>) -> some View {
        SetToggleRow(label: label, desc: desc) { switchControl(binding) }
    }

    private func switchControl(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding)
            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
    }

    // MARK: Bindings — app settings + per-project deltas

    private func bind<V>(_ key: ReferenceWritableKeyPath<AppStore, V>) -> Binding<V> {
        Binding(get: { store[keyPath: key] }, set: { store[keyPath: key] = $0 })
    }

    private func agentEnabledBinding(_ agent: AgentDescriptor) -> Binding<Bool> {
        Binding(get: { store.isAgentEnabled(agent.id) },
                set: { store.agentEnabledPrefs[agent.id.rawValue] = $0 })
    }

    private func globalFlagsBinding(_ agent: AgentDescriptor) -> Binding<String> {
        Binding(get: { store.globalAgentFlags[agent.id] ?? "" }, set: { store.globalAgentFlags[agent.id] = $0 })
    }

    private func scriptBinding(_ ws: Workspace) -> Binding<String> {
        Binding(get: { store.wsScripts[ws.id] ?? "" }, set: { store.wsScripts[ws.id] = $0 })
    }
    private func skipBinding(_ ws: Workspace) -> Binding<Bool> {
        Binding(get: { store.wsSkipScript[ws.id] ?? false }, set: { store.wsSkipScript[ws.id] = $0 })
    }
    private func sessionsBinding(_ ws: Workspace) -> Binding<[SessionTemplateEntry]> {
        Binding(get: { store.wsSessionTemplates[ws.id] ?? [] }, set: { store.wsSessionTemplates[ws.id] = $0 })
    }
    private func wsFlagsBinding(_ ws: Workspace, _ agent: AgentDescriptor) -> Binding<String> {
        Binding(get: { store.wsAgentFlags[ws.id]?[agent.id] ?? "" },
                set: { store.wsAgentFlags[ws.id, default: [:]][agent.id] = $0 })
    }

    // MARK: Delta presence + clear

    private func skipScript(_ ws: Workspace) -> Bool { store.wsSkipScript[ws.id] ?? false }
    private func hasScriptDelta(_ ws: Workspace) -> Bool {
        !(store.wsScripts[ws.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || skipScript(ws)
    }
    private func hasSessionsDelta(_ ws: Workspace) -> Bool { !(store.wsSessionTemplates[ws.id] ?? []).isEmpty }
    private func hasFlagsDelta(_ ws: Workspace, _ agent: AgentDescriptor) -> Bool {
        !(store.wsAgentFlags[ws.id]?[agent.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
    private func clearScript(_ ws: Workspace) { store.wsScripts[ws.id] = nil; store.wsSkipScript[ws.id] = nil }
    private func clearSessions(_ ws: Workspace) { store.wsSessionTemplates[ws.id] = nil }
    private func clearFlags(_ ws: Workspace, _ agent: AgentDescriptor) { store.wsAgentFlags[ws.id]?[agent.id] = nil }
}

// MARK: - Tab strip (working.html .set-tab)

private struct SetTab: View {
    let label: String
    var workspace: Workspace? = nil
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let workspace { WsChip(workspace: workspace, size: 15) }
                Text(label)
                    .font(.sans(13, 550))
                    .foregroundStyle(on ? Theme.ink : (hovering ? Theme.ink2 : Theme.ink4))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).frame(height: Theme.titlebarHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.accent).frame(height: 2)
                    .padding(.horizontal, 10).opacity(on ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Section + row primitives (working.html .set-grp / .set-card / .set-row)

/// A settings section: an uppercase label above a card of rows.
private struct SetSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.sans(10, 600)).kerning(0.6)
                .foregroundStyle(Theme.navLabel)
                .padding(.leading, 2).padding(.bottom, 10)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
        }
    }
}

private struct SetDivider: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 0.5) }
}

/// A row whose control fits on the line — label + description left, control right.
private struct SetToggleRow<Control: View>: View {
    let label: String
    var desc: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.sans(13, 550)).foregroundStyle(Theme.ink)
                if let desc {
                    Text(desc).font(.sans(12)).foregroundStyle(Theme.inkMuted)
                        .lineSpacing(2.4).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14).padding(.vertical, 11).frame(minHeight: 44)
    }
}

/// A row whose control is a full-width body (editor, session list) beneath the label.
/// `dimmed` greys the label and description (working.html `.set-row--off`) without changing
/// a single metric — the body stays where it is, so a row that switches off doesn't move
/// anything below it.
private struct SetEditorRow<Trailing: View, Body: View>: View {
    let label: String
    var desc: String? = nil
    var dimmed: Bool = false
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Body

    init(label: String, desc: String? = nil, dimmed: Bool = false,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Body) {
        self.label = label; self.desc = desc; self.dimmed = dimmed
        self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One line each, always: the header shares its baseline with a switch, and a desc
            // allowed to wrap in a narrow pane would grow the row and shove the rest of the
            // section down. The label never gives up space; the desc truncates instead.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(.sans(13, 550))
                    .foregroundStyle(dimmed ? Theme.ink4 : Theme.ink)
                    .lineLimit(1).fixedSize()
                if let desc {
                    Text(desc).font(.sans(12))
                        .foregroundStyle(dimmed ? Theme.inkFaint : Theme.inkMuted)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                trailing
            }
            content.padding(.top, 8)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

/// "Clear" — strips a project's whole delta on a row, back to pure inheritance.
private struct ClearButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text("Clear")
                .font(.sans(12, 500))
                .foregroundStyle(hovering ? Theme.ink : Theme.ink4)
                .underline(hovering)
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
    }
}

// MARK: - Script editors (working.html .set-code)

/// The Synth-tab setup-script editor: a caption row (real-cased filename + constraint note)
/// over a dark rounded code editor.
private struct ScriptEditor: View {
    let caption: String
    var note: String? = nil
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(caption).font(.mono(11, 500)).foregroundStyle(Theme.ink4)
                Spacer(minLength: 8)
                if let note { Text(note).font(.sans(11)).foregroundStyle(Theme.inkFaint) }
            }
            CodeEditor(text: $text, placeholder: placeholder, minHeight: 96)
        }
    }
}

/// The project-tab setup-script delta editor — joins under the shared strip (square top).
private struct ProjectScriptEditor: View {
    @Binding var text: String
    let projectName: String
    var body: some View {
        CodeEditor(text: $text, placeholder: "# extra steps for \(projectName) worktrees",
                   minHeight: 96, roundedTopCorners: false)
    }
}

/// The dark editor surface itself (working.html .set-code): a mono TextEditor with a
/// placeholder overlay, on the terminal surface.
private struct CodeEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 96
    var roundedTopCorners: Bool = true

    var body: some View {
        let corners = RoundedCorners(radius: 10, top: roundedTopCorners, bottom: true)
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.mono(12)).foregroundStyle(Color(hex: 0xD4D6DC).opacity(0.30))
                    .padding(.horizontal, 15).padding(.vertical, 13).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.mono(12))
                .foregroundStyle(Color(hex: 0xD4D6DC))
                .lineSpacing(3.6).scrollContentBackground(.hidden)
                .padding(.horizontal, 15).padding(.vertical, 13)
                .frame(minHeight: minHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(corners.fill(Theme.termBg))
        .overlay(corners.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }
}

/// A rounded shape with per-side corner control, so the delta editor can square its top edge
/// where it meets the shared strip.
private struct RoundedCorners: InsettableShape {
    var radius: CGFloat
    var top: Bool
    var bottom: Bool
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let tl = top ? radius : 0, tr = top ? radius : 0
        let bl = bottom ? radius : 0, br = bottom ? radius : 0
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        if tr > 0 { p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        if br > 0 { p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false) }
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        if bl > 0 { p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        if tl > 0 { p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) }
        p.closeSubpath()
        return p
    }
    func inset(by amount: CGFloat) -> RoundedCorners { var c = self; c.inset += amount; return c }
}

/// The shared-setup strip above a project's own steps (working.html .set-shared): a
/// collapsible header revealing the base script (dim, read-only) and a skip toggle.
private struct SharedSetupStrip: View {
    let base: String
    @Binding var skip: Bool
    let projectName: String
    let editInSynth: () -> Void
    @State private var open = false
    @State private var hovering = false

    private var lineCount: Int {
        base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0
            : base.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Phos(path: Phosphor.caret, size: 12).foregroundStyle(Theme.inkFaint)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text("Shared Synth setup · \(lineCount) lines")
                    .font(.sans(12, 500)).foregroundStyle(Theme.ink4)
                Spacer(minLength: 8)
                Button(action: editInSynth) {
                    Text("Edit in Synth").font(.sans(12, 500)).foregroundStyle(Theme.input)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } }

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    Text(base)
                        .font(.mono(11))
                        .foregroundStyle(Color(hex: 0x8B8E96))
                        .strikethrough(skip)
                        .lineSpacing(2.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.termBg))
                    Toggle(isOn: $skip) {
                        Text("Don't run the shared setup in \(projectName)")
                            .font(.sans(11)).foregroundStyle(Theme.inkMuted)
                    }
                    .toggleStyle(.checkbox).controlSize(.small)
                }
                .padding(.horizontal, 11).padding(.bottom, 10)
            }
        }
        .background(Theme.rowHover)
        .overlay(RoundedCorners(radius: 10, top: true, bottom: false).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - Agent flags (working.html .set-code--flags / .set-cmd--edit)

/// The Synth-tab flag field — a single mono line on the dark editor surface.
private struct FlagField: View {
    @Binding var text: String
    let placeholder: String
    /// Off keeps the field exactly where it is, at exactly its height — there is just nothing
    /// to edit for an agent that will never launch, so it greys out, stops taking a caret and
    /// drops out of the tab order (working.html `.set-row--off .set-code--flags`).
    var enabled: Bool = true

    private var ink: Color { enabled ? Color(hex: 0xD4D6DC) : Color(hex: 0x8B8E96) }

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                // The placeholder tracks the field's own ink: opencode and antigravity ship with
                // no default flags, so on an unedited field it is the ONLY text in the row's
                // body, and a placeholder that stayed bright would read as a field still live.
                Text(placeholder).font(.mono(12))
                    .foregroundStyle(ink.opacity(0.30)).allowsHitTesting(false)
            }
            MonoLineField(text: $text, editable: enabled, ink: ink)
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.termBg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }
}

/// One mono line that is always selectable and only sometimes editable — AppKit, because
/// SwiftUI's `TextField` can only be `.disabled`, and disabled takes the field out of
/// hit-testing altogether: the flags you would want to copy somewhere else can't even be
/// selected, and AppKit greys the text a second time on top of the colour we set. Read-only
/// is what "off" means here (working.html's `readonly` + `caret-color: transparent`).
///
/// The same view draws both states, so flipping the switch cannot move a pixel.
private struct MonoLineField: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    let ink: Color

    func makeNSView(context: Context) -> NSTextField {
        let f = KeyLoopField(string: "")
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .mono(12)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.usesSingleLineMode = true
        f.delegate = context.coordinator
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.text = $text
        f.isEditable = editable
        f.isSelectable = true
        f.textColor = NSColor(ink)
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            text.wrappedValue = f.stringValue
        }
    }

    /// Selection is a click; the tab loop is not. A read-only field keeps the first — you can
    /// still reach in and copy — and leaves the key view loop, so tabbing through Settings
    /// walks the switches and fields that still do something.
    private final class KeyLoopField: NSTextField {
        override var canBecomeKeyView: Bool { isEditable }
    }
}

/// The project-tab flag line — `$ claude <shared, dim + locked> <your tail, editable>` on
/// the terminal surface. A tail flag that repeats a shared one strikes the shared token.
private struct FlagLineField: View {
    let binary: String
    let shared: String
    @Binding var tail: String
    let placeholder: String

    private var sharedTokens: [String] { shared.split(whereSeparator: \.isWhitespace).map(String.init) }
    private var tailNames: Set<String> {
        Set(tail.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { $0.hasPrefix("-") }.map { String($0.split(separator: "=").first ?? "") })
    }
    private func name(_ t: String) -> String { String(t.split(separator: "=").first ?? "") }

    var body: some View {
        let blue = Theme.dyn(0x2361C4, 0x8AB4F8)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("$").foregroundStyle(Theme.inkMuted)
            Text(binary).foregroundStyle(Theme.ink)
            ForEach(Array(sharedTokens.enumerated()), id: \.offset) { _, tok in
                Text(tok).foregroundStyle(Theme.inkMuted)
                    .strikethrough(tok.hasPrefix("-") && tailNames.contains(name(tok)))
            }
            TextField(sharedTokens.isEmpty ? placeholder : "add flags", text: $tail)
                .textFieldStyle(.plain).foregroundStyle(blue)
                .frame(minWidth: 90)
        }
        .font(.mono(12))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tuiSolid))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.tuiHair, lineWidth: 1))
    }
}

// MARK: - Custom agents (working.html .set-agent-*)

/// A pill button in the add-bar's shape, for the one-off buttons that aren't in a bar.
private struct SetPillButton: View {
    let icon: String?
    let title: String
    var danger: Bool = false
    let action: () -> Void

    var body: some View {
        TplHover { hovering in
            Button(action: action) {
                HStack(spacing: 5) {
                    if let icon { Phos(path: icon, size: 12).foregroundStyle(Theme.inkFaint) }
                    Text(title).font(.sans(12, 550))
                        .foregroundStyle(danger ? Theme.danger : (hovering ? Theme.ink : Theme.ink3))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? (danger ? Theme.danger.opacity(0.08) : Theme.rowHover) : Theme.raised)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(hovering ? (danger ? Theme.danger.opacity(0.35) : Theme.borderStrong) : Theme.line,
                                      lineWidth: 0.5)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Adding one opens nothing: a row appears at the end of the list, empty, and you type into it.
/// An agent with no command has nothing to launch, so nothing offers it — which is exactly what
/// lets the row exist before it is finished.
private struct AddAgentButton: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        SetPillButton(icon: Phosphor.plus, title: "Add agent") {
            withAnimation(.easeOut(duration: 0.15)) { _ = store.addCustomAgent() }
        }
    }
}

/// One user-defined agent. Name (a field, with a pencil to say so) on the label line; the base
/// and the probe's answer under it; the command and its flags as one launch line in the same dark
/// field a built-in puts its flags in. Everything is edited where it is shown.
private struct CustomAgentRow: View {
    @Environment(AppStore.self) private var store
    let agent: CustomAgent

    @State private var confirming = false
    @State private var probeDebounce: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    private var on: Bool { store.agentEnabledPrefs[agent.id] ?? true }
    private var probe: AgentProbeResult? { store.agentProbes[agent.id] }
    private var clash: String? { store.customAgentClash(agent.id, binary: agent.binary) }
    private var base: AgentDescriptor? { agent.base.flatMap(AgentRegistry.builtInDescriptor) }
    private var missing: Bool { !agent.binary.isEmpty && probe?.state == .missing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // The registry resolves the mark from the id, so a row with no base yet gets the
                // generic sparkle — nothing is claimed on its behalf before it says what it is.
                SessionIcon(kind: .agent(agent.agentID), size: 15)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                nameField
                pencil.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Spacer(minLength: 8)
                switchControl.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                removeButton.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            if confirming { removeStrip.padding(.top, 6) } else { behavesLike.padding(.top, 4) }
            launchLine.padding(.top, 8)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .task(id: agent.binary) {
            // The row asks on appearance and after every edit settles — a probe is a process
            // launch, so it waits for the typing to stop rather than racing every keystroke.
            guard !agent.binary.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            store.probeCustomAgent(agent.id)
        }
    }

    // The name is a field, but a field that looks like a label is a field nobody finds — so the
    // pencil says so, and it is what puts the caret in.
    private var nameField: some View {
        TextField("Name", text: Binding(
            get: { agent.name },
            set: { v in
                store.updateCustomAgent(agent.id) {
                    $0.named = !v.trimmingCharacters(in: .whitespaces).isEmpty
                    $0.name = v
                }
            }))
            .textFieldStyle(.plain).font(.sans(13, 550))
            .foregroundStyle(on ? Theme.ink : Theme.ink4)
            .focused($nameFocused)
            .fixedSize()
    }

    private var pencil: some View {
        TplHover { hovering in
            Button { nameFocused = true } label: {
                Phos(path: Phosphor.pencil, size: 12)
                    .foregroundStyle(hovering ? Theme.ink3 : Theme.inkFaint)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.rowHover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Rename")
        }
    }

    private var switchControl: some View {
        Toggle("", isOn: Binding(get: { on }, set: { store.agentEnabledPrefs[agent.id] = $0 }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
    }

    /// ✕ asks on the row when something points at the agent, and removes outright when nothing
    /// does — the ask is bolted to the consequence, not to the surface.
    private var removeButton: some View {
        TplHover { hovering in
            Button {
                if confirming { confirming = false; return }
                if store.customAgentTemplateUses(agent.id) == 0 {
                    withAnimation(.easeOut(duration: 0.15)) { store.removeCustomAgent(agent.id) }
                } else {
                    confirming = true
                }
            } label: {
                Phos(path: Phosphor.close, size: 12)
                    .foregroundStyle(hovering ? Theme.danger : Theme.inkFaint)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.rowHover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Remove agent")
        }
    }

    /// "Behaves like" is where this feature is honest: the base is not decoration, it is which
    /// supervisor reads the session — status, comments, the quit card, MCP registration. So it is
    /// a control on the row, beside what the probe found: what Synth saw, and what it will treat
    /// it as.
    private var behavesLike: some View {
        HStack(spacing: 10) {
            Text("Behaves like").font(.sans(12)).foregroundStyle(Theme.inkMuted)
            Menu {
                ForEach(AgentRegistry.builtIn) { b in
                    Button(b.displayName) { store.updateCustomAgent(agent.id) { $0.base = b.id } }
                }
            } label: {
                Text(base?.displayName ?? "Choose…")
                    .font(.sans(12, 550))
                    .foregroundStyle(on ? Theme.ink3 : Theme.ink4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Text(probeLine).font(.sans(11))
                .foregroundStyle(probeWarn ? Self.warnInk : Theme.inkFaint)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    /// The ask, on the row that asked it. One line: what goes, what doesn't, and the two verbs.
    private var removeStrip: some View {
        let uses = store.customAgentTemplateUses(agent.id)
        return HStack(spacing: 8) {
            Text("Drops \(uses) session\(uses == 1 ? "" : "s") from the new-worktree template. Sessions already running carry on.")
                .font(.sans(12)).foregroundStyle(Theme.inkMuted)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            SetPillButton(icon: nil, title: "Cancel") { confirming = false }
            SetPillButton(icon: nil, title: "Remove", danger: true) {
                withAnimation(.easeOut(duration: 0.15)) { store.removeCustomAgent(agent.id) }
            }
        }
    }

    /// The command and its flags in the same dark field a built-in row puts its flags in, so the
    /// card reads as one control repeated — the only difference is that this one has to say WHICH
    /// command it is adding them to.
    private var launchLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("$").foregroundStyle(Color(hex: 0x8B8E96))
            TextField("command", text: Binding(
                get: { agent.binary },
                set: { v in store.updateCustomAgent(agent.id) { $0.binary = v } }))
                .textFieldStyle(.plain)
                .foregroundStyle(missing ? Theme.working : Color(hex: 0xD4D6DC))
                .fixedSize()
            TextField(base?.exampleFlags ?? "flags", text: Binding(
                get: { store.globalAgentFlags[agent.agentID] ?? "" },
                set: { store.globalAgentFlags[agent.agentID] = $0 }))
                .textFieldStyle(.plain)
                .foregroundStyle(on ? Color(hex: 0xD4D6DC) : Color(hex: 0x8B8E96))
                .disabled(!on)
        }
        .font(.mono(12))
        .padding(.horizontal, 15).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.termBg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    /// What the row says about the command, in the fewest words that answer "will this start?".
    /// An empty command is the one state that isn't a complaint — the row was only just added.
    private var probeLine: String {
        if let clash { return clash }
        if agent.binary.isEmpty { return "Type a command" }
        guard let probe else { return "Checking…" }
        switch probe.state {
        case .missing: return "Not on your PATH"
        // A command that answers but isn't a known agent says nothing: the picker still reads
        // "Choose…", which is the only thing left to do about it.
        case .unrecognised: return ""
        case .recognised: return probe.version ?? (base?.displayName ?? "")
        }
    }

    /// The same amber ⌘K uses for a warning that is text rather than a light: the flat
    /// `Theme.working` is tuned for a dot on any surface and doesn't hold contrast as 11pt type.
    private static let warnInk = Theme.dyn(0xC8811A, 0xF5A623)

    private var probeWarn: Bool {
        if clash != nil { return true }
        guard !agent.binary.isEmpty, let probe else { return false }
        return probe.state == .missing
    }
}

// MARK: - Sessions (working.html .tpl-*)

private extension SessionKind {
    @MainActor var tplLabel: String {
        switch self {
        case .agent:     return tplStart
        case .terminal:  return "Terminal"
        case .browser:   return "Browser"
        case .simulator: return "Simulator"
        case .markdown:  return "Document"
        }
    }
}

private enum TplMetrics {
    static let rowHeight: CGFloat = 32
    static let gap: CGFloat = 4
    static var step: CGFloat { rowHeight + gap }
}

/// The layered project session control: the shared base sessions locked on top (working.html
/// .tpl-row--shared), the project's own added below and reorderable, then the add bar. The
/// first row overall opens; numbering continues across the boundary.
private struct LayeredSessions: View {
    @Environment(AppStore.self) private var store
    let shared: [SessionTemplateEntry]
    @Binding var own: [SessionTemplateEntry]

    var body: some View {
        // The opener can sit in either list — it's the first entry overall whose agent is
        // still switched on, so a disabled shared row hands "opens" down to whatever follows.
        let opens = store.templateOpensAt(shared + own)
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: TplMetrics.gap) {
                ForEach(Array(shared.enumerated()), id: \.element.id) { i, entry in
                    SharedSessionRow(entry: entry, index: i, opens: i == opens)
                }
            }
            TplList(entries: $own, emptyText: "No extra sessions — opens with the shared set.",
                    indexOffset: shared.count,
                    opensIndex: opens.flatMap { $0 >= shared.count ? $0 - shared.count : nil })
            TplAddBar(entries: $own)
        }
    }
}

/// A locked shared session row on a project scope — greyed, no grip/×, tagged "Synth".
private struct SharedSessionRow: View {
    @Environment(AppStore.self) private var store
    let entry: SessionTemplateEntry
    let index: Int
    let opens: Bool

    private var off: Bool { !store.isAgentEnabled(entry.kind) }

    var body: some View {
        HStack(spacing: 8) {
            TplIndex(i: index)
            TplKindIcon(kind: entry.kind, off: off)
            Text(entry.name)
                .font(.sans(13, 500))
                .foregroundStyle(off ? Theme.inkFaint : Theme.inkMuted)
                .strikethrough(off, color: Theme.inkFaint)
                .lineLimit(1).padding(.horizontal, 5)
            if opens { TplOpensTag() }
            if off { TplOffPill() }
            Spacer(minLength: 4)
            TplKindPill(kind: entry.kind)
            Text("Synth")
                .font(.sans(10, 600)).kerning(0.3)
                .foregroundStyle(Theme.inkFaint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Theme.rowSelected))
        }
        .padding(.horizontal, 9)
        .frame(height: TplMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.rowHover)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border.opacity(0.6), lineWidth: 0.5)))
    }
}

private struct TplOpensTag: View {
    var body: some View {
        Text("OPENS")
            .font(.sans(10, 700)).kerning(0.6)
            .foregroundStyle(Theme.accent)
    }
}

/// The "Off" pill on a template entry whose agent is switched off (working.html `.tpl-off`).
/// The entry is skipped, not deleted — flipping the agent back on restores it as it was.
private struct TplOffPill: View {
    var body: some View {
        Text("Off")
            .font(.sans(10, 600)).kerning(0.3)
            .foregroundStyle(Theme.inkFaint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Theme.rowHover))
    }
}

private struct TplDrop: Equatable { var from: Int; var target: Int }

/// The editable template list (working.html .tpl-list[data-tpl]): reorderable rows with an
/// inline name field, kind pill and remove button. `indexOffset` continues numbering past a
/// locked shared block; `opensIndex` is the row that opens the worktree, or nil when the
/// opener sits in the shared block above (or every entry is switched off).
private struct TplList: View {
    @Binding var entries: [SessionTemplateEntry]
    let emptyText: String
    var indexOffset: Int = 0
    var opensIndex: Int?
    @State private var drop: TplDrop?

    var body: some View {
        if entries.isEmpty {
            TplEmpty(text: emptyText)
        } else {
            VStack(spacing: TplMetrics.gap) {
                ForEach(entries) { entry in
                    let idx = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
                    TplRow(entries: $entries, entry: entry, index: idx,
                           displayIndex: idx + indexOffset, opens: idx == opensIndex, drop: $drop)
                }
            }
            .overlay(alignment: .top) {
                if let d = drop, d.target != d.from {
                    TplDropLine().offset(y: dropLineY(d) - 1).allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.08), value: d.target)
                        .transition(.opacity.animation(.easeOut(duration: 0.11)))
                }
            }
        }
    }

    private func dropLineY(_ d: TplDrop) -> CGFloat {
        let boundary = d.target < d.from ? d.target : d.target + 1
        let y = CGFloat(boundary) * TplMetrics.step - TplMetrics.gap / 2
        return min(max(y, 1), CGFloat(entries.count) * TplMetrics.step - TplMetrics.gap - 1)
    }
}

private struct TplDropLine: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.9)).frame(height: 2)
            .overlay(alignment: .leading) {
                Circle().fill(Theme.accent.opacity(0.9)).frame(width: 6, height: 6).offset(x: -3)
            }
            .padding(.horizontal, 4)
    }
}

private struct TplEmpty: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.sans(12)).foregroundStyle(Theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])))
    }
}

private struct TplRow: View {
    @Environment(AppStore.self) private var store
    @Binding var entries: [SessionTemplateEntry]
    let entry: SessionTemplateEntry
    let index: Int
    let displayIndex: Int
    var opens: Bool = false
    @Binding var drop: TplDrop?
    @State private var dragging = false
    @State private var dragFrom = 0
    @State private var dragOffset: CGFloat = 0

    private var off: Bool { !store.isAgentEnabled(entry.kind) }

    var body: some View {
        HStack(spacing: 8) {
            grip
            TplIndex(i: displayIndex)
            TplKindIcon(kind: entry.kind, off: off)
            TplNameField(text: nameBinding, off: off)
            if opens { TplOpensTag() }
            if off { TplOffPill() }
            TplKindPill(kind: entry.kind)
            removeButton
        }
        .padding(.horizontal, 9)
        .frame(height: TplMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9).fill(opens ? Theme.accent.opacity(0.10) : Theme.raised)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(opens ? Theme.accent.opacity(0.26) : Theme.border, lineWidth: opens ? 1 : 0.5))
                .shadow(color: .black.opacity(dragging ? 0.12 : 0.04), radius: dragging ? 4 : 0.75, y: 1)
        )
        .offset(y: dragOffset)
        .zIndex(dragging ? 1 : 0)
    }

    private var nameBinding: Binding<String> {
        Binding(get: { entries.first(where: { $0.id == entry.id })?.name ?? "" },
                set: { v in if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i].name = v } })
    }

    private var grip: some View {
        Phos(path: Phosphor.gripSix, size: 14).foregroundStyle(Theme.inkFaint).contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in
                        if !dragging { dragging = true; dragFrom = entries.firstIndex(where: { $0.id == entry.id }) ?? 0 }
                        dragOffset = v.translation.height
                        let delta = Int((v.translation.height / TplMetrics.step).rounded())
                        drop = TplDrop(from: dragFrom, target: max(0, min(entries.count - 1, dragFrom + delta)))
                    }
                    .onEnded { _ in
                        if let d = drop, d.target != d.from {
                            withAnimation(.easeOut(duration: 0.15)) {
                                entries.move(fromOffsets: IndexSet(integer: d.from), toOffset: d.target > d.from ? d.target + 1 : d.target)
                            }
                        }
                        drop = nil; dragging = false; dragOffset = 0
                    }
            )
    }

    private var removeButton: some View {
        TplHover { hovering in
            Button {
                if let i = entries.firstIndex(where: { $0.id == entry.id }) {
                    _ = withAnimation(.easeOut(duration: 0.15)) { entries.remove(at: i) }
                }
            } label: {
                Phos(path: Phosphor.close, size: 12)
                    .foregroundStyle(hovering ? Theme.danger : Theme.inkFaint)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.rowHover : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Remove")
        }
    }
}

private struct TplIndex: View {
    let i: Int
    var body: some View {
        Text("\(i + 1)").font(.sans(11, 500, tabular: true))
            .foregroundStyle(Theme.inkFaint).frame(width: 13)
    }
}

private struct TplKindIcon: View {
    let kind: SessionKind
    var off: Bool = false
    var body: some View {
        Phos(path: kind.iconPath, size: 14).foregroundStyle(kind.tint).frame(width: 14)
            .opacity(off ? 0.45 : 1)
    }
}

private struct TplKindPill: View {
    let kind: SessionKind
    var body: some View {
        Text(kind.tplLabel).font(.sans(11, 550)).foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Theme.rowSelected))
    }
}

private struct TplNameField: View {
    @Binding var text: String
    /// A skipped entry stays editable — the template is a wish list you keep between flips.
    var off: Bool = false
    @State private var hovering = false
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).font(.sans(13, 500))
            .foregroundStyle(off ? Theme.inkFaint : Theme.ink)
            .frame(maxWidth: .infinity)
            .focused($focused)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering || focused ? Theme.rowHover : Color.clear)
                .overlay(focused ? RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.selRing, lineWidth: 1.5) : nil))
            // `.strikethrough` doesn't reach a TextField's own text, so the rule is drawn over a
            // hidden copy of the string — same font, so it measures to exactly the same width.
            .overlay(alignment: .leading) { if off { strike } }
            .onHover { hovering = $0 }
    }

    private var strike: some View {
        Text(text)
            .font(.sans(13, 500))
            .hidden()
            .overlay(Rectangle().fill(Theme.inkFaint).frame(height: 1))
            .padding(.horizontal, 5)
            .allowsHitTesting(false)
    }
}

private struct TplAddBar: View {
    @Environment(AppStore.self) private var store
    @Binding var entries: [SessionTemplateEntry]
    var body: some View {
        // A template that spawns a simulator row is only offerable while the experiment is on and
        // there is an Xcode to run it; otherwise every new worktree would come up with a row that
        // cannot attach to anything.
        // `availableAgents`, not every installed one: a switched-off agent is not offerable. Plus
        // the simulator only while the experiment is on and there is an Xcode — otherwise a new
        // worktree would come up with a row that cannot attach to anything.
        // The markdown kind is offerable only in a build that staged the synth-md payload
        // (ADR-0016) — otherwise a new worktree would come up with a row that cannot open.
        let kinds = store.availableAgents.map { SessionKind.agent($0.id) }
            + [.terminal, .browser] + (store.simulatorsAvailable ? [.simulator] : [])
            + (MarkdownSession.isAvailable ? [SessionKind.markdown] : [])
        HStack(spacing: 6) {
            ForEach(kinds, id: \.self) { kind in
                TplHover { hovering in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            entries.append(SessionTemplateEntry(kind: kind, name: kind.tplStart))
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Phos(path: Phosphor.plus, size: 12).foregroundStyle(Theme.inkFaint)
                            // The bar is one fixed-height line: a long name (a user's own agent)
                            // overflows sideways rather than wrapping and growing every button.
                            Text(kind.tplLabel).font(.sans(12, 550)).foregroundStyle(hovering ? Theme.ink : Theme.ink3)
                                .lineLimit(1).fixedSize()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.rowHover : Theme.raised)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovering ? Theme.borderStrong : Theme.line, lineWidth: 0.5)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct TplHover<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false
    var body: some View { content(hovering).onHover { hovering = $0 } }
}

// MARK: - Browsing data (working.html browsingDataRow)

/// What the project's browsers have kept, and the one place it is thrown away (ADR-0011
/// stage five). The profile is per PROJECT, not per branch: branches of one repo are the same
/// application, so a per-branch profile would charge a fresh login on every branch cut, and a
/// global one would give up isolation between unrelated projects.
///
/// Clearing is destructive and reversible only by signing in again, so it asks — on the row,
/// in the same strip a custom agent's removal uses, rather than in a modal of its own.
private struct BrowsingData: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace
    @State private var confirming = false

    private var directory: URL {
        BrowserEngineFactory.profileDirectory(workspaceKey: workspace.browserProfileKey)
    }

    var body: some View {
        Group {
            if confirming {
                HStack(spacing: 8) {
                    Text("Signs these browsers out of every site and forgets what they stored. Open pages reload.")
                        .font(.sans(12)).foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    SetPillButton(icon: nil, title: "Cancel") { confirming = false }
                    SetPillButton(icon: nil, title: "Clear", danger: true) {
                        store.clearBrowsingData(for: workspace)
                        confirming = false
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11).frame(minHeight: 44)
            } else {
                SetToggleRow(label: "Browsing data", desc: description) {
                    HStack(spacing: 8) {
                        // nil = not measured yet. A profile claiming 0 MB before the walk has
                        // finished reads as "nothing here", which is the one thing it must not
                        // say wrongly on the row whose button throws it away.
                        if let bytes = FolderSizeCache.shared.bytes(for: directory), bytes > 0 {
                            Text(FolderSize.format(bytes))
                                .font(.sans(12, tabular: true)).foregroundStyle(Theme.inkMuted)
                        }
                        SetPillButton(icon: nil, title: "Clear…") { confirming = true }
                    }
                }
            }
        }
        .onAppear { FolderSizeCache.shared.warm([directory]) }
    }

    private var description: String {
        if !BrowserEngineFactory.profilesPersist {
            return "Another Synth is using the saved profile, so this window's browsers start "
                 + "signed out and forget everything when it quits."
        }
        let bytes = FolderSizeCache.shared.bytes(for: directory) ?? 0
        return bytes > 0
            ? "Cookies, logins and site data, shared by every browser session in this project. Kept until you clear it."
            : "Nothing kept yet. Sign in to a site in a browser session and it stays signed in — across branches, and across restarts."
    }
}

// MARK: - Archived worktrees (working.html .arc-*)

private extension AppStore {
    /// Measured bytes only: a folder still being walked contributes nothing rather than a guess.
    func archivedBytes(_ branches: [Branch]) -> Int64 {
        branches.reduce(0) { $0 + (FolderSizeCache.shared.bytes(for: archivedFolder($1)) ?? 0) }
    }
}

/// Archiving only means "reversible" if the archive is somewhere you can stand and look at it.
/// ⌘K can restore one you remember the name of; this is the list you read when you don't — and
/// it is the only place the disk cost is visible, which is the whole reason to delete one early.
private struct ArchivedWorktrees: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace

    var body: some View {
        let branches = store.archivedBranches(in: workspace)
        SetEditorRow(label: "Worktrees on disk",
                     trailing: {
                         if !branches.isEmpty {
                             Text("\(branches.count) · \(FolderSize.format(store.archivedBytes(branches)))")
                                 .font(.sans(12, tabular: true)).foregroundStyle(Theme.inkMuted)
                         }
                     }) {
            if branches.isEmpty {
                TplEmpty(text: "Nothing archived.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ArcList(branches: branches)
                    ArcPolicy()
                }
            }
        }
        // Both land well after the pane is drawn and both dedupe themselves; the id re-runs them
        // when a row is archived or restored while Settings is open.
        .task(id: branches.map(\.id)) {
            FolderSizeCache.shared.warm(branches.map { store.archivedFolder($0) })
            store.refreshArchiveVerdicts()
        }
    }
}

private struct ArcList: View {
    let branches: [Branch]

    var body: some View {
        ScrollView {
            VStack(spacing: TplMetrics.gap) {
                ForEach(branches) { ArcRow(branch: $0) }
            }
            // the rows carry a ring; without the gutter the scrollbar sits on top of it
            .padding(.trailing, 4)
        }
        // Four rows and a visibly cut fifth — the cut is the only honest scroll cue on a list
        // whose scrollbar hides until you touch it.
        .frame(maxHeight: TplMetrics.step * 4 + TplMetrics.rowHeight * 0.6)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ArcRow: View {
    @Environment(AppStore.self) private var store
    let branch: Branch

    private var eligible: Bool {
        if case .eligible = store.archiveVerdict(branch) { return true }
        return false
    }

    /// Read off the displayed verdict, not the stored one: a branch the budget has called early
    /// reads as checking too, and the chip has to agree with the words in it.
    private var checking: Bool { store.archiveVerdictChip(branch) == ArchiveSweeper.Block.secondOpinion.chip }

    var body: some View {
        HStack(spacing: 9) {
            Phos(path: Phosphor.archive, size: 14).foregroundStyle(Theme.inkFaint).frame(width: 14)
            // Everything to the right of the name is rigid, so the name is what gives up width:
            // a reason clipped to "commits not pushed anywhe…" is worse than no reason at all,
            // because it looks like the answer is somewhere else.
            Text(branch.name)
                .font(.sans(13, 500)).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(meta)
                .font(.sans(11, tabular: true)).foregroundStyle(Theme.inkFaint).fixedSize()
            if let chip = store.archiveVerdictChip(branch) { ArcWhy(text: chip, eligible: eligible, checking: checking) }
            restoreButton
            deleteButton
        }
        .padding(.horizontal, 9)
        .frame(height: TplMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.raised)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 0.75, y: 1))
    }

    /// "4h ago · 1.2 GB" — the size only once the walk lands, because a folder claiming 0 MB is
    /// worse than a folder claiming nothing.
    private var meta: String {
        let when = store.archivedAge(branch)
        guard let bytes = FolderSizeCache.shared.bytes(for: store.archivedFolder(branch)) else { return when }
        return "\(when) · \(FolderSize.format(bytes))"
    }

    /// `.arc-btn`, which is not quite `.tpl-add__btn`: tighter, and it answers to the pointer.
    /// It is the one thing on this row you press on purpose, and a button that looks identical
    /// under the cursor reads as a label until you happen to click it.
    private var restoreButton: some View {
        TplHover { hovering in
            Button { store.restoreArchivedBranch(branch) } label: {
                Text("Restore")
                    .font(.sans(12, 550))
                    .foregroundStyle(hovering ? Theme.ink : Theme.ink3)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.rowHover : Theme.raised)
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(hovering ? Theme.borderStrong : Theme.line, lineWidth: 0.5)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(ArcPressStyle())
        }
    }

    private var deleteButton: some View {
        TplHover { hovering in
            Button {
                // Deleting the folder is the one act on this row that doesn't come back, so it
                // asks — in ⌘K's confirm frame, not a dialog of this pane's own. The app has one
                // confirm surface and "confirms from every surface" means every surface routes
                // to it; a second one here would be a second wording of one promise to keep in
                // step. Cancel is preselected there, so a stray ↵ costs nothing.
                store.requestDeleteArchivedWorktree(branch)
            } label: {
                Phos(path: Phosphor.trash, size: 12)
                    .foregroundStyle(hovering ? Theme.danger : Theme.inkFaint)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.rowHover : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Delete permanently")
        }
    }
}

/// Why this folder is still on disk. A blocked row is the normal, correct state — the sweeper
/// protecting work — so it stays a quiet neutral chip; only the row that is about to go gets the
/// accent, because that is the one worth catching before it does.
/// `.arc-btn:active`. Shallower than `IconPressStyle`'s 0.94, which is tuned for an icon with
/// room to move — a text button that shrinks that far reads as a wobble rather than a press.
private struct ArcPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

private struct ArcWhy: View {
    let text: String
    let eligible: Bool
    /// The sweeper has read this one clean once and is waiting on a second reading a day later.
    /// Italic because it is the only chip that is not a verdict — it is the absence of one, and
    /// a reader who can't tell it from "PR still open" will read a pause as a decision.
    let checking: Bool

    var body: some View {
        Text(text)
            .font(.sans(10, 550))
            .italic(checking)
            .foregroundStyle(eligible ? Theme.inkOpen : Theme.inkMuted)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(eligible ? Theme.accent.opacity(0.12) : Theme.rowHover))
    }
}

/// The budget is archive-wide but the list above is one project's, so the two numbers are shown
/// apart — otherwise the row's own "7 · 7.3 GB" reads as the budget it is being measured against.
/// Two ratios, no sentence: a cap you can't see coming is indistinguishable from folders
/// vanishing at random, and which folders it has called early is already on their own rows.
private struct ArcPolicy: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        // A budget with nothing to spend it on is a number, not a fact — the caps can only bring
        // a folder's turn forward, and with the sweep off or the wait at Never no turn ever comes.
        if store.archiveSweepEnabled, store.archiveGraceDays > 0, !parts.isEmpty {
            Text("Archive-wide " + parts.joined(separator: " · "))
                .font(.sans(11, tabular: true))
                .foregroundStyle(Theme.inkFaint)
                .padding(.top, 9)
        }
    }

    private var parts: [String] {
        let archived = store.workspaces.flatMap { $0.branches.filter(\.isArchived) }
        var parts: [String] = []
        if store.archiveMaxCount > 0 { parts.append("\(archived.count) / \(store.archiveMaxCount) worktrees") }
        // both sides of a ratio share one unit — "7.8 GB / 50 GB" says GB twice to say it once
        if store.archiveMaxGB > 0 {
            parts.append(String(format: "%.1f / %d GB",
                                Double(store.archivedBytes(archived)) / 1_073_741_824,
                                store.archiveMaxGB))
        }
        return parts
    }
}

// MARK: - Segmented control (working.html .seg / .set-seg)

/// The house segmented picker: every option visible, the chosen one raised. Generic over what
/// it picks because the theme and the three archive knobs are the same control with different
/// tags — a second implementation would drift on the raised state within a release.
private enum SegWidth {
    static let three: CGFloat = 216
    /// Four options in the width built for three wraps every label onto two lines.
    static let four: CGFloat = 272
}

private struct SetSeg<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var width: CGFloat = SegWidth.three

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                let on = selection == value
                Button { selection = value } label: {
                    Text(label).font(.sans(12, 500))
                        .foregroundStyle(on ? Theme.repoName : Theme.inkMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.raised : Color.clear)
                            .shadow(color: on ? Color.black.opacity(0.12) : .clear, radius: 1, y: 1)
                            .overlay(on ? RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5) : nil))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2).background(RoundedRectangle(cornerRadius: 8).fill(Theme.rowSelected))
        .frame(width: width)
    }
}

/// Settings → Markdown. Three choices, because there are only three answers: read it here, read
/// it in your editor, or send it out of Synth entirely.
///
/// The editor choice carries WHICH editor rather than adding a fourth control for it. A machine
/// with one editor installed therefore has nothing extra to decide, and a machine with several
/// gets the menu only when it clicks that segment. Nothing is offered that is not installed, so
/// the middle segment is simply absent on a machine with no terminal editor at all.
private struct MarkdownOpenSeg: View {
    @Environment(AppStore.self) private var store
    @State private var editors: [TerminalEditor] = []

    private var chosenEditor: TerminalEditor? {
        if case let .editor(binary) = store.markdownOpen {
            return editors.first { $0.binary == binary }
        }
        return editors.first
    }

    var body: some View {
        HStack(spacing: 8) {
            SetSeg(options: options, selection: Binding(
                get: { mode },
                set: { apply($0) }
            ), width: editors.isEmpty ? SegWidth.three : SegWidth.four)

            // Only when there is a genuine choice to make.
            if mode == .editor, editors.count > 1 {
                Menu {
                    ForEach(editors) { editor in
                        Button(editor.name) { store.markdownOpen = .editor(editor.binary) }
                    }
                } label: {
                    Text(chosenEditor?.name ?? "Editor").font(.sans(12, 500))
                        .foregroundStyle(Theme.inkMuted)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        // Detection reads the login shell's PATH, which is probed off the main thread and may
        // not have resolved when Settings first draws.
        .task { editors = MarkdownOpener.installed() }
    }

    private enum Mode: Hashable { case synth, editor, defaultApp }

    private var mode: Mode {
        switch store.markdownOpen {
        case .synth: return .synth
        case .editor: return .editor
        case .defaultApp: return .defaultApp
        }
    }

    private var options: [(Mode, String)] {
        var out: [(Mode, String)] = [(.synth, "Synth")]
        if !editors.isEmpty {
            out.append((.editor, editors.count == 1 ? editors[0].name : "Editor"))
        }
        out.append((.defaultApp, "Default app"))
        return out
    }

    private func apply(_ next: Mode) {
        switch next {
        case .synth: store.markdownOpen = .synth
        case .defaultApp: store.markdownOpen = .defaultApp
        case .editor:
            guard let editor = chosenEditor else { return }
            store.markdownOpen = .editor(editor.binary)
        }
    }
}

private struct ThemeSeg: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        SetSeg(options: ThemePref.allCases.map { ($0, $0.label) },
               selection: Binding(get: { store.themePref }, set: { store.themePref = $0 }))
    }
}

// MARK: - About (working.html About row)

private struct AboutRow: View {
    @Environment(AppStore.self) private var store
    let version: String
    @State private var checking = false
    var body: some View {
        // The foot button and this row are the waiting build's only two surfaces, both pull — so a
        // staged build says so here too, and offers the same Restart rather than a Check that
        // would only re-find what is already downloaded.
        if let update = store.stagedUpdate {
            SetToggleRow(label: version,
                         desc: "Synth \(update.version) is ready · installs when you quit") {
                aboutButton("Restart") { store.restartForUpdate() }
            }
        } else {
            SetToggleRow(label: version, desc: "Up to date · checked 2 hours ago") {
                // The button carries "Checking…", not the description: the row's one fact should
                // not blink out while the check runs.
                aboutButton(checking ? "Checking…" : "Check for updates") {
                    // A real build asks Sparkle, and a check you asked for answers in its own
                    // window. A dev build has no updater, so it stages a demo build instead —
                    // checking by hand has to land where finding one on its own lands, the foot
                    // button and this row flipping to Restart, or the dev channel is the one
                    // place this feature can never be seen.
                    if let updater = Updates.controller?.updater { updater.checkForUpdates(); return }
                    checking = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        checking = false
                        #if DEBUG
                        store.stageStubUpdate(version: AppStore.debugNextVersion())
                        #endif
                    }
                }
            }
        }
    }

    private func aboutButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.sans(12, 500)).foregroundStyle(Theme.ink3)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.5)))
        }.buttonStyle(.plain)
    }
}

// MARK: - Workspace chip (working.html .repo__chip)

struct WsChip: View {
    let workspace: Workspace
    var size: CGFloat = 19
    var body: some View {
        let color = Theme.chipColors[workspace.colorIndex % Theme.chipColors.count]
        RoundedRectangle(cornerRadius: size * 0.32).fill(color).frame(width: size, height: size)
            .overlay(Text(workspace.monogram).font(.sans(size * 0.58, 600)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: size * 0.32).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0.75, y: 1)
    }
}
