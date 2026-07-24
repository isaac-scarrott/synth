import SwiftUI

/// The full-screen Settings content pane (working.html renderSettings). It shares the
/// shell — the sidebar swaps its tree for a scope list, this fills the content pane.
/// Global shows one setup script; a workspace shows the run order plus the read-only
/// global script ("runs first") above its own editable one ("runs next"): the effective
/// config runs BOTH, global first — a merge of execution, not an override.
struct SettingsPane: View {
    @Environment(AppStore.self) private var store

    private var isGlobal: Bool { store.settingsIsGlobal }
    private var ws: Workspace? { store.settingsWorkspace }
    private var name: String { ws?.name ?? "Global" }

    var body: some View {
        VStack(spacing: 0) {
            head
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if isGlobal { appearanceSection }
                    if isGlobal { soundsSection }
                    if isGlobal { mcpSection }
                    if isGlobal { privacySection }
                    if isGlobal { experimentalSection }
                    scriptSection
                    templateSection
                    flagsSection
                }
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // working.html .pane__head — same head/breadcrumb chrome as a session pane.
    private var head: some View {
        HStack(spacing: 10) {
            if store.sidebarCollapsed {
                SidebarToggle().padding(.trailing, 2)
            }
            if isGlobal {
                Phos(path: Phosphor.globe, size: 16)
                    .foregroundStyle(Theme.inkMuted).frame(width: 20)
            } else if let ws {
                WsChip(workspace: ws, size: 19)
            }
            Text(name)
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.ink)
            (Text("Settings").fontWeight(.semibold)
                + Text(" / \(isGlobal ? "All projects" : name)"))
                .font(.system(size: 11, design: .monospaced)).kerning(-0.11)
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, store.sidebarCollapsed ? Theme.trafficLightsClearance : 18)
        .padding(.trailing, 18)
        .frame(height: Theme.titlebarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }

    // MARK: Appearance — global only (working.html's global Appearance segmented control).

    @ViewBuilder private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Appearance")
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.repoName)
            (Text("System").fontWeight(.semibold)
                + Text(" follows your macOS appearance; Light and Dark pin it."))
                .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                .lineSpacing(3).padding(.top, 4)
            ThemeSeg().padding(.top, 14)
        }
    }

    // MARK: Experimental — global only. Tabs is an opt-in, off-by-default view mode
    // (working.html's global Experimental → Tabs segmented control).

    @ViewBuilder private var experimentalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Experimental")
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.repoName)
            (Text("Tabs").fontWeight(.semibold)
                + Text(" collapses the sidebar to two levels and gives the content a tab strip of the branch's sessions. Off by default — a work-in-progress preview."))
                .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                .lineSpacing(3).padding(.top, 4)
            TabsSeg().padding(.top, 14)
        }
    }

    // MARK: Notification sounds — global, per-type. Gate the default sound on the unfocused
    // Notification Center path (in-app toasts are always silent).

    @ViewBuilder private var soundsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notification sounds")
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.repoName)
            sub("Play a sound with Notification Center alerts when Synth isn't focused. In-app notifications stay silent.")
            VStack(spacing: 0) {
                soundRow("Needs-input sound", soundInputBinding)
                Rectangle().fill(Theme.border).frame(height: 0.5)
                soundRow("Error sound", soundErrorBinding)
                Rectangle().fill(Theme.border).frame(height: 0.5)
                soundRow("Done sound", soundDoneBinding)
            }
            .padding(.top, 14)
        }
    }

    private func soundRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
            Spacer(minLength: 8)
            Toggle("", isOn: binding)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
        }
        .padding(.vertical, 7)
    }

    private var soundInputBinding: Binding<Bool> {
        Binding(get: { store.soundNeedsInput }, set: { store.soundNeedsInput = $0 })
    }
    private var soundErrorBinding: Binding<Bool> {
        Binding(get: { store.soundError }, set: { store.soundError = $0 })
    }
    private var soundDoneBinding: Binding<Bool> {
        Binding(get: { store.soundDone }, set: { store.soundDone = $0 })
    }

    // MARK: MCP servers — global, per-machine. Which bundled tool servers agents find in
    // every managed worktree; a change re-registers/removes them in each worktree's config.

    @ViewBuilder private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MCP servers")
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.repoName)
            sub("Tools Synth offers to coding agents in every managed worktree. Changes apply to newly started agent sessions.")
            VStack(spacing: 0) {
                mcpRow("Synth browser",
                       "Agents can open and drive in-app browser sessions — navigate, click, screenshot, record.",
                       mcpBrowserBinding)
                Rectangle().fill(Theme.border).frame(height: 0.5)
                mcpRow("Synth app",
                       "Agents can ask Synth to create worktrees and hand work off to them. Every request needs your approval.",
                       mcpAppBinding)
            }
            .padding(.top, 14)
        }
    }

    private func mcpRow(_ label: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: binding)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
        }
        .padding(.vertical, 7)
    }

    private var mcpBrowserBinding: Binding<Bool> {
        Binding(get: { store.mcpBrowserEnabled }, set: { store.mcpBrowserEnabled = $0 })
    }
    private var mcpAppBinding: Binding<Bool> {
        Binding(get: { store.mcpAppEnabled }, set: { store.mcpAppEnabled = $0 })
    }

    // MARK: Privacy — anonymous, opt-out usage analytics. Off tells PostHog to stop sending at
    // once; nothing here identifies you, and the dev channel never reports regardless.

    @ViewBuilder private var privacySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Privacy")
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.repoName)
            sub("Help improve Synth by sharing anonymous usage — which features you use and how often. No account, no code, no file names or contents, nothing that identifies you. You can turn it off any time.")
            VStack(spacing: 0) {
                mcpRow("Share anonymous usage analytics",
                       "Sends a small set of events (sessions opened, worktrees created, feedback sent) and app open/close, tied to a random per-install id. Off stops it immediately.",
                       analyticsBinding)
            }
            .padding(.top, 14)
        }
    }

    private var analyticsBinding: Binding<Bool> {
        Binding(get: { store.analyticsEnabled }, set: { store.analyticsEnabled = $0 })
    }

    // MARK: The one setting so far — the worktree setup script.

    @ViewBuilder private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Worktree setup script")
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.repoName)
            if isGlobal {
                sub("Runs once inside every new worktree, right after it's created — across all projects.")
                CodeCard(label: "setup.sh", text: globalBinding)
                    .padding(.top, 14)
                note("Runs in the new worktree's root with $SYNTH_MAIN pointing at the primary checkout. Times out after 5 minutes; a non-zero exit is reported on the worktree but never blocks it.")
            } else {
                (Text("Extra setup for ") + Text(name).fontWeight(.semibold) + Text(" worktrees, on top of the global script."))
                    .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                    .lineSpacing(3).padding(.top, 4)
                flowStrip(note: "Both run · global first")
                CodeCard(label: "Global — runs first", text: globalBinding, readOnly: true,
                         trailing: { EditInGlobalLink() })
                    .padding(.top, 14)
                CodeCard(label: "\(name) — runs next", text: wsBinding)
                    .padding(.top, 14)
                note("Each runs in the new worktree's root. Times out after 5 minutes; a non-zero exit is reported but never blocks it.")
            }
        }
    }

    // MARK: New worktree sessions — the ordered session set every worktree starts with
    // (working.html sessionsSection). Same override model as the flags: a workspace's
    // list replaces the global outright; an empty list inherits global.

    @ViewBuilder private var templateSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New worktree sessions")
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.repoName)
            if isGlobal {
                sub("Every new worktree starts with these sessions, created in order — the first one opens.")
                TplList(entries: globalTplBinding,
                        emptyText: "No sessions — new worktrees start empty.")
                    .padding(.top, 14)
                TplAddBar(entries: globalTplBinding).padding(.top, 8)
                TplPreview(entries: store.globalSessionTemplate).padding(.top, 14)
                note("Sessions spawn once the setup script finishes. The template only shapes the start — rename, reorder or close them freely afterwards.")
            } else {
                (Text("Starting sessions for ") + Text(name).fontWeight(.semibold)
                    + Text(" worktrees — these replace the global set. Leave empty to inherit global."))
                    .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                    .lineSpacing(3).padding(.top, 4)
                flowStrip(note: "Project overrides global")
                VStack(alignment: .leading, spacing: 7) {
                    TplListHead(label: "Global — inherited when empty") { EditInGlobalLink() }
                    TplListRO(entries: store.globalSessionTemplate, emptyText: "No global sessions.")
                }
                .padding(.top, 14)
                VStack(alignment: .leading, spacing: 7) {
                    TplListHead(label: "\(name) — overrides global") { EmptyView() }
                    TplList(entries: wsTplBinding,
                            emptyText: "Inheriting global — add a session to override.")
                    TplAddBar(entries: wsTplBinding).padding(.top, 1)
                }
                .padding(.top, 14)
                TplPreview(entries: store.sessionTemplate(for: ws)).padding(.top, 14)
            }
        }
    }

    // MARK: Agent flags — default flags passed to each agent's binary on session start.

    /// One block per installed agent, so a machine with only one of them shows only that one.
    @ViewBuilder private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 30) {
            ForEach(AgentRegistry.installed, id: \.id) { agent in
                agentFlags(agent)
            }
        }
    }

    @ViewBuilder private func agentFlags(_ agent: AgentDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(agent.displayName) flags")
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.repoName)
            if isGlobal {
                (Text("Passed to ") + Text(agent.binaryName).font(.system(size: 12, design: .monospaced))
                    + Text(" every time a \(agent.displayName) session starts — across all projects."))
                    .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                    .lineSpacing(3).padding(.top, 4)
                CodeCard(label: "flags", text: globalFlagsBinding(agent), minHeight: 44).padding(.top, 14)
                CmdPreview(binary: agent.binaryName, flags: store.globalAgentFlags[agent.id] ?? "").padding(.top, 14)
                agentNote(agent)
            } else {
                (Text("Flags for ") + Text(name).fontWeight(.semibold)
                    + Text(" \(agent.displayName) sessions. These override the global flags for this project — leave empty to inherit global."))
                    .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                    .lineSpacing(3).padding(.top, 4)
                flowStrip(note: "Project overrides global").padding(.top, 14)
                CodeCard(label: "Global — inherited when empty",
                         text: .constant(store.globalAgentFlags[agent.id] ?? ""),
                         readOnly: true, minHeight: 44, trailing: { EditInGlobalLink() }).padding(.top, 14)
                CodeCard(label: "\(name) — overrides global", text: wsFlagsBinding(agent), minHeight: 44).padding(.top, 14)
                CmdPreview(binary: agent.binaryName, flags: store.agentFlags(agent.id, for: ws)).padding(.top, 14)
            }
        }
    }

    private func agentNote(_ agent: AgentDescriptor) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Phos(path: Phosphor.info, size: 14).foregroundStyle(Theme.inkMeta).padding(.top, 1)
            (Text("Any ") + Text(agent.binaryName).font(.system(size: 11.5, design: .monospaced))
                + Text(" flag works here — type them as you would on the command line, like ")
                + Text(agent.exampleFlags).font(.system(size: 11.5, design: .monospaced)) + Text("."))
                .font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted).lineSpacing(2)
        }
        .padding(.top, 12)
    }

    // working.html .set-flow — makes "global first, then workspace" legible at a glance.
    private func flowStrip(note: String) -> some View {
        HStack(spacing: 9) {
            HStack(spacing: 7) {
                Phos(path: Phosphor.globe, size: 15).foregroundStyle(Theme.inkMuted)
                Text("Global").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.repoName)
            }
            Phos(path: Phosphor.caret, size: 15).foregroundStyle(Theme.inkMeta)
            HStack(spacing: 7) {
                if let ws { WsChip(workspace: ws, size: 16) }
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.repoName)
            }
            Spacer(minLength: 8)
            Text(note)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Theme.rowHover)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 0.5))
        )
        .padding(.top, 14)
    }

    private func sub(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            .lineSpacing(3).padding(.top, 4)
    }

    private func note(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Phos(path: Phosphor.info, size: 14).foregroundStyle(Theme.inkMeta).padding(.top, 1)
            Text(s).font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted).lineSpacing(2)
        }
        .padding(.top, 12)
    }

    // MARK: Bindings — edits persist to the mock store so they survive scope hops.

    private var globalBinding: Binding<String> {
        Binding(get: { store.globalScript }, set: { store.globalScript = $0 })
    }
    private var wsBinding: Binding<String> {
        let id = ws?.id
        return Binding(
            get: { id.flatMap { store.wsScripts[$0] } ?? store.wsScriptPlaceholder },
            set: { v in if let id { store.wsScripts[id] = v } }
        )
    }

    private func globalFlagsBinding(_ agent: AgentDescriptor) -> Binding<String> {
        Binding(get: { store.globalAgentFlags[agent.id] ?? "" },
                set: { store.globalAgentFlags[agent.id] = $0 })
    }
    private func wsFlagsBinding(_ agent: AgentDescriptor) -> Binding<String> {
        let id = ws?.id
        return Binding(
            get: { id.flatMap { store.wsAgentFlags[$0]?[agent.id] } ?? "" },
            set: { v in if let id { store.wsAgentFlags[id, default: [:]][agent.id] = v } }
        )
    }

    private var globalTplBinding: Binding<[SessionTemplateEntry]> {
        Binding(get: { store.globalSessionTemplate }, set: { store.globalSessionTemplate = $0 })
    }
    private var wsTplBinding: Binding<[SessionTemplateEntry]> {
        let id = ws?.id
        return Binding(
            get: { id.flatMap { store.wsSessionTemplates[$0] } ?? [] },
            set: { v in if let id { store.wsSessionTemplates[id] = v } }
        )
    }
}

// MARK: - New worktree sessions (working.html .tpl-*)

/// The template UI's pill label (working.html TPL_KINDS). Icon path/tint come from
/// Theme's SessionKind extension — the same glyphs the sidebar rows use; the stock
/// starting name (`tplStart`) lives with SessionTemplateEntry in Model.
private extension SessionKind {
    @MainActor var tplLabel: String {
        switch self {
        case .agent:    return tplStart
        case .terminal: return "Terminal"
        case .browser:  return "Browser"
        }
    }
}

/// Row metrics shared by the list and the drag math: fixed row height + gap, so a drag
/// target index is pure arithmetic on translation.height.
private enum TplMetrics {
    static let rowHeight: CGFloat = 32
    static let gap: CGFloat = 4
    static var step: CGFloat { rowHeight + gap }
}

/// The uppercase label row above a template list (working.html .set-code-head — the same
/// dial as CodeCard's label row, reused standalone here).
private struct TplListHead<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold)).kerning(0.5)
                .foregroundStyle(Theme.navLabel)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

/// An in-flight grip drag: the row's origin slot and the slot a release would land in.
private struct TplDrop: Equatable {
    var from: Int
    var target: Int
}

/// The editable template list (working.html .tpl-list[data-tpl]): reorderable rows with
/// an inline name field, kind pill and remove button.
private struct TplList: View {
    @Binding var entries: [SessionTemplateEntry]
    let emptyText: String
    @State private var drop: TplDrop?

    var body: some View {
        if entries.isEmpty {
            TplEmpty(text: emptyText)
        } else {
            VStack(spacing: TplMetrics.gap) {
                ForEach(entries) { entry in
                    TplRow(entries: $entries, entry: entry,
                           index: entries.firstIndex(where: { $0.id == entry.id }) ?? 0,
                           drop: $drop)
                }
            }
            // .drop-line — painted above the rows, hidden when the drop is a no-op.
            .overlay(alignment: .top) {
                if let d = drop, d.target != d.from {
                    TplDropLine()
                        .offset(y: dropLineY(d) - 1)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.08), value: d.target)
                        .transition(.opacity.animation(.easeOut(duration: 0.11)))
                }
            }
        }
    }

    /// Line centre against the un-reshuffled layout (the dragged row still holds its
    /// origin slot, like the HTML's faded .drag-src): mid-gap above the row the drop
    /// lands before, or under the last row for an append, clamped inside the list.
    private func dropLineY(_ d: TplDrop) -> CGFloat {
        let boundary = d.target < d.from ? d.target : d.target + 1
        let y = CGFloat(boundary) * TplMetrics.step - TplMetrics.gap / 2
        return min(max(y, 1), CGFloat(entries.count) * TplMetrics.step - TplMetrics.gap - 1)
    }
}

/// The copper insertion line (working.html .drop-line): a 2px accent rule inset 4px from
/// each side, with a round dot cap protruding past its left end.
private struct TplDropLine: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent.opacity(0.9))
            .frame(height: 2)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Theme.accent.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .offset(x: -3)
            }
            .padding(.horizontal, 4)
    }
}

/// The read-only mirror (working.html .tpl-list--ro): same rows minus grip/×, flat and
/// dimmed — the inherited global list shown on a workspace scope.
private struct TplListRO: View {
    let entries: [SessionTemplateEntry]
    let emptyText: String

    var body: some View {
        if entries.isEmpty {
            TplEmpty(text: emptyText)
        } else {
            VStack(spacing: TplMetrics.gap) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    HStack(spacing: 8) {
                        TplIndex(i: i)
                        TplKindIcon(kind: entry.kind)
                        Text(entry.name)
                            .font(.system(size: 12.5, weight: .medium)).kerning(-0.08)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                        Spacer(minLength: 4)
                        TplKindPill(kind: entry.kind)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: TplMetrics.rowHeight)
                }
            }
            .opacity(0.62)
        }
    }
}

/// Empty-state card (working.html .tpl-empty): a dashed hairline around a quiet line.
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

/// One editable template row (working.html .tpl-row): grip · index · kind icon · name
/// field · kind pill · ×. The grip's DragGesture lifts the row to track the pointer while
/// the rest of the list holds still (working.html startTplDrag) — rows are fixed-height,
/// so the landing slot is translation.height over the row step, committed on release.
private struct TplRow: View {
    @Binding var entries: [SessionTemplateEntry]
    let entry: SessionTemplateEntry
    let index: Int
    @Binding var drop: TplDrop?
    @State private var dragging = false
    @State private var dragFrom = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            grip
            TplIndex(i: index)
            TplKindIcon(kind: entry.kind)
            TplNameField(text: nameBinding)
            TplKindPill(kind: entry.kind)
            removeButton
        }
        .padding(.horizontal, 9)
        .frame(height: TplMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9).fill(Theme.raised)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(dragging ? 0.12 : 0.04), radius: dragging ? 4 : 0.75, y: 1)
        )
        .offset(y: dragOffset)
        .zIndex(dragging ? 1 : 0)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { entries.first(where: { $0.id == entry.id })?.name ?? "" },
            set: { v in if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i].name = v } }
        )
    }

    // .tpl-grip — global coordinates so the lifted row moving with the pointer doesn't
    // feed back into the translation.
    private var grip: some View {
        Phos(path: Phosphor.gripSix, size: 14)
            .foregroundStyle(Theme.inkFaint)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            dragFrom = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
                        }
                        dragOffset = v.translation.height
                        let delta = Int((v.translation.height / TplMetrics.step).rounded())
                        drop = TplDrop(from: dragFrom,
                                       target: max(0, min(entries.count - 1, dragFrom + delta)))
                    }
                    .onEnded { _ in
                        if let d = drop, d.target != d.from {
                            withAnimation(.easeOut(duration: 0.15)) {
                                entries.move(fromOffsets: IndexSet(integer: d.from),
                                             toOffset: d.target > d.from ? d.target + 1 : d.target)
                            }
                        }
                        drop = nil
                        dragging = false
                        dragOffset = 0
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
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Theme.rowSelected : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
    }
}

/// .tpl-idx — the 1-based order number.
private struct TplIndex: View {
    let i: Int
    var body: some View {
        Text("\(i + 1)")
            .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(Theme.inkFaint)
            .frame(width: 13)
    }
}

/// The 14pt kind glyph — same icon + tint as the sidebar session rows (.session__icon).
private struct TplKindIcon: View {
    let kind: SessionKind
    var body: some View {
        Phos(path: kind.iconPath, size: 14)
            .foregroundStyle(kind.tint).frame(width: 14)
    }
}

/// .tpl-kind — the kind pill on the row's right.
private struct TplKindPill: View {
    let kind: SessionKind
    var body: some View {
        Text(kind.tplLabel)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(Theme.rowSelected))
    }
}

/// input.tpl-name — a plain inline field; a soft fill surfaces on hover/focus only.
private struct TplNameField: View {
    @Binding var text: String
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium)).kerning(-0.08)
            .foregroundStyle(Theme.ink)
            .focused($focused)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering || focused ? Theme.rowHover : Color.clear)
                    .overlay(focused ? RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Theme.selRing, lineWidth: 1.5) : nil)
            )
            .onHover { hovering = $0 }
    }
}

/// .tpl-add — one pill button per kind; tapping appends `{kind, its start name}`.
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
                            Text(kind.tplLabel)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(hovering ? Theme.ink : Theme.ink3)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(hovering ? Theme.rowHover : Theme.raised)
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(hovering ? Theme.borderStrong : Theme.line, lineWidth: 0.5))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Hover-tracking wrapper so the add/remove buttons can restyle without each carrying
/// its own @State boilerplate.
private struct TplHover<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false
    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

/// The live preview (working.html tplPreview): the sidebar subtree a new worktree would
/// open with — a mock branch group with the template's sessions nested under the same
/// hairline indent as the real sidebar. Display only; the first row carries the
/// open-session tint, so "the first one opens" is visible.
private struct TplPreview: View {
    let entries: [SessionTemplateEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TplListHead(label: "New worktree preview") { EmptyView() }
            HStack(spacing: 6) {
                Phos(path: Phosphor.caret, size: 12)
                    .foregroundStyle(Theme.chevron)
                    .rotationEffect(.degrees(90))
                    .frame(width: 12)
                Text("feature/next-thing")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.branchName)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10).padding(.vertical, 5)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    HStack(spacing: 8) {
                        TplKindIcon(kind: entry.kind)
                        Text(entry.name)
                            .font(.system(size: 11.5))
                            .fontWeight(i == 0 ? .semibold : .regular)
                            .foregroundStyle(i == 0 ? Theme.inkOpen : Theme.sessionName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    // The open session's sticky tint on the first row (.session--open).
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.accent.opacity(i == 0 ? 0.10 : 0)))
                }
            }
            // The live sidebar's sessions block verbatim (rows 15 past the leading
            // hairline — Sidebar's Reveal), indented 15 under the branch row: the
            // preview shows what the app will actually render, not the HTML metrics.
            .padding(.leading, 15)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.border).frame(width: 1)
            }
            .padding(.leading, 15)
        }
        .padding(.top, 10).padding(.horizontal, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 0.5))
        )
        .allowsHitTesting(false)
    }
}

/// The effective `claude …` launch line, flags tinted like a terminal command — mirrors
/// working.html's `.set-cmd` preview on the terminal-card surface.
private struct CmdPreview: View {
    let binary: String
    let flags: String
    private var tokens: [String] { flags.split(whereSeparator: \.isWhitespace).map(String.init) }

    var body: some View {
        let blue = Theme.dyn(0x2B6FD6, 0x8AB4F8)
        (Text("$ ").foregroundStyle(Theme.inkMuted) + Text(binary).foregroundStyle(Theme.repoName)
            + tokens.reduce(Text("")) { $0 + Text(" ") + Text($1).foregroundStyle(blue) })
            .font(.system(size: 11.5, design: .monospaced)).lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.tuiBg)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.tuiHair, lineWidth: 1)))
            .textSelection(.enabled)
    }
}

/// working.html's `.seg` — a pill segmented control. Global-only theme picker; the
/// active segment lifts on a raised fill, both tuned to the current appearance.
private struct ThemeSeg: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ThemePref.allCases) { pref in
                let on = store.themePref == pref
                Button { store.themePref = pref } label: {
                    Text(pref.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? Theme.repoName : Theme.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(on ? Theme.raised : Color.clear)
                                .shadow(color: on ? Color.black.opacity(0.12) : .clear, radius: 1, y: 1)
                                .overlay(on ? RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.border, lineWidth: 0.5) : nil)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.rowSelected))
        .frame(maxWidth: 300, alignment: .leading)
    }
}

/// The Experimental → Tabs picker — the same pill segmented control as ThemeSeg, but a
/// two-state (Off / Tabs) flip over the off-by-default `tabsMode` preference.
private struct TabsSeg: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            seg("Off", on: !store.tabsMode) { store.tabsMode = false }
            seg("Tabs", on: store.tabsMode) { store.tabsMode = true }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.rowSelected))
        .frame(maxWidth: 300, alignment: .leading)
    }

    private func seg(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Theme.repoName : Theme.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(on ? Theme.raised : Color.clear)
                        .shadow(color: on ? Color.black.opacity(0.12) : .clear, radius: 1, y: 1)
                        .overlay(on ? RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.border, lineWidth: 0.5) : nil)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Edit in Global" — jumps scope without leaving settings (working.html data-goto).
private struct EditInGlobalLink: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        Button { store.settingsScope = .global } label: {
            Text("Edit in Global")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.input)
        }
        .buttonStyle(.plain)
    }
}

/// working.html .set-code — a dark rounded editor card with an uppercase label row.
/// Read-only cards render dimmed static text ("what also runs"); editable cards a live
/// TextEditor bound to the mock store.
private struct CodeCard<Trailing: View>: View {
    let label: String
    let text: Binding<String>
    var readOnly = false
    var minHeight: CGFloat = 130
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold)).kerning(0.5)
                    .foregroundStyle(Theme.navLabel)
                Spacer(minLength: 0)
                trailing()
            }
            editor
        }
    }

    @ViewBuilder private var editor: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        Group {
            if readOnly {
                Text(text.wrappedValue)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xD4D6DC))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .opacity(0.62)
            } else {
                TextEditor(text: text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xD4D6DC))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: minHeight)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(shape.fill(Theme.termBg))
        .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
    }
}

extension CodeCard where Trailing == EmptyView {
    init(label: String, text: Binding<String>, readOnly: Bool = false, minHeight: CGFloat = 130) {
        self.init(label: label, text: text, readOnly: readOnly, minHeight: minHeight, trailing: { EmptyView() })
    }
}

/// A workspace monogram chip (working.html .repo__chip) at an arbitrary size — shared
/// by the settings pane head and the run-order strip.
struct WsChip: View {
    let workspace: Workspace
    var size: CGFloat = 19

    var body: some View {
        let color = Theme.chipColors[workspace.colorIndex % Theme.chipColors.count]
        RoundedRectangle(cornerRadius: size * 0.32).fill(color)
            .frame(width: size, height: size)
            .overlay(Text(workspace.monogram)
                .font(.system(size: size * 0.58, weight: .semibold)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: size * 0.32).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0.75, y: 1)
    }
}
