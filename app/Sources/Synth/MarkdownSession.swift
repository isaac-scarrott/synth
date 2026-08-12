import AppKit

/// Where the bundled synth-md payload lives, how a markdown session launches it, and what the
/// app tells it about itself (ADR-0016).
///
/// The payload is three things staged into `Contents/Resources/md` by `stage_resources`:
/// a vendored Bun runtime, the TUI as one bundled JS file, and OpenTUI's runtime assets
/// (native dylib + tree-sitter grammars + parser worker). Nothing on the user's machine is
/// required — no node, no bun, no npm — which is the whole point: a markdown row must open on
/// a fresh Mac exactly as it does here.
enum MarkdownSession {
    /// `Contents/Resources/md`, or nil in a build that never staged it — the TUI is then
    /// simply unavailable and `openFileLink` falls back to the OS handler.
    static var payloadURL: URL? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("md", isDirectory: true),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("synth-md.js").path)
        else { return nil }
        return root
    }

    /// The Bun slice for this machine. Synth ships arm64-only (app/vendor/fetch-cef.sh takes
    /// the macosarm64 CEF distro and dist.sh's `swift build` is host-arch), so there is one —
    /// but the lookup is arch-keyed so adding a slice is a build-script change, not this file.
    static var runtimeURL: URL? {
        guard let payload = payloadURL else { return nil }
        #if arch(arm64)
        let slice = "aarch64"
        #else
        let slice = "x64"
        #endif
        let bun = payload.appendingPathComponent("bun/\(slice)/bun")
        return FileManager.default.isExecutableFile(atPath: bun.path) ? bun : nil
    }

    static var isAvailable: Bool { runtimeURL != nil }

    /// The line a markdown session's login shell execs — the same `$SYNTH_LAUNCH_COMMAND`
    /// mechanism an agent row uses (TerminalManager), so PTY lifecycle, reaping and theming
    /// all come free.
    ///
    /// `exec`, not a plain run: the session exists to show this document, so quitting the TUI
    /// is the PTY child exiting, which is the child-exited signal that closes the row — the
    /// same contract an agent row has.
    static func launchCommand(path: String?) -> String? {
        // A markdown row is "a session showing this document", not "a session running
        // synth-md" — so which program renders it is the user's choice (Settings → Markdown)
        // and the row is the same either way.
        if case let .editor(binary) = preference, let path,
           let command = MarkdownOpener.launchCommand(binary: binary, path: path) {
            return command
        }
        guard let runtime = runtimeURL, let payload = payloadURL else { return nil }
        var words = ["exec", shellQuote(runtime.path), shellQuote(payload.appendingPathComponent("synth-md.js").path)]
        if let path { words.append(shellQuote(path)) }
        return words.joined(separator: " ")
    }

    /// Settings → Markdown, mirrored off the store so the surface — which builds its own launch
    /// line and holds no store reference — can read it. AppStore owns the value and keeps this
    /// in step; nothing else writes it.
    nonisolated(unsafe) static var preference: MarkdownOpen = .synth

    /// Whether a markdown row can be opened at all. The bundled TUI may be missing from a build
    /// that could not fetch Bun, but a chosen terminal editor still works — so this is not the
    /// same question as `isAvailable`.
    static var canOpenInSession: Bool {
        if case let .editor(binary) = preference { return MarkdownOpener.resolve(binary) != nil }
        return isAvailable
    }

    /// What the TUI needs to look and behave like part of Synth rather than a program that
    /// happens to be running inside it: the appearance, the palette, and the socket it hands
    /// non-document links back through so the app's existing routing applies (Store's
    /// `openTerminalLink`) instead of a second copy of those rules living in TypeScript.
    /// Both palettes travel, not just the current one. Ghostty announces the appearance to the
    /// program it runs and re-announces it on a flip, so the TUI re-themes in place — with only
    /// one palette in hand it would have to repaint a document in the scheme it was launched
    /// under. Env is fixed at spawn; the appearance is not.
    static func environment(dark: Bool, socketPath: String) -> [String: String] {
        var env: [String: String] = [
            "SYNTH_MD_APPEARANCE": dark ? "dark" : "light",
            "SYNTH_CTL_SOCKET": socketPath,
        ]
        let both = ["dark": palette(dark: true), "light": palette(dark: false)]
        if let data = try? JSONSerialization.data(withJSONObject: both),
           let json = String(data: data, encoding: .utf8) {
            env["SYNTH_MD_PALETTE"] = json
        }
        return env
    }

    /// Write the `synth` command into the session shim dir, beside the agent shims.
    ///
    /// A shell script rather than a symlink to `synth-hook`: its whole job is a one-line
    /// routing decision, and baking the payload's absolute paths in at install time means the
    /// script needs no environment to find them. `exec`, so `synth notes.md` REPLACES the
    /// shell — it behaves like typing `vim`, which is the locked feel.
    static func installCLI(into shimDir: String) {
        // Whatever Settings → Markdown says, so `synth notes.md` and a clicked link agree.
        // Re-written whenever that choice changes.
        let opener: String
        if case let .editor(binary) = preference, let resolved = MarkdownOpener.resolve(binary) {
            opener = shellQuote(resolved)
        } else if let runtime = runtimeURL, let payload = payloadURL {
            opener = shellQuote(runtime.path) + " "
                + shellQuote(payload.appendingPathComponent("synth-md.js").path)
        } else {
            // Nothing to open markdown with; the shim would only be `open`, which the user's
            // shell already does better.
            try? FileManager.default.removeItem(atPath: shimDir + "/synth")
            return
        }
        let script = """
        #!/bin/sh
        # synth — open a file the way Synth would (ADR-0016). Written by the running app.
        if [ $# -eq 0 ]; then
          echo "usage: synth <file>" >&2
          exit 2
        fi
        # Case-insensitive, because README.MD and Notes.Markdown are both real.
        case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
          *.md|*.markdown)
            [ -f "$1" ] && exec \(opener) "$1"
            ;;
        esac
        # Anything else is the OS's business, which is what this shell would have done anyway.
        exec open "$@"
        """
        let path = shimDir + "/synth"
        try? FileManager.default.removeItem(atPath: path)
        guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return }
        chmod(path, 0o755)
    }

    /// Theme.swift's tokens, resolved to hex for a process that cannot ask AppKit.
    ///
    /// A deliberate subset rather than the whole of Theme: these are the roles a *document*
    /// has — body ink, headings, links, code, quotes, rules — and mapping the app's surface
    /// tokens onto them one-to-one would be a coincidence, not a design. The TUI carries its
    /// own defaults for both appearances (theme.ts), so anything omitted here still lands on
    /// a considered value rather than nothing.
    private static func palette(dark: Bool) -> [String: String] {
        dark
            ? [
                "fg": "#E6E8ED",        // Theme.ink
                "muted": "#8D9099",     // Theme.inkMuted
                "faint": "#666A72",     // Theme.inkFaint
                "accent": "#EEE0CD",    // Theme.accent — the icon's champagne mark
                "heading": "#F2F4F8",
                "link": "#8AB4F8",
                "code": "#D8DEE9",
                "quote": "#A9ADB6",
                "rule": "#5E626D",      // 3.04:1 on the terminal card — a visible hairline
                "overlayBg": "#282B30", // Theme.raised
                "danger": "#E5534B",
              ]
            : [
                "fg": "#1C1E23",
                "muted": "#5B5E66",     // Theme.inkMeta, the tier that clears 4.5:1 on the coat
                "faint": "#8A8D95",
                "accent": "#A86038",    // Theme.accent — light's copper, the champagne fails here
                "heading": "#12141A",
                "link": "#194EB7",      // the light ANSI blue from TerminalTheme, 7:1 on paper
                "code": "#2B2D34",
                "quote": "#54565E",
                "rule": "#868C99",      // 3.17:1 on the paper
                "overlayBg": "#FFFFFF", // Theme.raised
                "danger": "#A2241A",
              ]
    }

    /// Single-quote for the login shell, mirroring GhosttySurfaceView's own quoting — a
    /// document path is user data and may contain spaces, quotes or anything else.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
