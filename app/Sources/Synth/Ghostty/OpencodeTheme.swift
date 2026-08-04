import Foundation

/// Installs Synth's opencode theme, which exists for one reason: opencode's light half is too pale.
///
/// The contrast with `AgentTheme` is the whole story, and it is worth writing down because the two
/// agents look like the same problem and are not. opencode's theme *machinery* works. It asks the
/// terminal what colour it is (OSC 10/11), it enables DEC mode 2031, and — measured — it re-themes a
/// **running** session when ghostty announces the appearance changed. Claude Code does neither: its
/// `auto` ignores every 2031 notification, and its theme key is read once at startup. So opencode
/// needs no live rewriting and no re-theming path at all; a theme file carries `{dark, light}` for
/// every key in one document and opencode picks the half itself.
///
/// What it needs is better light values. On the surfaces opencode paints for itself, its own light
/// half leaves `textMuted` at **3.17:1**, `accent` and `warning` at **2.52:1**, and seven more ink
/// colours under 4.5:1 — placeholder text, headings, keywords, diff context. Eleven values are
/// deepened, hue kept; the dark half is copied through untouched, byte for byte.
///
/// Two consequences of opencode's design that shaped this:
///
/// **The theme has to be complete.** A partial file crashes opencode on startup —
/// `undefined is not an object (evaluating 'a.background.a')` — so this is necessarily a fork of
/// opencode's default rather than a patch over it, and it will drift when opencode changes its own.
/// `t25_opencodecontrast` is the answer to that: it renders a real opencode against this file, so a
/// missing or stale key fails as a crash-to-no-runs rather than passing quietly.
///
/// **opencode paints its own background.** It does not let the terminal's show through, which is why
/// the ratios above are measured against `backgroundElement` (`#f5f5f5`) rather than
/// `TerminalTheme`'s surface. It also means an opencode pane is opaque and sits out the window's
/// translucency — noted, not fixed; that is a theme file's `background`, and overriding it to match
/// would be a guess at a colour the terminal composites rather than owns.
enum OpencodeTheme {
    private static let slug = "synth"

    /// opencode reads its config from `$XDG_CONFIG_HOME/opencode`, falling back to `~/.config`.
    /// Honoured here because opencode honours it — a session inherits the login shell's environment
    /// (`ShellEnvironment`), so someone who sets it really does move the directory.
    static func configDir(home: URL = AgentTheme.defaultHome()) -> URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode")
        }
        return home.appendingPathComponent(".config/opencode")
    }

    /// Theme settings Synth will take over: none set, opencode's own default, its terminal-following
    /// mode, and Synth's own. `system` is adopted rather than left alone because it is the setting
    /// this fix is *for* — it already follows the appearance correctly, and all Synth changes is
    /// which values it follows it with. Anything else is someone having picked catppuccin or gruvbox
    /// on purpose, and is left exactly alone.
    private static let adoptable: Set<String> = ["system", "opencode", slug]

    /// Copy the theme into place and point `tui.json` at it.
    ///
    /// Appearance-independent — the file holds both halves — so this takes no `dark:`. It is still
    /// called from the appearance path, which costs nothing (both writes are conditional on content
    /// changing) and makes it self-healing if the file is deleted underneath a running Synth.
    static func sync(home: URL = AgentTheme.defaultHome()) {
        guard let theme = bundledTheme() else { return }
        let dir = configDir(home: home)
        // Unlike Claude Code's config, `tui.json` is opencode's to create *or not* — a fresh install
        // has no such file and no theme setting, and that is the case this most needs to work. So an
        // absent file is written rather than treated as a refusal.
        guard adopt(dir: dir) else { return }
        let dest = dir.appendingPathComponent("themes/\(slug).json")
        if let existing = try? Data(contentsOf: dest), existing == theme { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? theme.write(to: dest, options: .atomic)
    }

    /// Claim `theme` in `tui.json`, preserving every other key in it.
    private static func adopt(dir: URL) -> Bool {
        let url = dir.appendingPathComponent("tui.json")
        var config: [String: Any] = ["$schema": "https://opencode.ai/tui.json"]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return false }   // a file we cannot parse is one we must not overwrite
            config = parsed
            if let current = config["theme"] as? String {
                guard adoptable.contains(current) else { return false }
                guard current != slug else { return true }
            }
        }
        config["theme"] = slug
        // `withoutEscapingSlashes` because this file is the user's to read: the `$schema` URL comes
        // back out as `https:\/\/opencode.ai/...` without it, which is valid JSON and looks broken.
        guard let out = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try out.write(to: url, options: .atomic)
        } catch {
            return false
        }
        return true
    }

    /// The theme as shipped. Looked up by hand rather than `Bundle.module` (which fatalErrors when
    /// the dev bundle misses the copy), mirroring `ChangelogPane`'s lookup.
    private static func bundledTheme() -> Data? {
        var bundles: [URL] = []
        if let r = Bundle.main.resourceURL {
            bundles.append(r.appendingPathComponent("Synth_Synth.bundle"))
        }
        if let e = Bundle.main.executableURL?.deletingLastPathComponent() {
            bundles.append(e.appendingPathComponent("Synth_Synth.bundle"))
        }
        for url in bundles {
            if let bundle = Bundle(url: url),
               let res = bundle.url(forResource: "opencode-theme", withExtension: "json"),
               let data = try? Data(contentsOf: res) {
                return data
            }
        }
        NSLog("Synth: opencode-theme.json resource missing — opencode keeps its own theme")
        return nil
    }
}
