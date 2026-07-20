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
    private static var probeStarted = false

    /// The login-shell PATH split into dirs, or nil until the probe resolves (or gives up).
    /// Detection falls back to the process PATH while this is nil.
    static var loginPathDirs: [String]? {
        lock.lock(); defer { lock.unlock() }
        return cachedDirs
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
            let dirs = probe()
            lock.lock(); cachedDirs = dirs; lock.unlock()
            onResolve()
        }
    }

    /// Run `${SHELL:-/bin/zsh} -l -i -c 'printf …$PATH'` — matching `TerminalLauncher`'s launch
    /// convention — and return its PATH dirs. A `\u{01}` sentinel brackets the value so rc-file
    /// chatter printed before our command can't be mistaken for it. stdin is `/dev/null` so an rc
    /// file that reads the tty can't block on a keypress that never comes. Nil on non-zero exit,
    /// unparseable output, or timeout.
    private static func probe() -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-i", "-c", "printf '\\001%s\\001' \"$PATH\""]
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
        return dirs.isEmpty ? nil : dirs
    }

    /// Ferries the drained output across the semaphore's happens-before edge.
    private final class DataBox: @unchecked Sendable { var data = Data() }
}
