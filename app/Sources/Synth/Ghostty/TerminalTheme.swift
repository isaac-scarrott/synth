import AppKit
import GhosttyKit

/// The terminal's ghostty configuration, themed to match the app appearance — the native
/// counterpart of working.html's `--tui-*` tokens. Light mode is a cool near-white surface
/// carrying the app's own ink. Dark mode overrides only the background (the near-black
/// `--tui-bg`), so the surface — and the padding band ghostty fills with it — reads as one
/// continuous dark card with the app frame; foreground and ANSI palette ride on Claude Code's
/// own dark theme rather than fighting it. Everything else (font, padding, clipboard, the
/// shell-integration=none used by the env scrub) is scheme-independent and lives here too.
///
/// The asymmetry is the whole point: dark is the terminal every TUI was written for, so it needs
/// one line. Light has to answer for colours a tool picked while looking at a dark screen — which
/// is what the palette and `lightFaintOpacity` below are for. It answers only where a terminal is
/// entitled to: the sixteen themeable slots, and how strongly faint renders. The scheme itself is
/// announced to the TUI by ghostty (DEC 2031), so anything that themes itself — Claude Code,
/// opencode — has already switched by the time these apply.
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

    // The 256-colour ramp above slot 15 is deliberately left alone, and the reason is worth
    // keeping: slots 0–15 are what a terminal theme is *for* — every theme redefines them and
    // tools expect it — while 16–255 are a fixed standard a tool addresses by absolute value.
    // Mirroring the greyscale ramp (232–255) so a light surface reads it the way its author
    // meant was tried and reverted. It fixes the half of the usage where the ramp supplies the
    // foreground alone (`38;5;250` as body text goes 1.8:1 → 10.7:1) and breaks every pairing
    // where it supplies only the *background*: a status bar of `bg=colour236` under pinned white
    // ink is a dark band with light text before, and a light band with white text after. tmux
    // with a stock powerline config was unreadable. One palette cannot serve both sides, and the
    // side that breaks is the one the tool nailed down.
    //
    // So `38;5;250` as body text stays at 1.8:1 here, and fzf's selected row stays a dark slab.
    // Those are the tool's own dark preset resolving against a standard palette — answerable
    // where the tool is configured (`fzf --color=light`), not by re-basing the palette underneath
    // every other tool that reads it correctly.

    /// How much of the foreground survives SGR 2 (faint), which ghostty renders by blending the
    /// text toward the background. The default half-and-half is symmetric but its *result* is
    /// not: the same mid grey it lands on reads at 5.3:1 over the dark card and 3.2:1 here,
    /// because a mid grey is far nearer white than black. Faint is not decoration — it is what
    /// spinners, hints and timestamps are written in — so light keeps more of the ink and buys
    /// back the ratio dark gets for free. Dark keeps the default.
    private static let lightFaintOpacity = 0.65

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
        faint-opacity = \(Self.lightFaintOpacity)
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
