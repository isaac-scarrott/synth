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
                    scriptSection
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
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if isGlobal {
                    Phos(path: Phosphor.globe, size: 16)
                        .foregroundStyle(Theme.inkMuted).frame(width: 20)
                } else if let ws {
                    WsChip(workspace: ws, size: 19)
                }
                Text(name)
                    .font(.system(size: 13, weight: .semibold)).kerning(-0.13)
                    .foregroundStyle(Theme.ink)
            }
            (Text("Settings").fontWeight(.semibold)
                + Text(" / \(isGlobal ? "All workspaces" : name)"))
                .font(.system(size: 11, design: .monospaced)).kerning(-0.11)
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
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
                runOrderStrip
                CodeCard(label: "Global — runs first", text: globalBinding, readOnly: true,
                         trailing: { EditInGlobalLink() })
                    .padding(.top, 14)
                CodeCard(label: "\(name) — runs next", text: wsBinding)
                    .padding(.top, 14)
                note("Each runs in the new worktree's root. Times out after 5 minutes; a non-zero exit is reported but never blocks it.")
            }
        }
    }

    // working.html .set-flow — makes "both run, global first" legible at a glance.
    private var runOrderStrip: some View {
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
            Text("Both run · global first")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkMuted)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.025))
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
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold)).kerning(0.5)
                    .foregroundStyle(Color(hex: 0x9A9AA0))
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
                    .frame(minHeight: 130)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(shape.fill(Color(hex: 0x1B1B1E)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
    }
}

extension CodeCard where Trailing == EmptyView {
    init(label: String, text: Binding<String>, readOnly: Bool = false) {
        self.init(label: label, text: text, readOnly: readOnly, trailing: { EmptyView() })
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
