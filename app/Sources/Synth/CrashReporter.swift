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
    /// Pid-scoped. A single shared path meant two Synth instances overwrote each other's
    /// evidence, and the survivor reported one crash for two.
    private static let markerDir = AppSupport.dir("crash")
    private static let markerURL = markerDir.appendingPathComponent("last-crash-\(getpid())")

    /// Report-and-clear any marker the previous run left behind. Call at launch AFTER
    /// `Analytics.bootstrap` so the event has somewhere to land (a no-op when analytics is off).
    @MainActor static func reportPending() {
        // Every marker, not just this pid's: the crash we are reporting belongs to a process
        // that is gone, and its pid is not ours.
        let markers = (try? FileManager.default.contentsOfDirectory(at: markerDir,
                                                                    includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("last-crash-") } ?? []
        // The trail belongs to the run that crashed, so it is read before the fresh run
        // overwrites it — which `Fault`'s own trail file does at first touch.
        let trail = Fault.previousRunTrail()
        for marker in markers {
            guard let data = try? Data(contentsOf: marker),
                  let payload = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !payload.isEmpty else { continue }
            // "<signal>|<version>" — the version is pre-rendered at install so a crash on N,
            // reported after Sparkle staged N+1, stops being blamed on the build that fixed it.
            let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
            var props: [String: Any] = ["signal": parts[0]]
            if parts.count > 1 { props["crashed_version"] = parts[1] }
            if let mtime = (try? FileManager.default
                .attributesOfItem(atPath: marker.path)[.modificationDate]) as? Date {
                props["crashed_at"] = ISO8601DateFormatter().string(from: mtime)
            }
            // What the run was doing on its way down. Closed vocabulary, so it is wire-safe
            // by the same rule as every other fault property.
            if !trail.isEmpty { props["trail"] = trail.joined(separator: ",") }
            Analytics.capture("app_crashed", props)
            try? FileManager.default.removeItem(at: marker)
        }
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

    /// Pre-rendered here, not at crash time: a crashing thread may not allocate, and the
    /// version is exactly the thing the next launch can no longer be trusted to know.
    private static let versionSuffix: [UInt8] = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return Array("|\(v)".utf8)
    }()
    private static func marker(_ name: String) -> [UInt8] { Array(name.utf8) + versionSuffix }

    private static let mSIGABRT = marker("SIGABRT")
    private static let mSIGSEGV = marker("SIGSEGV")
    private static let mSIGBUS  = marker("SIGBUS")
    private static let mSIGILL  = marker("SIGILL")
    private static let mSIGFPE  = marker("SIGFPE")
    private static let mSIGTRAP = marker("SIGTRAP")
    private static let mSIGSYS  = marker("SIGSYS")
    private static let mNSException = marker("NSException")
    private static let mUnknown = marker("unknown")
}
