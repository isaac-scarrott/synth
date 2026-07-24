import AppKit
import GhosttyKit

/// The terminal's ghostty configuration, themed to match the app appearance — the native
/// counterpart of working.html's `--tui-*` tokens. Light mode is a cool near-white surface
/// carrying the app's own ink. Dark mode overrides only the background (the near-black
/// `--tui-bg`), so the surface — and the padding band ghostty fills with it — reads as one
/// continuous dark card with the app frame; foreground and ANSI palette ride on Claude Code's
/// own dark theme rather than fighting it. Everything else (font, padding, clipboard, the
/// shell-integration=none used by the env scrub) is scheme-independent and lives here too.
enum TerminalTheme {
    /// Colours for one appearance. Backgrounds/foreground plus a full 16-colour ANSI palette
    /// (0–7 normal, 8–15 bright), kept in step with the HTML design tokens.
    private struct Palette {
        let bg, fg, cursor, selection: String
        let ansi: [String]   // 16 entries
    }

    // Light-mode legibility: the hue set holds 7:1 on the surface and the bright set (9–14) is
    // *deeper* than normal — TUIs lean on bright for emphasis, and on a light background
    // "brighter" must mean deeper ink, not lighter. Brights stop at 9:1 rather than going as
    // dark as they can: past that the six hues collapse into each other and into black.
    // Slots 7 and 15 are the exception and stay light. They are what a TUI paints *under*
    // white-on-colour — selected rows, inverse video, status bars — and inverting them to ink
    // dropped those to 1.04:1. Anything wanting readable body text uses the default fg.
    private static let light = Palette(
        bg: "f7f8fa", fg: "1c1e23", cursor: "1c1e23", selection: "d0d9e6",
        ansi: ["1c1e23", "a2241a", "106236", "754d09", "194eb7", "86289e", "075d6f", "9296a1",
               "5b5e68", "851d16", "0d4f2c", "5f3e07", "143f96", "6e2082", "064c5b", "ffffff"])

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func configString(dark: Bool) -> String {
        let base = """
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
        """
        // Dark mode overrides only the background: `window-padding-color = background` fills the
        // padding band with it, so this keeps the surface flush with the app's near-black frame
        // instead of leaking ghostty's lighter default. Foreground and palette stay Claude Code's.
        guard !dark else { return base + "\nbackground = 121317" }
        let c = Self.light
        let palette = c.ansi.enumerated()
            .map { "palette = \($0.offset)=#\($0.element)" }
            .joined(separator: "\n")
        return base + "\n" + """
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
