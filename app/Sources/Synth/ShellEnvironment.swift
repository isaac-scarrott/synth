import Foundation

/// The PATH a login+interactive shell sees — the exact PATH `TerminalLauncher` launches agents
/// under (`${SHELL:-/bin/zsh} -l -i`), and far richer than the app process's PATH under a
/// Dock/Finder launch. That launch inherits only the bare macOS default (`/usr/bin:/bin:…`),
/// missing every version-manager shim — nvm, fnm, volta, asdf, mise, bun, pnpm — and any custom
/// prefix. Agent detection consults this so a Dock launch resolves the same binaries a launched
/// agent will, instead of falling back to a fixed hint list that misses those installs.
///
/// Probed once, off the main thread, with a timeout so a slow or interactive rc file (oh-my-zsh's
/// update prompt, nvm/asdf installers) can't wedge detection.
enum ShellEnvironment {
    private static let lock = NSLock()
    private static var cachedDirs: [String]?
    private static var cachedAliases: [String: String]?
    private static var probeStarted = false
    private static var resolved = false
    private static let resolvedCond = NSCondition()

    /// The login-shell PATH split into dirs, or nil until the probe resolves (or gives up).
    /// Detection falls back to the process PATH while this is nil.
    static var loginPathDirs: [String]? {
        lock.lock(); defer { lock.unlock() }
        return cachedDirs
    }

    /// The shell's own aliases, name → expansion. A command Synth is pointed at may be one of
    /// these rather than a program (`claude-personal=claudewho-personal`), and an alias lives
    /// only inside an interactive shell — so this probe is the ONLY place Synth can learn what
    /// the user's own name for their agent actually stands for. Nil until the probe resolves,
    /// and empty for a shell that has none (or isn't zsh).
    static var loginAliases: [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return cachedAliases
    }

    /// Block until the probe has landed (or timed out), then return. For callers that need the
    /// login shell's answer to do their job at all — `AgentProbe` resolves a typed command
    /// against it — rather than merely preferring it. It blocks, so it belongs off the main
    /// thread, or in a check mode that has no UI to hold up (`AgentCheck`).
    static func waitUntilResolved(timeout: TimeInterval = 6) {
        prewarm {}
        resolvedCond.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while !resolved, resolvedCond.wait(until: deadline) {}
        resolvedCond.unlock()
    }

    /// Kick the probe off once, off the main thread; `onResolve` runs on completion — success,
    /// timeout, or failure alike — so a caller can refresh anything it derived from the process
    /// PATH. Idempotent: later calls no-op, and only the first `onResolve` fires.
    static func prewarm(onResolve: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !probeStarted else { lock.unlock(); return }
        probeStarted = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let answer = probe()
            lock.lock(); cachedDirs = answer?.dirs; cachedAliases = answer?.aliases ?? [:]; lock.unlock()
            resolvedCond.lock(); resolved = true; resolvedCond.broadcast(); resolvedCond.unlock()
            onResolve()
        }
    }

    /// Run `${SHELL:-/bin/zsh} -l -i -c '…'` — matching `TerminalLauncher`'s launch convention —
    /// and return its PATH dirs and aliases. A `\u{01}` sentinel brackets the PATH and a `\u{04}`
    /// pair brackets the alias table, so rc-file chatter printed before our command can't be
    /// mistaken for either. stdin is `/dev/null` so an rc file that reads the tty can't block on
    /// a keypress that never comes. Nil on non-zero exit, unparseable output, or timeout.
    ///
    /// The alias table is read out of zsh's own `$aliases` map rather than parsed back out of
    /// `alias -L`, which would mean unpicking shell quoting to get at the value. `$galiases` and
    /// `$saliases` are deliberately left out: a global or suffix alias never stands for a
    /// command. The whole clause is behind `$ZSH_VERSION` and inside `eval`, so a login shell
    /// that isn't zsh never parses zsh syntax — it just reports no aliases.
    private static func probe() -> (dirs: [String], aliases: [String: String])? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let aliasDump = "if [ -n \"$ZSH_VERSION\" ]; then "
            + "eval 'for k in \"${(@k)aliases}\"; do printf \"%s\\003%s\\002\" \"$k\" \"${aliases[$k]}\"; done'; fi"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-i", "-c",
                          "printf '\\001%s\\001\\004' \"$PATH\"; \(aliasDump); printf '\\004'"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        // Drain on a background queue so a chatty rc file can't fill the pipe buffer and deadlock
        // the child before it exits; join with a timeout and give up (kill the shell) if it hangs.
        let box = DataBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 4) == .timedOut {
            proc.terminate()
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let out = String(data: box.data, encoding: .utf8) else { return nil }
        // The sentinel-bracketed segment is the PATH; everything around it is rc-file noise.
        let parts = out.components(separatedBy: "\u{01}")
        guard parts.count >= 3 else { return nil }
        let dirs = parts[1].split(separator: ":").map(String.init)
        return dirs.isEmpty ? nil : (dirs, parseAliases(out))
    }

    /// The `\u{04}`-bracketed table: `name\u{03}expansion` records separated by `\u{02}`.
    private static func parseAliases(_ out: String) -> [String: String] {
        let sections = out.components(separatedBy: "\u{04}")
        guard sections.count >= 3 else { return [:] }
        var table: [String: String] = [:]
        for record in sections[1].components(separatedBy: "\u{02}") {
            let f = record.components(separatedBy: "\u{03}")
            guard f.count == 2, !f[0].isEmpty else { continue }
            table[f[0]] = f[1]
        }
        return table
    }

    /// Ferries the drained output across the semaphore's happens-before edge.
    private final class DataBox: @unchecked Sendable { var data = Data() }
}
