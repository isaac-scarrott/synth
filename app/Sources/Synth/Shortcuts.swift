import SwiftUI

/// working.html's `.cmdk__key` — a small rounded key-cap. Shared by the palette's
/// trailing shortcut hints and the ⌘? shortcuts sheet.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.inkMuted)
            .lineLimit(1).fixedSize()
            .frame(minWidth: 17)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.rowSelected)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 0.5))
            )
    }
}

/// A run of key-caps rendered edge to edge (working.html's `.sc-row__keys`).
struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { KeyCap(text: $0) }
        }
    }
}

// MARK: - Shortcuts sheet (⌘?)

/// One binding row: a label, its keys, and optional alternate keys shown after "or".
private struct Shortcut {
    let keys: [String]
    let label: String
    var alt: [String]? = nil
}

/// One tab of the shortcuts sheet — a named, icon'd category of bindings.
private struct ShortcutCategory {
    let name: String
    let icon: String          // Phosphor path
    let rows: [Shortcut]
}

extension AppStore {
    /// Walk the shortcuts sheet's category sidebar, clamped to its bounds.
    func moveShortcutsCategory(_ delta: Int) {
        let n = ShortcutsSheet.categoryCount
        shortcutsCategory = max(0, min(n - 1, shortcutsCategory + delta))
    }
}

/// Every binding, grouped into categories with a keyboard-navigable sidebar (↑/↓ or j/k) and a
/// detail pane — so the set stays glanceable as it grows, and reads like the rest of the app.
struct ShortcutsSheet: View {
    @Environment(AppStore.self) private var store

    // Ordered by importance: the everyday app chords, then the two things you drive constantly
    // (the ⌘K menu and the sidebar), then the power features, then contextual surfaces.
    fileprivate static let categories: [ShortcutCategory] = [
        ShortcutCategory(name: "General", icon: Phosphor.keys, rows: [
            Shortcut(keys: ["⌘", "K"], label: "Command menu", alt: ["⌃", "K"]),
            Shortcut(keys: ["⌘", "N"], label: "New session"),
            Shortcut(keys: ["⌘", "T"], label: "New terminal"),
            Shortcut(keys: ["⌘", "D"], label: "Close current session"),
            Shortcut(keys: ["⌘", "B"], label: "Toggle sidebar"),
            Shortcut(keys: ["⌘", "⏎"], label: "Jump to latest notification"),
            Shortcut(keys: ["⌘", ","], label: "Settings"),
            Shortcut(keys: ["⌘", "?"], label: "Keyboard shortcuts"),
            Shortcut(keys: ["⌘", "⇧", "F"], label: "Send feedback"),
            Shortcut(keys: ["⌘", "Q"], label: "Quit (confirms if busy)"),
        ]),
        ShortcutCategory(name: "Command menu", icon: Phosphor.search, rows: [
            Shortcut(keys: ["↑", "↓"], label: "Move", alt: ["⌃J", "⌃K"]),
            Shortcut(keys: ["↵"], label: "Open · drill in"),
            Shortcut(keys: ["⌫"], label: "Back (empty search)"),
            Shortcut(keys: ["⌘", "K"], label: "Close", alt: ["esc"]),
        ]),
        ShortcutCategory(name: "Sidebar", icon: Phosphor.sidebar, rows: [
            Shortcut(keys: ["↑", "↓"], label: "Move selection", alt: ["J", "K"]),
            Shortcut(keys: ["→", "←"], label: "Expand · collapse", alt: ["L", "H"]),
            Shortcut(keys: ["⇥"], label: "Toggle group"),
            Shortcut(keys: ["↵"], label: "Open session · toggle", alt: ["Space"]),
            Shortcut(keys: ["A"], label: "New session in row"),
            Shortcut(keys: ["R"], label: "Rename selected"),
            Shortcut(keys: ["D"], label: "Close · remove selected"),
            Shortcut(keys: ["⇧J", "⇧K"], label: "Reorder down · up"),
            Shortcut(keys: ["esc"], label: "Focus content"),
        ]),
        ShortcutCategory(name: "Split layout", icon: Phosphor.squares, rows: [
            Shortcut(keys: ["⌘", "⇧", "→"], label: "Split toward arrow", alt: ["⌘", "|"]),
            Shortcut(keys: ["⌘", "⇧", "—"], label: "Split stacked (below)"),
            Shortcut(keys: ["⌘", "⌥", "→"], label: "Focus pane (spatial)", alt: ["⌘", "⌥", "L"]),
            Shortcut(keys: ["⌘", "1"], label: "Focus pane N", alt: ["⌘", "9"]),
            Shortcut(keys: ["⌘", "0"], label: "Focus sidebar"),
            Shortcut(keys: ["⌘", "`"], label: "Cycle next · previous", alt: ["⌘", "⇧", "`"]),
            Shortcut(keys: ["⌘", "⌥", "⇧", "→"], label: "Resize active pane"),
            Shortcut(keys: ["⌘", "⇧", "⏎"], label: "Zoom / unzoom pane"),
            Shortcut(keys: ["⌘", "⇧", "U"], label: "Unsplit (keep running)"),
        ]),
        ShortcutCategory(name: "Browser", icon: Phosphor.globe, rows: [
            Shortcut(keys: ["⌘", "L"], label: "Go to address"),
            Shortcut(keys: ["⌘", "R"], label: "Reload page"),
            Shortcut(keys: ["⌘", "["], label: "Back"),
            Shortcut(keys: ["⌘", "]"], label: "Forward"),
            Shortcut(keys: ["⌥", "⌘", "I"], label: "Toggle DevTools"),
            Shortcut(keys: ["⌘", "⇧", "M"], label: "Toggle device mode"),
            Shortcut(keys: ["esc"], label: "Exit comment mode"),
        ]),
    ]
    static var categoryCount: Int { categories.count }

    private var selected: Int { min(max(0, store.shortcutsCategory), Self.categories.count - 1) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 0.5)
            detail
        }
        .frame(width: 600, height: 428)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    // The category rail — icon + name, the selected one wearing the app's copper accent pill.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SHORTCUTS")
                .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                .foregroundStyle(Theme.navLabel)
                .padding(.leading, 10).padding(.top, 4).padding(.bottom, 8)
            ForEach(Array(Self.categories.enumerated()), id: \.offset) { i, cat in
                CategoryRow(icon: cat.icon, name: cat.name, selected: i == selected) {
                    store.shortcutsCategory = i
                }
            }
            Spacer(minLength: 0)
            // Keyboard-first affordance — this sheet is driven by the keyboard.
            HStack(spacing: 6) {
                KeyCaps(keys: ["↑", "↓"])
                Text("navigate").font(.system(size: 10.5)).foregroundStyle(Theme.inkMeta)
                Spacer(minLength: 0)
                KeyCap(text: "esc")
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
        }
        .padding(.vertical, 14).padding(.horizontal, 8)
        .frame(width: 194)
        .background(Theme.sidebar)
    }

    private var detail: some View {
        let cat = Self.categories[selected]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Phos(path: cat.icon, size: 15).foregroundStyle(Theme.copper).frame(width: 16)
                Text(cat.name)
                    .font(.system(size: 14, weight: .semibold)).kerning(-0.1)
                    .foregroundStyle(Theme.ink)
            }
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(cat.rows.enumerated()), id: \.offset) { idx, row in
                        if idx > 0 { Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 0.5) }
                        HStack(spacing: 12) {
                            Text(row.label)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.ink2)
                            Spacer(minLength: 0)
                            HStack(spacing: 3) {
                                KeyCaps(keys: row.keys)
                                if let alt = row.alt {
                                    Text("or").font(.system(size: 10.5))
                                        .foregroundStyle(Theme.inkMeta).padding(.horizontal, 3)
                                    KeyCaps(keys: alt)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One category row in the shortcuts sidebar — the sidebar-row idiom: icon + name, the selected
/// one wearing the copper accent tint, hover deepening it, matching the session rows.
private struct CategoryRow: View {
    let icon: String
    let name: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Phos(path: icon, size: 14)
                    .foregroundStyle(selected ? Theme.copper : Theme.inkMuted)
                    .frame(width: 15)
                Text(name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.inkOpen : Theme.sessionName)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Theme.accent.opacity(selected ? (hovering ? 0.16 : 0.11) : (hovering ? 0.06 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
