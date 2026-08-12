import Foundation

/// Where a markdown file opens when you click one (Settings → Markdown).
///
/// Three answers, and no more: Synth's own document surface, a terminal editor in a Synth
/// session, or whatever the Mac already opens the file with. The middle one is the reason this
/// setting exists at all — plenty of people read and write markdown in nvim or helix and would
/// rather keep doing that, and Synth can host it in a session just as well as it hosts an agent.
enum MarkdownOpen: Codable, Sendable, Hashable {
    /// The bundled synth-md TUI (ADR-0016).
    case synth
    /// A terminal editor, by binary name ("nvim", "hx", "nano"), in a Synth terminal session.
    case editor(String)
    /// Hand it to macOS.
    case defaultApp
}

extension MarkdownOpen: RawRepresentable {
    /// Persisted verbatim, with the editor's binary name inline — same shape as SessionKind's,
    /// so an unknown value degrades to the default rather than throwing the snapshot away.
    var rawValue: String {
        switch self {
        case .synth: return "synth"
        case .defaultApp: return "default"
        case .editor(let binary): return "editor:" + binary
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "synth": self = .synth
        case "default": self = .defaultApp
        default:
            guard rawValue.hasPrefix("editor:") else { return nil }
            let binary = String(rawValue.dropFirst("editor:".count))
            guard !binary.isEmpty else { return nil }
            self = .editor(binary)
        }
    }
}

/// One terminal editor Synth found on this machine.
struct TerminalEditor: Identifiable, Sendable, Hashable {
    /// The binary name, which is also the id: only one `nvim` can win on a PATH.
    var id: String { binary }
    let binary: String
    let name: String
    /// The absolute path detection resolved, which is what the launch line uses — a bare name
    /// would resolve again inside the login shell and could pick a different one.
    let path: String
}

enum MarkdownOpener {
    /// The terminal editors worth offering, in the order they are listed. Deliberately a fixed
    /// set rather than "anything on PATH": the list is a menu, and a menu of every executable
    /// on the machine is not a menu. `$EDITOR` is folded in below, which covers the rest.
    private static let known: [(binary: String, name: String)] = [
        ("nvim", "Neovim"),
        ("vim", "Vim"),
        ("hx", "Helix"),
        ("helix", "Helix"),
        ("micro", "Micro"),
        ("emacs", "Emacs"),
        ("nano", "Nano"),
        ("vi", "Vi"),
    ]

    /// Directories to search beyond the login shell's own PATH.
    ///
    /// `ShellEnvironment.loginPathDirs` is the real answer and covers every install mechanism
    /// the user actually uses — Homebrew on either prefix, MacPorts, Nix, asdf/mise shims,
    /// cargo, uv — because it is *their* shell's PATH, not a guess. These are the fallback for
    /// the window before that probe resolves, and for a Dock launch that inherits almost
    /// nothing: the standard prefixes, plus the per-user ones a login shell would have added.
    private static let hintDirs = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        "/opt/local/bin",                                   // MacPorts
        "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin", // Nix
        "~/.nix-profile/bin",
        "~/.local/bin", "~/.cargo/bin", "~/bin",
    ]

    /// Terminal editors present on this machine, deduplicated by binary, in menu order.
    ///
    /// `$EDITOR` is included even when it is not in the known list, because someone who has set
    /// it has already told us what they want and it would be strange to omit it.
    static func installed() -> [TerminalEditor] {
        var found: [TerminalEditor] = []
        var seen = Set<String>()

        for entry in known {
            guard !seen.contains(entry.binary), let path = resolve(entry.binary) else { continue }
            seen.insert(entry.binary)
            found.append(TerminalEditor(binary: entry.binary, name: entry.name, path: path))
        }

        if let editor = ProcessInfo.processInfo.environment["EDITOR"]?
            .split(separator: " ").first.map(String.init),
           let binary = editor.split(separator: "/").last.map(String.init),
           !seen.contains(binary), let path = resolve(editor) {
            found.append(TerminalEditor(binary: binary, name: binary, path: path))
        }
        return found
    }

    /// The absolute path of `binary`, or nil. An absolute name is taken as given.
    static func resolve(_ binary: String) -> String? {
        let fm = FileManager.default
        if binary.hasPrefix("/") {
            return fm.isExecutableFile(atPath: binary) ? binary : nil
        }
        let home = NSHomeDirectory()
        let processPath: [String] = ProcessInfo.processInfo.environment["PATH"]?
            .components(separatedBy: ":") ?? []
        let hints: [String] = hintDirs.map { $0.replacingOccurrences(of: "~", with: home) }
        var dirs: [String] = ShellEnvironment.loginPathDirs ?? []
        dirs.append(contentsOf: processPath)
        dirs.append(contentsOf: hints)
        for dir in dirs {
            let candidate = dir + "/" + binary
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The launch line for a terminal session that edits `path` in `binary`.
    ///
    /// `exec`, like every other launch line here: the session exists to hold this editor, so
    /// quitting it is the PTY child exiting, which is what closes the row.
    static func launchCommand(binary: String, path: String) -> String? {
        guard let resolved = resolve(binary) else { return nil }
        return "exec " + shellQuote(resolved) + " " + shellQuote(path)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
