import Foundation

/// Keeps Claude Code's own theme in step with Synth's appearance.
///
/// Claude Code never reads the terminal's 16-colour palette — it paints with a hard-coded
/// truecolor theme of its own, defaults to `dark`, and (as of 2.1.217) does no background
/// detection: there is no OSC 11 query anywhere in the binary. So a light Synth was running
/// Claude Code's *dark* theme, whose body text is `#ffffff`, against a light surface — 1.03:1,
/// invisible. TerminalTheme cannot reach this; only the agent's own config can.
///
/// `theme` in `~/.claude.json` is the only lever the CLI exposes. It is not a settings.json key,
/// takes no environment variable, and the `config` subcommand that used to set it is gone, so
/// `--settings` injection at spawn (how the launch shim does hooks) is not available here.
/// That makes this a global write: `claude` started from a plain terminal picks it up too.
enum AgentTheme {
    private static let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")

    /// Point Claude Code at the light or dark half of its own theme pair.
    ///
    /// Read-modify-write of a file Claude Code also owns, so this writes only when the value
    /// actually changes — appearance flips are rare, surface re-themes are not, and every
    /// needless write is a chance to land on top of the agent's own save. A missing or
    /// unparseable config is left alone: it is Claude Code's to create, not ours to invent.
    ///
    /// Only new sessions pick this up. Claude Code reads the theme once at startup, so a
    /// session already on screen when the appearance flips keeps the theme it launched with.
    static func sync(dark: Bool) {
        let wanted = dark ? "dark" : "light"
        guard let data = try? Data(contentsOf: configURL),
              var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        // Leave the daltonized and ANSI variants alone — someone who picked one chose it for
        // legibility, and flipping them to plain light/dark would undo that.
        if let current = config["theme"] as? String {
            guard current == "dark" || current == "light" else { return }
            guard current != wanted else { return }
        }
        config["theme"] = wanted
        guard let out = try? JSONSerialization.data(withJSONObject: config) else { return }
        try? out.write(to: configURL, options: .atomic)
    }
}
