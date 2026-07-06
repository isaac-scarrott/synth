import AppKit
import GhosttyKit

/// The terminal's ghostty configuration, themed to match the app appearance — the native
/// counterpart of design.html's `--tui-*` tokens. Light mode is a warm "paper" surface with
/// a muted-but-legible palette; dark mode is a deep near-black card with brighter accents.
/// Everything else (font, padding, clipboard, the shell-integration=none used by the env
/// scrub) is scheme-independent and lives here too, so one config fully describes a surface.
enum TerminalTheme {
    /// Colours for one appearance. Backgrounds/foreground plus a full 16-colour ANSI palette
    /// (0–7 normal, 8–15 bright), kept in step with the HTML design tokens.
    private struct Palette {
        let bg, fg, cursor, selection: String
        let ansi: [String]   // 16 entries
    }

    // Light-mode legibility: every colour holds ≥4.5:1 contrast on the paper bg, and the
    // bright set (8–15) is *darker* than normal — TUIs lean on bright for emphasis, and on
    // a light background "brighter" must mean deeper ink, not lighter.
    private static let light = Palette(
        bg: "f4f2ec", fg: "33333a", cursor: "33333a", selection: "d8e4f5",
        ansi: ["33333a", "c03a30", "1e7f42", "8a660c", "2361c4", "8b40b5", "16717a", "6e6e78",
               "6b6b74", "a52e25", "176b37", "75560a", "1c4fa8", "76349c", "115e66", "26262b"])

    private static let dark = Palette(
        bg: "131315", fg: "e3e3e7", cursor: "e3e3e7", selection: "333a48",
        ansi: ["2a2a30", "ec6a5e", "6fcf8e", "e0b45f", "6fa2ee", "c398e8", "5fc9c1", "cfcfd4",
               "7e7e88", "ff8a80", "8fe0a8", "f0c674", "8ab4f8", "d8b6fb", "86e3dc", "f6f6f8"])

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func configString(dark: Bool) -> String {
        let c = dark ? Self.dark : Self.light
        let palette = c.ansi.enumerated()
            .map { "palette = \($0.offset)=#\($0.element)" }
            .joined(separator: "\n")
        return """
        font-family = SF Mono
        font-size = 12
        term = xterm-256color
        cursor-style = block
        mouse-hide-while-typing = true
        window-padding-x = 8
        window-padding-y = 6
        window-padding-color = background
        clipboard-read = allow
        clipboard-write = allow
        confirm-close-surface = false
        shell-integration = none
        background = \(c.bg)
        foreground = \(c.fg)
        cursor-color = \(c.cursor)
        selection-background = \(c.selection)
        \(palette)
        """
    }

    /// Build a finalized `ghostty_config_t` for the given appearance. Caller owns it and must
    /// `ghostty_config_free` it after handing it to `ghostty_app_new`/`ghostty_surface_update_config`.
    static func makeConfig(dark: Bool) -> ghostty_config_t {
        let config = ghostty_config_new()!   // ghostty_config_new never returns null
        let s = configString(dark: dark)
        s.withCString { cstr in
            "/synth-terminal.conf".withCString { path in
                ghostty_config_load_string(config, cstr, UInt(s.utf8.count), path)
            }
        }
        ghostty_config_finalize(config)
        return config
    }
}
