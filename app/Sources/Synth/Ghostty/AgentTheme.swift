import Foundation

/// Keeps Claude Code's own theme in step with Synth's appearance — and, in light mode, answers for
/// the colours it picks there.
///
/// Claude Code never reads the terminal's 16-colour palette; it paints with a truecolor theme of its
/// own. `TerminalTheme` cannot reach any of that, so this is the only lever, and the whole design
/// turns on one measured fact: **the `theme` key in `~/.claude.json` is read once, at startup.**
/// Rewriting it does nothing to a session already on screen, so the old approach left every open
/// session on whichever theme it launched with. Flip Synth to light with sessions running and they
/// keep painting Claude Code's dark theme onto a near-white surface, where its body text (`#ffffff`)
/// measures **1.06:1** and 57 of its 72 colour tokens fall under 4.5:1. That is the bug this exists
/// to close, and a key that only new sessions read cannot close it.
///
/// What *is* live is the custom-theme directory: Claude Code watches `~/.claude/themes` and reloads
/// on any change. So Synth ships one theme of its own, `custom:synth`, and re-themes by rewriting
/// that file — which a running session picks up within a second, in both directions. Three things
/// then follow from a single `base`, which is why it is one file and not a light/dark pair:
///   • the 72 colour tokens come from that base
///   • so does the syntax highlighter (Claude Code derives it from the *resolved* base — GitHub for
///     light, Monokai Extended for dark — not from the theme's name)
///   • so does the diff renderer
///
/// The asymmetry mirrors `TerminalTheme`'s: dark rides Claude Code's own theme untouched, because
/// dark is what every one of these colours was chosen against. Light carries `lightOverrides`.
enum AgentTheme {
    /// Where Claude Code keeps its config and the directory it watches for custom themes. Both
    /// assume the default location; `CLAUDE_CONFIG_DIR` would move them, and Synth does not set it.
    ///
    /// `home` is a parameter rather than a constant so a test can point this at a scratch directory.
    /// It has to be: `NSHomeDirectory()` reads the password database, *not* `$HOME`, for a process
    /// that is not sandboxed — so a harness that exports `HOME` and calls this would rewrite the
    /// developer's own `~/.claude.json` while believing it was working in a temp directory.
    static func defaultHome() -> URL { URL(fileURLWithPath: NSHomeDirectory()) }

    private static func configURL(_ home: URL) -> URL {
        home.appendingPathComponent(".claude.json")
    }

    private static func themeURL(_ home: URL) -> URL {
        home.appendingPathComponent(".claude/themes/\(slug).json")
    }

    private static let slug = "synth"
    private static let ref = "custom:synth"

    /// Theme settings Synth will take over. `light` and `dark` are the plain pair this used to
    /// write; `auto` is here because "Auto (match terminal)" does not match the terminal — it was
    /// measured resolving to *dark* on a light surface and staying there through every DEC 2031
    /// theme-change notification the terminal sends, which is the unreadable case above. Following
    /// the appearance is what `auto` asks for, so adopting it honours the choice rather than
    /// overriding it. Anything else — daltonized, ANSI-only, someone's own custom theme — is a
    /// deliberate pick for legibility and is left exactly alone.
    private static let adoptable: Set<String> = ["light", "dark", "auto", ref]

    /// Light-mode corrections, measured against `TerminalTheme`'s light surface (`#f7f8fa`).
    ///
    /// Every value keeps its token's hue and saturation and lowers only its lightness — the least
    /// change that clears the floor, so Claude Code still looks like Claude Code. Text is held to
    /// 4.5:1 (WCAG 1.4.3) and the four non-text tokens to 3:1 (1.4.11): `promptBorder` and
    /// `bashBorder` draw panels, `rate_limit_fill` is a bar, `clawd_body` is the mascot silhouette.
    ///
    /// The worst offender is `subtle` at **2.06:1** — the dim grey every hint, timestamp and token
    /// count is written in, which is what "grey text on a white background" turns out to be.
    ///
    /// Deliberately absent, because overriding them would be the wrong fix:
    ///   • `inverseText` is white by design and only ever painted *on* a fill — the fill has to earn
    ///     the ratio, which is why `professionalBlue` (its usual backing) is corrected instead
    ///   • `*Shimmer` is the bright frame of a sweep across text already measured at rest
    ///   • `rainbow_*` is decoration that never carries meaning alone
    ///   • the background tokens are judged by what gets painted on them, not against the surface
    ///   • `clawd_background` is the mascot's silhouette — brand artwork, not a contrast decision
    ///   • `diffAddedWord` / `diffRemovedWord` read like foregrounds and are not: they are the fill
    ///     behind a changed *word* inside a diff line, and Claude Code paints black on them.
    ///     Deepening them to clear 4.5:1 as ink drove the ink *on* them from ~17:1 down to 4.28:1 —
    ///     measured, then reverted. A fill is corrected by what it has to carry, not by its own
    ///     ratio against a surface it never touches.
    private static let lightOverrides: [String: String] = [
        "blue_FOR_SUBAGENTS_ONLY": "#3b74ad",          // 2.75 → 4.61
        "briefLabelClaude": "#ba502c",                  // 2.96 → 4.63
        "chromeYellow": "#8f6b02",                      // 1.61 → 4.63
        "claude": "#ba502c",                            // 2.96 → 4.63
        "claudeBlue_FOR_SYSTEM_SPINNER": "#4c5ff6",     // 4.14 → 4.62
        "clawd_body": "#d57251",                        // 2.96 → 3.11 (non-text)
        "cyan_FOR_SUBAGENTS_ONLY": "#077b97",           // 3.47 → 4.61
        "fastMode": "#bd4f00",                          // 2.70 → 4.62
        "green_FOR_SUBAGENTS_ONLY": "#12823b",          // 3.10 → 4.62
        "ide": "#3772b9",                               // 3.73 → 4.63
        "orange_FOR_SUBAGENTS_ONLY": "#bc4f2b",         // 2.94 → 4.60
        "permission": "#4c5ff6",                        // 4.14 → 4.62
        "pink_FOR_SUBAGENTS_ONLY": "#b94a70",           // 3.53 → 4.62
        "professionalBlue": "#3b74ad",                  // 2.75 → 4.61
        "promptBorder": "#8d8d8d",                      // 2.68 → 3.12 (non-text)
        "purple_FOR_SUBAGENTS_ONLY": "#6e68b3",         // 3.52 → 4.60
        "subtle": "#707070",                            // 2.06 → 4.66
        "suggestion": "#4c5ff6",                        // 4.14 → 4.62
        "warning": "#92691d",                           // 4.43 → 4.64
        "yellow_FOR_SUBAGENTS_ONLY": "#976703",         // 2.76 → 4.64
    ]

    /// Point Claude Code at the light or dark half of Synth's own theme.
    ///
    /// Both writes are conditional on the content actually changing. Appearance flips are rare and
    /// surface re-themes are not — `applyTheme` runs on every window move between displays — and
    /// each needless write to `~/.claude.json` is a chance to land on top of the agent's own save,
    /// while each needless write to the theme file wakes every running session's watcher.
    static func sync(dark: Bool, home: URL = defaultHome()) {
        guard adopt(home: home) else { return }
        writeTheme(dark: dark, home: home)
    }

    /// Claim the `theme` setting unless the user has chosen something Synth has no business
    /// touching. Returns whether `custom:synth` is the theme in force, and so whether the theme
    /// file is ours to write.
    ///
    /// A missing or unparseable config is left alone: it is Claude Code's to create, not ours to
    /// invent.
    private static func adopt(home: URL) -> Bool {
        let url = configURL(home)
        guard let data = try? Data(contentsOf: url),
              var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        if let current = config["theme"] as? String {
            guard adoptable.contains(current) else { return false }
            guard current != ref else { return true }
        }
        config["theme"] = ref
        guard let out = try? JSONSerialization.data(withJSONObject: config) else { return false }
        do {
            try out.write(to: url, options: .atomic)
        } catch {
            return false
        }
        return true
    }

    private static func writeTheme(dark: Bool, home: URL) {
        let theme: [String: Any] = [
            "name": "Synth",
            "base": dark ? "dark" : "light",
            // Claude Code keeps only overrides whose key exists in the base theme, so an unknown
            // key is dropped rather than rejected — a stale name costs the correction, not the file.
            "overrides": dark ? [:] : lightOverrides,
        ]
        guard let out = try? JSONSerialization.data(withJSONObject: theme,
                                                   options: [.sortedKeys, .prettyPrinted])
        else { return }
        let url = themeURL(home)
        if let existing = try? Data(contentsOf: url), existing == out { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? out.write(to: url, options: .atomic)
    }
}
