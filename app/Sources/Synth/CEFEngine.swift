#if canImport(CEFShim)
import AppKit
import CEFShim

/// Owns the process-wide CEF runtime and session hygiene (ADR-0011): per-instance
/// root cache dir, per-session profile dirs deleted on close, one CDP port per app
/// instance, and stale-profile sweeping — the spike's singleton trap means leftover
/// dirs from a crashed instance must never be reused.
@MainActor
final class BrowserProcessSupervisor {
    static let shared = BrowserProcessSupervisor()

    private(set) var cdpPort: UInt16 = 0
    private var initialized = false
    private var instanceRoot: URL?
    private var terminationObserver: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    /// Roots live per app instance (instance-<pid>) because Chromium's process
    /// singleton is per cache root: two Synth instances sharing one root would make
    /// the second CefInitialize defer to the first.
    private static let profilesRoot = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Synth/BrowserProfiles", isDirectory: true)

    private init() {}

    func ensureInitialized() throws {
        guard !initialized else { return }

        let frameworkPath = Bundle.main.bundlePath
            + "/Contents/Frameworks/Chromium Embedded Framework.framework"
        guard FileManager.default.fileExists(atPath: frameworkPath) else {
            throw BrowserEngineFactory.Unavailable(reason:
                "CEF framework missing from the app bundle — launch a bundle assembled by app/dev.sh or app/build-app.sh")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: Self.profilesRoot, withIntermediateDirectories: true)
        sweepDeadInstances()

        let root = Self.profilesRoot.appendingPathComponent(
            "instance-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        guard let port = Self.allocateCDPPort(range: 9300...9399) else {
            try? fm.removeItem(at: root)
            throw BrowserEngineFactory.Unavailable(reason: "no free CDP port in 9300-9399")
        }

        let automation = ProcessInfo.processInfo.environment["SYNTH_AUTOMATION"] == "1"
        guard CEFShimRuntime.initialize(
            withRootCachePath: root.path, cdpPort: port, automation: automation) else {
            try? fm.removeItem(at: root)
            throw BrowserEngineFactory.Unavailable(reason:
                "CefInitialize failed — see cef.log under \(root.path)")
        }

        instanceRoot = root
        cdpPort = port
        initialized = true

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
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Full teardown: force-close every browser, CefShutdown, delete this instance's
    /// cache root. CEF cannot re-initialize afterwards; app-exit (or check-mode) only.
    func shutdownNow() {
        guard initialized else { return }
        CEFShimRuntime.shutdown()
        initialized = false
        reapHelpers()
        if let root = instanceRoot {
            try? FileManager.default.removeItem(at: root)
            instanceRoot = nil
        }
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

    func makeProfileDirectory() throws -> URL {
        guard let root = instanceRoot else {
            throw BrowserEngineFactory.Unavailable(reason: "browser runtime not initialized")
        }
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func removeProfileDirectory(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Deletes instance roots whose owning pid is gone (crashed / killed instances).
    private func sweepDeadInstances() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: Self.profilesRoot, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix("instance-") {
            guard let pid = Int32(entry.lastPathComponent.dropFirst("instance-".count))
            else { continue }
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

/// The production BrowserEngine: CEF 144 behind the shim, one page per engine,
/// isolated profile dir deleted when the browser is gone.
@MainActor
final class CEFEngine: NSObject, BrowserEngine {
    weak var delegate: BrowserEngineDelegate?

    private let shim: CEFShimBrowser
    private let profileDir: URL
    let cdpPort: UInt16

    private(set) var currentURL: URL?
    private(set) var pageTitle: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    var view: NSView { shim.view }

    init(initialURL: URL) throws {
        let supervisor = BrowserProcessSupervisor.shared
        try supervisor.ensureInitialized()
        let profileDir = try supervisor.makeProfileDirectory()
        guard let shim = CEFShimBrowser(
            url: initialURL.absoluteString,
            cachePath: profileDir.path,
            frame: NSRect(x: 0, y: 0, width: 900, height: 600)
        ) else {
            supervisor.removeProfileDirectory(profileDir)
            throw BrowserEngineFactory.Unavailable(reason: "CEF refused to create a browser")
        }
        self.shim = shim
        self.profileDir = profileDir
        self.cdpPort = supervisor.cdpPort
        self.currentURL = initialURL
        super.init()
        shim.delegate = self
    }

    func navigate(to url: URL) { shim.navigate(url.absoluteString) }
    func goBack() { shim.goBack() }
    func goForward() { shim.goForward() }
    func reload() { shim.reload() }
    func showDevTools() { shim.showDevTools() }
    func closeDevTools() { shim.closeDevTools() }
    var devToolsOpen: Bool { shim.hasDevTools() }

    func shutdown() {
        shim.close()   // async; profile dir is deleted in cefBrowserDidClose
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

    nonisolated func cefBrowserDidClose() {
        MainActor.assumeIsolated {
            BrowserProcessSupervisor.shared.removeProfileDirectory(profileDir)
        }
    }
}
#endif
