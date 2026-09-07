import Foundation

/// Installs Synth's opencode theme, which exists for two reasons: opencode's light half is too pale,
/// and opencode paints its own background where Claude Code lets the terminal's show through.
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
/// deepened, hue kept; the dark half is copied through untouched but for `background`, below.
///
/// **The background is handed back to the terminal.** opencode painted every cell of its own field
/// — `#ffffff` in light, `#0a0a0a` in dark — while ghostty fills the `window-padding` band around it
/// with `TerminalTheme`'s surface, so a pane drew a rectangle inset 23pt from its own edge and sat
/// out the window's translucency besides. opencode's answer to this is `"none"`, which it documents
/// as blending with the terminal, and which does work — except that it also anchors the neutral ramp
/// opencode *derives* surfaces from, and a zero-alpha black anchor turns the splash mark's shadow
/// into two near-black slabs on a light screen (measured: `#dbdbdb` → `#1c1c1c`). So `background` is
/// `TerminalTheme`'s own surface written at zero alpha — `#f7f8fa00` / `#12131700` — which paints
/// nothing and still says what is behind it. Every cell then comes back as the terminal's default,
/// and the derived shadow lands on `#d5d6d7` rather than in the dark. `t25_opencodecontrast` gates
/// both halves of that: the field is unpainted, and the pair matches `TerminalTheme`.
///
/// One consequence of opencode's design shaped the rest:
///
/// **The theme has to be complete.** A partial file crashes opencode on startup —
/// `undefined is not an object (evaluating 'a.background.a')` — so this is necessarily a fork of
/// opencode's default rather than a patch over it, and it will drift when opencode changes its own.
/// `t25_opencodecontrast` is the answer to that: it renders a real opencode against this file, so a
/// missing or stale key fails as a crash-to-no-runs rather than passing quietly.
enum OpencodeTheme {
    private static let slug = "synth"

    /// opencode reads its config from `$XDG_CONFIG_HOME/opencode`, falling back to `~/.config`.
    /// Honoured here because opencode honours it — a session inherits the login shell's environment
    /// (`ShellEnvironment`), so someone who sets it really does move the directory. v2 shares the
    /// directory with v1, including its `themes/`, and differs only in which file names the theme.
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

    /// Copy the theme into place and point opencode at it.
    ///
    /// Appearance-independent — the file holds both halves — so this takes no `dark:`. It is still
    /// called from the appearance path, which costs nothing (both writes are conditional on content
    /// changing) and makes it self-healing if the file is deleted underneath a running Synth.
    static func sync(home: URL = AgentTheme.defaultHome()) {
        guard let theme = bundledTheme() else { return }
        let dir = configDir(home: home)
        // Both, and neither short-circuited: v1 and v2 name the theme in different files, and a
        // machine can be running either or both.
        let v1 = adoptTUI(dir: dir)
        let v2 = adoptCLI(dir: dir, home: home)
        guard v1 || v2 else { return }
        let dest = dir.appendingPathComponent("themes/\(slug).json")
        if let existing = try? Data(contentsOf: dest), existing == theme { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? theme.write(to: dest, options: .atomic)
    }

    /// Claim `theme` in v1's `tui.json`, preserving every other key in it.
    private static func adoptTUI(dir: URL) -> Bool {
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
        // Unlike v2's, `tui.json` is opencode's to create *or not* — a fresh install has no such
        // file and no theme setting, and that is the case this most needs to work. So an absent file
        // is written rather than treated as a refusal.
        config["theme"] = slug
        return write(config, to: url)
    }

    /// Claim `theme.name` in v2's `cli.json`, preserving every other key in it — `theme.mode`
    /// included, which is v2's own light/dark following and none of Synth's business.
    ///
    /// An absent file is created only where `mayCreateCLIConfig` allows it — the one place this
    /// differs from `tui.json`, and the reason is not symmetry.
    private static func adoptCLI(dir: URL, home: URL) -> Bool {
        let url = dir.appendingPathComponent("cli.json")
        var config: [String: Any] = ["$schema": "https://opencode.ai/v2/cli.json"]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return false }
            config = parsed
        } else if !mayCreateCLIConfig(dir: dir, home: home) {
            return false
        }
        var theme: [String: Any] = [:]
        if let existing = config["theme"] {
            // A `theme` that is not v2's object is a hand-edit we have no reading of, and replacing
            // it would throw away whatever it meant.
            guard let object = existing as? [String: Any] else { return false }
            theme = object
            if let current = theme["name"] as? String {
                guard adoptable.contains(current) else { return false }
                guard current != slug else { return true }
            }
        }
        theme["name"] = slug
        config["theme"] = theme
        return write(config, to: url)
    }

    /// The one rule about creating v2's `cli.json`, for every claim Synth makes in it — the theme
    /// here, the stop gesture in `Opencode2Supervisor`.
    ///
    /// v2 writes the file itself, once, by migrating v1's `tui.json` and its key-value state into
    /// it — and it performs that migration only while the file does not already exist. Creating it
    /// ahead of a migration that is still owed would skip it silently and drop every v1 preference
    /// the user had. So where either source is still standing, this waits: v2 writes the file on
    /// its next run and the claim lands on the one after.
    ///
    /// Where neither is — a machine that never ran v1 — there is nothing to wait for, and waiting
    /// would mean a fresh install never getting Synth's theme at all, nor its stop gesture, since
    /// v2 has no reason of its own to write the file until the user changes a preference in it.
    static func mayCreateCLIConfig(dir: URL, home: URL = AgentTheme.defaultHome()) -> Bool {
        let fm = FileManager.default
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/state")
        return !fm.fileExists(atPath: dir.appendingPathComponent("tui.json").path)
            && !fm.fileExists(atPath: state.appendingPathComponent("opencode/kv.json").path)
    }

    private static func write(_ config: [String: Any], to url: URL) -> Bool {
        // `withoutEscapingSlashes` because these files are the user's to read: the `$schema` URL
        // comes back out as `https:\/\/opencode.ai/...` without it, which is valid JSON and looks
        // broken.
        guard let out = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
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
