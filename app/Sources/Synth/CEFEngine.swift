#if canImport(CEFShim)
import AppKit
import CEFShim

/// Owns the process-wide CEF runtime and profile hygiene (ADR-0011): the cache root, the
/// per-workspace profile directories under it, one CDP port per app instance, and
/// stale-root sweeping.
///
/// Stage five made the profiles PERSIST, which decides the layout:
///
///     BrowserProfiles/shared/<workspace-key>/    kept; the user clears it, nothing else
///     BrowserProfiles/instance-<pid>/<key>/      the fallback root, swept when the pid dies
///
/// `shared` is the root every instance wants, because that is where the logins are. It can
/// only have one: Chromium takes a process-singleton lock on `root_cache_path` and a second
/// CefInitialize against the same root is refused outright (cef_types.h: "Multiple
/// application instances writing to the same root_cache_path directory could result in data
/// corruption. A process singleton lock based on the root_cache_path value is therefore
/// used"). CEF cannot be re-initialized after a failed init, so there is no retrying it —
/// the claim has to be settled BEFORE CefInitialize. Hence our own flock beside the root: a
/// second Synth of this channel loses it, falls back to a per-instance root, and gets a
/// working browser with an empty profile rather than no browser at all. `profilesPersist`
/// says which happened, so the fallback is a fact the app can state rather than a silent
/// last-writer-wins.
@MainActor
final class BrowserProcessSupervisor {
    static let shared = BrowserProcessSupervisor()

    private(set) var cdpPort: UInt16 = 0
    /// False when another live Synth of this channel holds the persistent root and this
    /// instance is running on a throwaway one. Its browsers work; their logins die with it.
    private(set) var profilesPersist = true
    private var initialized = false
    private var root: URL?
    /// Set only for a root this instance owns outright — the one shutdown may delete.
    private var transientRoot: URL?
    private var lockFD: Int32 = -1
    private var terminationObserver: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    private static let profilesRoot = AppSupport.dir("BrowserProfiles")
    private static let sharedRoot = profilesRoot.appendingPathComponent("shared", isDirectory: true)
    private static let sharedLock = profilesRoot.appendingPathComponent("shared.lock")

    private init() {}

    func ensureInitialized() throws {
        guard !initialized else { return }

        let frameworkPath = Bundle.main.bundlePath
            + "/Contents/Frameworks/Chromium Embedded Framework.framework"
        guard FileManager.default.fileExists(atPath: frameworkPath) else {
            throw BrowserEngineFactory.Unavailable(reason:
                "CEF framework missing from the app bundle — launch a bundle assembled by app/dev.sh or app/dist.sh")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: Self.profilesRoot, withIntermediateDirectories: true)
        sweepDeadInstances()

        let root: URL
        if claimSharedRoot() {
            root = Self.sharedRoot
        } else {
            profilesPersist = false
            root = Self.profilesRoot.appendingPathComponent(
                "instance-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            transientRoot = root
            NSLog("Synth: another Synth holds the persistent browser profile root — this " +
                  "instance's browsers start signed out and forget everything on quit")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        guard let port = Self.allocateCDPPort(range: 9300...9399) else {
            releaseSharedRoot()
            if let transient = transientRoot { try? fm.removeItem(at: transient) }
            throw BrowserEngineFactory.Unavailable(reason: "no free CDP port in 9300-9399")
        }

        let automation = ProcessInfo.processInfo.environment["SYNTH_AUTOMATION"] == "1"
        guard CEFShimRuntime.initialize(
            withRootCachePath: root.path, cdpPort: port, automation: automation) else {
            releaseSharedRoot()
            if let transient = transientRoot { try? fm.removeItem(at: transient) }
            throw BrowserEngineFactory.Unavailable(reason:
                "CefInitialize failed — see cef.log under \(root.path)")
        }

        self.root = root
        cdpPort = port
        initialized = true
        // Advertise the endpoint to CDP clients (no-op in --browser-check mode).
        InstanceRegistry.shared.setCDPPort(port)

        // CEF processes must be down before the app exits, or the survivors absorb
        // the next launch's singleton.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BrowserProcessSupervisor.shared.shutdownNow() }
        }

        // willTerminate never fires for bare signals, and CefInitialize installed
        // Chromium's own SIGTERM handler, which posts shutdown to the browser UI
        // thread and exits Chromium's way — bypassing state save, CefShutdown, and
        // profile cleanup. Take the signals ourselves (SIG_IGN replaces Chromium's
        // handler; DispatchSource delivers on main) and route them through the
        // normal quit path, so the observer above and the store's save both run.
        //
        // SIGKILL needs no belt-and-braces here: Chromium's parent-death cleanup
        // collects all helpers within ~2s of the browser process dying (verified),
        // and the next launch's sweepDeadInstances() removes the orphaned profile dir.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                // Mark this a non-interactive quit BEFORE terminating, so the first
                // applicationShouldTerminate already sees it and skips the confirm dialog —
                // otherwise a modal stacks against the signal-driven kill and the save is lost.
                MainActor.assumeIsolated { AppTermination.forceQuit = true }
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Full teardown: force-close every browser, CefShutdown, and let go of the root. CEF
    /// cannot re-initialize afterwards; app-exit (or check-mode) only. The persistent root
    /// survives — the whole point of stage five is that quitting is not a reason to forget
    /// your logins — so only a throwaway root is deleted here.
    func shutdownNow() {
        guard initialized else { return }
        CEFShimRuntime.shutdown()
        initialized = false
        reapHelpers()
        if let transient = transientRoot {
            try? FileManager.default.removeItem(at: transient)
            transientRoot = nil
        }
        releaseSharedRoot()
        root = nil
    }

    // MARK: - The persistent root, and who holds it

    /// Takes the flock guarding `shared`, or reports that someone else has it. Non-blocking
    /// and held for the process's life: the kernel drops it on exit or crash, so a Synth
    /// that died without tidying up never locks the next one out. This is deliberately OUR
    /// lock rather than Chromium's — Chromium's answer only arrives as a failed
    /// CefInitialize, which cannot be retried with different settings.
    private func claimSharedRoot() -> Bool {
        let fd = open(Self.sharedLock.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        lockFD = fd
        return true
    }

    private func releaseSharedRoot() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }

    /// CefShutdown returns while children are still exiting gracefully (observed ~6s
    /// lag); anything slower gets SIGKILL. Only OUR direct children — another Synth
    /// launched from the same bundle shares the helper paths but not the parent pid.
    private func reapHelpers() {
        let deadline = Date(timeIntervalSinceNow: 3)
        var survivors = helperChildPIDs()
        while !survivors.isEmpty && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            survivors = helperChildPIDs()
        }
        for pid in survivors { kill(pid, SIGKILL) }
    }

    private func helperChildPIDs() -> [pid_t] {
        let helperPrefix = Bundle.main.bundlePath + "/Contents/Frameworks/Synth Helper"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(ProcessInfo.processInfo.processIdentifier)",
                          "-f", helperPrefix]
        let out = Pipe()
        task.standardOutput = out
        guard (try? task.run()) != nil else { return [] }
        task.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n").compactMap { pid_t($0) } ?? []
    }

    /// The profile every browser session in one workspace shares. One directory, not one
    /// per session: the workspace is the unit the user thinks in, and two sessions on the
    /// same repo being signed in as different people would be a surprise, not isolation.
    func profileDirectory(workspaceKey: String) throws -> URL {
        guard let root else {
            throw BrowserEngineFactory.Unavailable(reason: "browser runtime not initialized")
        }
        let dir = root.appendingPathComponent(workspaceKey, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where a workspace's profile is right now: under the live root once the runtime is up,
    /// under the persistent one before that — which is where it will land the moment a
    /// browser opens. Settings measures this and Clear removes it, so they never disagree.
    func profilePath(workspaceKey: String) -> URL {
        (root ?? Self.sharedRoot).appendingPathComponent(workspaceKey, isDirectory: true)
    }

    /// Throws away one workspace's profile — the only thing that deletes one now, and only
    /// because the user asked (stage five: the old lifecycle deleted every profile on close
    /// and never asked anyone).
    ///
    /// The directory is renamed aside rather than emptied in place, so a new engine can be
    /// built on the same path the same instant. The renamed copy is removed now and again at
    /// +2s and +6s: CEF's profile flush can land after the browser is gone and resurrect a
    /// just-closed profile as a husk, and a path that is never reused cannot catch a live
    /// profile the way deleting in place could.
    ///
    /// Callers must have torn the workspace's engines down first — a profile with a live
    /// browser on it is not the caller's to delete.
    func clearProfile(workspaceKey: String) {
        guard let root else { return }
        let dir = root.appendingPathComponent(workspaceKey, isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        let aside = Self.profilesRoot.appendingPathComponent(
            ".cleared-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.moveItem(at: dir, to: aside)) != nil else {
            // Nowhere to move it to (a full disk, a permissions change) — emptying in place
            // is the honest fallback, and the husk it may leave is one profile's worth of
            // files that the next clear takes out.
            try? fm.removeItem(at: dir)
            return
        }
        try? fm.removeItem(at: aside)
        for delay in [2.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                try? FileManager.default.removeItem(at: aside)
            }
        }
    }

    /// Deletes throwaway roots whose owning pid is gone (crashed / killed instances), and
    /// any `.cleared-*` copy a clear didn't finish removing before the app went away. The
    /// persistent `shared` root is never a candidate — that is the one thing here that is
    /// supposed to outlive every process.
    private func sweepDeadInstances() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: Self.profilesRoot, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".cleared-") {
                try? fm.removeItem(at: entry)
                continue
            }
            guard name.hasPrefix("instance-"),
                  let pid = Int32(name.dropFirst("instance-".count)) else { continue }
            // kill(pid, 0): probe liveness without signaling. ESRCH means gone.
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Bind-probes 127.0.0.1 for a port CEF's DevTools server can take.
    private static func allocateCDPPort(range: ClosedRange<UInt16>) -> UInt16? {
        for port in range where portIsFree(port) { return port }
        return nil
    }

    private static func portIsFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

/// The production BrowserEngine: CEF 144 behind the shim, one page per engine, on the
/// workspace's profile — which it shares with every other session in that workspace and
/// leaves behind when it closes (stage five).
@MainActor
final class CEFEngine: NSObject, BrowserEngine {
    weak var delegate: BrowserEngineDelegate?

    private let shim: CEFShimBrowser
    let cdpPort: UInt16

    private(set) var currentURL: URL?
    private(set) var pageTitle: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    var view: NSView { shim.view }

    init(initialURL: URL, sessionID: UUID, workspaceKey: String) throws {
        let supervisor = BrowserProcessSupervisor.shared
        try supervisor.ensureInitialized()
        let profileDir = try supervisor.profileDirectory(workspaceKey: workspaceKey)
        guard let shim = CEFShimBrowser(
            url: initialURL.absoluteString,
            cachePath: profileDir.path,
            sessionId: sessionID.uuidString,
            frame: NSRect(x: 0, y: 0, width: 900, height: 600)
        ) else {
            throw BrowserEngineFactory.Unavailable(reason: "CEF refused to create a browser")
        }
        self.shim = shim
        self.cdpPort = supervisor.cdpPort
        self.currentURL = initialURL
        super.init()
        shim.delegate = self
    }

    func navigate(to url: URL) { shim.navigate(url.absoluteString) }
    func goBack() { shim.goBack() }
    func goForward() { shim.goForward() }
    func reload() { shim.reload() }
    // CEF zoom is logarithmic: factor = 1.2^level, so level = log₁.₂(factor).
    func setZoom(_ factor: Double) { shim.setZoomLevel(factor > 0 ? log(factor) / log(1.2) : 0) }
    func showDevTools() { shim.showDevTools() }
    func closeDevTools() { shim.closeDevTools() }
    var devToolsOpen: Bool { shim.hasDevTools() }

    func shutdown() {
        shim.close()   // async; the workspace's profile stays exactly where it is
    }
}

extension CEFEngine: CEFShimBrowserDelegate {
    // The shim calls back on the main thread (CEF UI thread under the external pump);
    // assumeIsolated re-enters MainActor without a hop.
    nonisolated func cefBrowserAddressDidChange(_ url: String) {
        MainActor.assumeIsolated {
            guard let parsed = URL(string: url) else { return }
            currentURL = parsed
            delegate?.engine(self, addressDidChange: parsed)
        }
    }

    nonisolated func cefBrowserTitleDidChange(_ title: String) {
        MainActor.assumeIsolated {
            pageTitle = title
            delegate?.engine(self, titleDidChange: title)
        }
    }

    nonisolated func cefBrowserNavigationStateDidChange(_ canGoBack: Bool, canGoForward: Bool) {
        MainActor.assumeIsolated {
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            delegate?.engine(self, navigationStateDidChange: canGoBack, canGoForward: canGoForward)
        }
    }

    nonisolated func cefBrowserDidRequestPopup(_ url: String) {
        MainActor.assumeIsolated {
            guard let parsed = URL(string: url) else { return }
            delegate?.engine(self, didRequestPopup: parsed)
        }
    }
}
#endif
