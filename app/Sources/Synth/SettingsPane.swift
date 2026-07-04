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
                    scriptSection
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
                IconButton(path: Phosphor.sidebar, help: "Expand sidebar") {
                    store.sidebarCollapsed = false
                }
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
                + Text(" / \(isGlobal ? "All workspaces" : name)"))
                .font(.system(size: 11, design: .monospaced)).kerning(-0.11)
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, store.sidebarCollapsed ? 76 : 18)
        .padding(.trailing, 18)
        .frame(height: store.sidebarCollapsed ? 30 : 44)
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

    // MARK: The one setting so far — the worktree setup script.

    @ViewBuilder private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Worktree setup script")
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.repoName)
            if isGlobal {
                sub("Runs once inside every new worktree, right after it's created — across all workspaces.")
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

    // MARK: Claude Code flags — default flags passed to `claude` on session start.

    @ViewBuilder private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude Code flags")
                .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                .foregroundStyle(Theme.repoName)
            if isGlobal {
                (Text("Passed to ") + Text("claude").font(.system(size: 12, design: .monospaced))
                    + Text(" every time a Claude Code session starts — across all workspaces."))
                    .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                    .lineSpacing(3).padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(Array(AppStore.commonClaudeFlags.enumerated()), id: \.offset) { i, f in
                        FlagToggleRow(flag: f.flag, label: f.label, desc: f.desc, first: i == 0)
                    }
                }
                .padding(.top, 10)
                CodeCard(label: "flags", text: globalFlagsBinding, minHeight: 44).padding(.top, 14)
                CmdPreview(flags: store.globalClaudeFlags).padding(.top, 14)
                claudeNote
            } else {
                (Text("Flags for ") + Text(name).fontWeight(.semibold)
                    + Text(" Claude sessions. These override the global flags for this workspace — leave empty to inherit global."))
                    .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                    .lineSpacing(3).padding(.top, 4)
                flowStrip(note: "Workspace overrides global").padding(.top, 14)
                CodeCard(label: "Global — inherited when empty", text: .constant(store.globalClaudeFlags),
                         readOnly: true, minHeight: 44, trailing: { EditInGlobalLink() }).padding(.top, 14)
                CodeCard(label: "\(name) — overrides global", text: wsFlagsBinding, minHeight: 44).padding(.top, 14)
                CmdPreview(flags: store.claudeFlags(for: ws)).padding(.top, 14)
            }
        }
    }

    private var claudeNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Phos(path: Phosphor.info, size: 14).foregroundStyle(Color(hex: 0xB0B0B5)).padding(.top, 1)
            (Text("Any ") + Text("claude").font(.system(size: 11.5, design: .monospaced))
                + Text(" flag works here — the switches are shortcuts for common ones. Add anything else in the field, like ")
                + Text("--model opus").font(.system(size: 11.5, design: .monospaced)) + Text("."))
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
            Phos(path: Phosphor.caret, size: 15).foregroundStyle(Color(hex: 0xC2C2C7))
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
            Phos(path: Phosphor.info, size: 14).foregroundStyle(Color(hex: 0xB0B0B5)).padding(.top, 1)
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

    private var globalFlagsBinding: Binding<String> {
        Binding(get: { store.globalClaudeFlags }, set: { store.globalClaudeFlags = $0 })
    }
    private var wsFlagsBinding: Binding<String> {
        let id = ws?.id
        return Binding(
            get: { id.flatMap { store.wsClaudeFlags[$0] } ?? "" },
            set: { v in if let id { store.wsClaudeFlags[id] = v } }
        )
    }
}

/// One switch row in the Claude-flags list: a human label + the raw flag (mono, blue) +
/// a one-line description, with a native toggle bound to the global flag set.
private struct FlagToggleRow: View {
    @Environment(AppStore.self) private var store
    let flag: String
    let label: String
    let desc: String
    var first: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.repoName)
                    Text(flag).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dyn(0x2B6FD6, 0x8AB4F8))
                }
                Text(desc).font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted).lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { store.hasClaudeFlag(flag) },
                                     set: { _ in store.toggleClaudeFlag(flag) }))
                .labelsHidden().toggleStyle(.switch).tint(Theme.attention).controlSize(.small)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Theme.border).frame(height: 0.5) }
        }
    }
}

/// The effective `claude …` launch line, flags tinted like a terminal command — mirrors
/// working.html's `.set-cmd` preview on the terminal-card surface.
private struct CmdPreview: View {
    let flags: String
    private var tokens: [String] { flags.split(whereSeparator: \.isWhitespace).map(String.init) }

    var body: some View {
        let blue = Theme.dyn(0x2B6FD6, 0x8AB4F8)
        (Text("$ ").foregroundStyle(Theme.inkMuted) + Text("claude").foregroundStyle(Theme.repoName)
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

/// "Edit in Global" — jumps scope without leaving settings (working.html data-goto).
private struct EditInGlobalLink: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        Button { store.settingsScope = .global } label: {
            Text("Edit in Global")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.attention)
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
                    .foregroundStyle(Color(hex: 0xD4D4D8))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .opacity(0.62)
            } else {
                TextEditor(text: text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xD4D4D8))
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
