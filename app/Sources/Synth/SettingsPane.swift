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
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
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
            SetSection(label: "Notification sounds") {
                switchRow("Session finished", "A background agent stopped working.", bind(\.soundDone))
                SetDivider()
                switchRow("Needs input", "An agent is waiting on you.", bind(\.soundNeedsInput))
                SetDivider()
                switchRow("Command failed", "A terminal command exited non-zero.", bind(\.soundError))
            }
            SetSection(label: "MCP servers") {
                switchRow("Browser", "13 tools to drive and inspect browser sessions.", bind(\.mcpBrowserEnabled))
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
                                emptyText: "No sessions — new worktrees open empty.", firstOpens: true)
                        TplAddBar(entries: bind(\.globalSessionTemplate))
                    }
                }
            }
            SetSection(label: "Agent defaults") {
                ForEach(Array(AgentRegistry.installed.enumerated()), id: \.element.id) { i, agent in
                    if i > 0 { SetDivider() }
                    SetEditorRow(label: agent.binaryName, desc: "Flags added to every \(agent.binaryName) launch.") {
                        FlagField(text: globalFlagsBinding(agent), placeholder: agent.exampleFlags)
                    }
                }
            }
            SetSection(label: "Privacy") {
                SetToggleRow(label: "Anonymous analytics", desc: "Usage counts only. No code, prompts or paths.") {
                    switchControl(bind(\.analyticsEnabled))
                }
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
            SetSection(label: "Agents") {
                ForEach(Array(AgentRegistry.installed.enumerated()), id: \.element.id) { i, agent in
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
    }

    private var emptyProject: some View {
        SetSection(label: "Projects") {
            VStack(spacing: 0) {
                Phos(path: Phosphor.folder, size: 26).foregroundStyle(Theme.inkFaint)
                Text("No projects yet")
                    .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                    .foregroundStyle(Theme.ink).padding(.top, 10)
                Text("Add a project to set what its worktrees open with.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted).padding(.top, 4)
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
                    .font(.system(size: 12.5, weight: .medium)).kerning(-0.08)
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
                .font(.system(size: 10, weight: .semibold)).kerning(0.6)
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
                Text(label).font(.system(size: 12.5, weight: .medium)).kerning(-0.08).foregroundStyle(Theme.ink)
                if let desc {
                    Text(desc).font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted)
                        .lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14).padding(.vertical, 11).frame(minHeight: 44)
    }
}

/// A row whose control is a full-width body (editor, session list) beneath the label.
private struct SetEditorRow<Trailing: View, Body: View>: View {
    let label: String
    var desc: String? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Body

    init(label: String, desc: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Body) {
        self.label = label; self.desc = desc; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(.system(size: 12.5, weight: .medium)).kerning(-0.08).foregroundStyle(Theme.ink)
                if let desc {
                    Text(desc).font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted)
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
                .font(.system(size: 11.5, weight: .medium))
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
                Text(caption).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink4)
                Spacer(minLength: 8)
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.inkFaint) }
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
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(hex: 0xD4D6DC).opacity(0.30))
                    .padding(.horizontal, 15).padding(.vertical, 13).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(hex: 0xD4D6DC))
                .lineSpacing(3).scrollContentBackground(.hidden)
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
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.ink4)
                Spacer(minLength: 8)
                Button(action: editInSynth) {
                    Text("Edit in Synth").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.input)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } }

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    Text(base)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x8B8E96))
                        .strikethrough(skip)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.termBg))
                    Toggle(isOn: $skip) {
                        Text("Don't run the shared setup in \(projectName)")
                            .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
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

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xD4D6DC).opacity(0.30)).allowsHitTesting(false)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(hex: 0xD4D6DC))
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.termBg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
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
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tuiBg))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.tuiHair, lineWidth: 1))
    }
}

// MARK: - Sessions (working.html .tpl-*)

private extension SessionKind {
    @MainActor var tplLabel: String {
        switch self {
        case .agent:    return tplStart
        case .terminal: return "Terminal"
        case .browser:  return "Browser"
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
    let shared: [SessionTemplateEntry]
    @Binding var own: [SessionTemplateEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: TplMetrics.gap) {
                ForEach(Array(shared.enumerated()), id: \.element.id) { i, entry in
                    SharedSessionRow(entry: entry, index: i, opens: i == 0)
                }
            }
            TplList(entries: $own, emptyText: "No extra sessions — opens with the shared set.",
                    indexOffset: shared.count, firstOpens: shared.isEmpty)
            TplAddBar(entries: $own)
        }
    }
}

/// A locked shared session row on a project scope — greyed, no grip/×, tagged "Synth".
private struct SharedSessionRow: View {
    let entry: SessionTemplateEntry
    let index: Int
    let opens: Bool

    var body: some View {
        HStack(spacing: 8) {
            TplIndex(i: index)
            TplKindIcon(kind: entry.kind)
            Text(entry.name)
                .font(.system(size: 12.5, weight: .medium)).kerning(-0.08)
                .foregroundStyle(Theme.inkMuted).lineLimit(1).padding(.horizontal, 5)
            if opens { TplOpensTag() }
            Spacer(minLength: 4)
            TplKindPill(kind: entry.kind)
            Text("Synth")
                .font(.system(size: 9.5, weight: .semibold)).kerning(0.3)
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
            .font(.system(size: 9.5, weight: .bold)).kerning(0.5)
            .foregroundStyle(Theme.accent)
    }
}

private struct TplDrop: Equatable { var from: Int; var target: Int }

/// The editable template list (working.html .tpl-list[data-tpl]): reorderable rows with an
/// inline name field, kind pill and remove button. `indexOffset` continues numbering past a
/// locked shared block; `firstOpens` tags row 0 as the one that opens.
private struct TplList: View {
    @Binding var entries: [SessionTemplateEntry]
    let emptyText: String
    var indexOffset: Int = 0
    var firstOpens: Bool = false
    @State private var drop: TplDrop?

    var body: some View {
        if entries.isEmpty {
            TplEmpty(text: emptyText)
        } else {
            VStack(spacing: TplMetrics.gap) {
                ForEach(entries) { entry in
                    let idx = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
                    TplRow(entries: $entries, entry: entry, index: idx,
                           displayIndex: idx + indexOffset, opens: firstOpens && idx == 0, drop: $drop)
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
            .font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])))
    }
}

private struct TplRow: View {
    @Binding var entries: [SessionTemplateEntry]
    let entry: SessionTemplateEntry
    let index: Int
    let displayIndex: Int
    var opens: Bool = false
    @Binding var drop: TplDrop?
    @State private var dragging = false
    @State private var dragFrom = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            grip
            TplIndex(i: displayIndex)
            TplKindIcon(kind: entry.kind)
            TplNameField(text: nameBinding)
            if opens { TplOpensTag() }
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
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.rowSelected : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Remove")
        }
    }
}

private struct TplIndex: View {
    let i: Int
    var body: some View {
        Text("\(i + 1)").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(Theme.inkFaint).frame(width: 13)
    }
}

private struct TplKindIcon: View {
    let kind: SessionKind
    var body: some View { Phos(path: kind.iconPath, size: 14).foregroundStyle(kind.tint).frame(width: 14) }
}

private struct TplKindPill: View {
    let kind: SessionKind
    var body: some View {
        Text(kind.tplLabel).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Theme.rowSelected))
    }
}

private struct TplNameField: View {
    @Binding var text: String
    @State private var hovering = false
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).font(.system(size: 12.5, weight: .medium)).kerning(-0.08)
            .foregroundStyle(Theme.ink).focused($focused)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering || focused ? Theme.rowHover : Color.clear)
                .overlay(focused ? RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.selRing, lineWidth: 1.5) : nil))
            .onHover { hovering = $0 }
    }
}

private struct TplAddBar: View {
    @Binding var entries: [SessionTemplateEntry]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(AgentRegistry.installed.map { SessionKind.agent($0.id) } + [.terminal, .browser], id: \.self) { kind in
                TplHover { hovering in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            entries.append(SessionTemplateEntry(kind: kind, name: kind.tplStart))
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Phos(path: Phosphor.plus, size: 12).foregroundStyle(Theme.inkFaint)
                            Text(kind.tplLabel).font(.system(size: 11.5, weight: .medium)).foregroundStyle(hovering ? Theme.ink : Theme.ink3)
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

// MARK: - Appearance segmented control (working.html .seg)

private struct ThemeSeg: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        HStack(spacing: 2) {
            ForEach(ThemePref.allCases) { pref in
                let on = store.themePref == pref
                Button { store.themePref = pref } label: {
                    Text(pref.label).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? Theme.repoName : Theme.inkMuted)
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
        .frame(width: 216)
    }
}

// MARK: - About (working.html About row)

private struct AboutRow: View {
    let version: String
    @State private var checking = false
    var body: some View {
        SetToggleRow(label: version, desc: checking ? "Checking…" : "Up to date · checked 2 hours ago") {
            Button {
                checking = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { checking = false }
            } label: {
                Text("Check for updates")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.5)))
            }.buttonStyle(.plain)
        }
    }
}

// MARK: - Workspace chip (working.html .repo__chip)

struct WsChip: View {
    let workspace: Workspace
    var size: CGFloat = 19
    var body: some View {
        let color = Theme.chipColors[workspace.colorIndex % Theme.chipColors.count]
        RoundedRectangle(cornerRadius: size * 0.32).fill(color).frame(width: size, height: size)
            .overlay(Text(workspace.monogram).font(.system(size: size * 0.58, weight: .semibold)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: size * 0.32).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0.75, y: 1)
    }
}
