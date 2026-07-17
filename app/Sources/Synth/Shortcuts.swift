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

private struct ShortcutGroup {
    let name: String
    let rows: [Shortcut]
}

/// Every binding, one glanceable modal — a straight port of working.html's SHORTCUTS.
struct ShortcutsSheet: View {
    private static let groups: [ShortcutGroup] = [
        ShortcutGroup(name: "General", rows: [
            Shortcut(keys: ["⌘", "K"], label: "Command menu"),
            Shortcut(keys: ["⌘", "N"], label: "New session"),
            Shortcut(keys: ["⌘", "T"], label: "New terminal"),
            Shortcut(keys: ["⌘", "D"], label: "Close current session"),
            Shortcut(keys: ["⌘", "B"], label: "Toggle sidebar"),
            Shortcut(keys: ["⌘", "0"], label: "Focus sidebar"),
            Shortcut(keys: ["⌘", "1"], label: "Focus open session"),
            Shortcut(keys: ["⌘", ","], label: "Settings"),
            Shortcut(keys: ["⌘", "?"], label: "Keyboard shortcuts"),
            Shortcut(keys: ["⌘", "⇧", "F"], label: "Send feedback"),
        ]),
        ShortcutGroup(name: "Sidebar", rows: [
            Shortcut(keys: ["↑", "↓"], label: "Move selection", alt: ["J", "K"]),
            Shortcut(keys: ["→", "←"], label: "Expand · collapse", alt: ["L", "H"]),
            Shortcut(keys: ["⇥"], label: "Toggle group"),
            Shortcut(keys: ["↵"], label: "Open session / toggle", alt: ["Space"]),
            Shortcut(keys: ["R"], label: "Rename selected"),
            Shortcut(keys: ["D"], label: "Close · remove selected"),
            Shortcut(keys: ["⇧J", "⇧K"], label: "Reorder down · up"),
        ]),
        ShortcutGroup(name: "Split layout", rows: [
            Shortcut(keys: ["⌘", "⇧", "→"], label: "Split toward arrow", alt: ["⌘", "|"]),
            Shortcut(keys: ["⌘", "⌥", "→"], label: "Focus pane (spatial)", alt: ["⌘", "⌥", "L"]),
            Shortcut(keys: ["⌘", "1"], label: "Focus pane N · sidebar", alt: ["⌘", "0"]),
            Shortcut(keys: ["⌘", "`"], label: "Cycle panes"),
            Shortcut(keys: ["⌘", "⌥", "⇧", "→"], label: "Resize active pane"),
            Shortcut(keys: ["⌘", "⇧", "⏎"], label: "Zoom / unzoom pane"),
            Shortcut(keys: ["⌘", "⇧", "U"], label: "Unsplit (keep running)"),
        ]),
        ShortcutGroup(name: "Browser", rows: [
            Shortcut(keys: ["⌘", "L"], label: "Go to address"),
            Shortcut(keys: ["⌘", "R"], label: "Reload page"),
            Shortcut(keys: ["⌘", "["], label: "Back"),
            Shortcut(keys: ["⌘", "]"], label: "Forward"),
            Shortcut(keys: ["⌥", "⌘", "I"], label: "Toggle DevTools"),
            Shortcut(keys: ["⌘", "⇧", "M"], label: "Toggle device mode"),
        ]),
        ShortcutGroup(name: "Command menu", rows: [
            Shortcut(keys: ["↑", "↓"], label: "Move", alt: ["⌃J", "⌃K"]),
            Shortcut(keys: ["↵"], label: "Open · drill in"),
            Shortcut(keys: ["⌫"], label: "Back (empty search)"),
            Shortcut(keys: ["esc"], label: "Close"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard shortcuts")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.name.uppercased())
                        .font(.system(size: 10, weight: .semibold)).kerning(0.5)
                        .foregroundStyle(Theme.navLabel)
                        .padding(.horizontal, 2).padding(.bottom, 5)
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 12) {
                            Text(row.label)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.ink2)
                            Spacer(minLength: 0)
                            HStack(spacing: 3) {
                                KeyCaps(keys: row.keys)
                                if let alt = row.alt {
                                    Text("or")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.inkMeta)
                                        .padding(.horizontal, 3)
                                    KeyCaps(keys: alt)
                                }
                            }
                        }
                        .padding(.horizontal, 2).padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.panel)
    }
}
