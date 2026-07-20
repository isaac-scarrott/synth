import Foundation

/// Best-effort native crash capture. PostHog only sees *caught* errors, but the crashes that
/// actually take Synth down — the vendored Ghostty/CEF engines, a `fatalError`, a bad memory
/// access — arrive as POSIX signals or uncaught exceptions that unwind the process before any
/// network send could finish. So the handler does the one thing that's safe from a crashing
/// thread: drop a tiny marker file to disk with async-signal-safe calls only. The NEXT launch
/// reads the marker, reports `app_crashed`, and deletes it — turning "it just vanished" into a
/// countable data point.
///
/// This is deliberately best-effort, not a forensic crash reporter: it records *that* a crash
/// happened and which signal, not a symbolicated stack. It also restores the default disposition
/// and re-raises, so the OS still writes its own `.crash` report for the deep dives.
enum CrashReporter {
    private static let markerURL = AppSupport.dir("crash").appendingPathComponent("last-crash")

    /// Report-and-clear any marker the previous run left behind. Call at launch AFTER
    /// `Analytics.bootstrap` so the event has somewhere to land (a no-op when analytics is off).
    @MainActor static func reportPending() {
        let path = markerURL.path
        guard let data = try? Data(contentsOf: markerURL),
              let signalName = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !signalName.isEmpty else { return }
        var props: [String: Any] = ["signal": signalName]
        if let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date {
            props["crashed_at"] = ISO8601DateFormatter().string(from: mtime)
        }
        Analytics.capture("app_crashed", props)
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Install the signal + uncaught-exception handlers. Call once at launch. The marker buffers
    /// are forced to initialize here, on the main thread — never lazily from a crashing thread.
    @MainActor static func install() {
        try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        _ = markerPathC.count
        for sig in signals { _ = bytes(for: sig) }
        _ = mNSException.count

        NSSetUncaughtExceptionHandler { _ in CrashReporter.onException() }
        for sig in signals { signal(sig, { s in CrashReporter.onSignal(s) }) }
    }

    // MARK: - The crashing-thread side (async-signal-safe only: no Swift String, no allocation)

    private static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGSYS]

    private static func onSignal(_ sig: Int32) {
        writeMarker(bytes(for: sig))
        signal(sig, SIG_DFL)   // restore the default so the OS still generates its crash report…
        raise(sig)             // …then let the crash proceed.
    }

    private static func onException() { writeMarker(mNSException) }

    /// open + write + close are all async-signal-safe; the path and payload are pre-rendered C
    /// buffers (initialized in `install`), so nothing here allocates.
    private static func writeMarker(_ payload: [UInt8]) {
        let fd = markerPathC.withUnsafeBufferPointer {
            open($0.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        guard fd >= 0 else { return }
        payload.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    private static let markerPathC: [CChar] = Array(markerURL.path.utf8CString)

    private static func bytes(for sig: Int32) -> [UInt8] {
        switch sig {
        case SIGABRT: return mSIGABRT
        case SIGSEGV: return mSIGSEGV
        case SIGBUS:  return mSIGBUS
        case SIGILL:  return mSIGILL
        case SIGFPE:  return mSIGFPE
        case SIGTRAP: return mSIGTRAP
        case SIGSYS:  return mSIGSYS
        default:      return mUnknown
        }
    }

    private static let mSIGABRT = Array("SIGABRT".utf8)
    private static let mSIGSEGV = Array("SIGSEGV".utf8)
    private static let mSIGBUS  = Array("SIGBUS".utf8)
    private static let mSIGILL  = Array("SIGILL".utf8)
    private static let mSIGFPE  = Array("SIGFPE".utf8)
    private static let mSIGTRAP = Array("SIGTRAP".utf8)
    private static let mSIGSYS  = Array("SIGSYS".utf8)
    private static let mNSException = Array("NSException".utf8)
    private static let mUnknown = Array("unknown".utf8)
}
