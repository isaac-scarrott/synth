import CoreGraphics
import Foundation

// The installed simulator fleet: what exists, and boot/shutdown. `simctl` is the whole
// implementation here on purpose (ADR-0015) — it is supported, stable, and answers every
// question this layer asks, including the model identifier and the screen geometry the drawn
// hardware frame needs. CoreSimulator stays reserved for the two things `simctl` has no verb
// for at any version: reading the framebuffer and injecting touches.

// MARK: - Values

/// A device's lifecycle state. The numeric values are CoreSimulator's `SimDeviceState`, so the
/// same enum reads a `simctl` string and a `-[SimDevice state]` integer.
enum SimulatorDeviceState: UInt, Sendable {
    case creating = 0
    case shutdown = 1
    case booting = 2
    case booted = 3
    case shuttingDown = 4

    init?(simctlName: String) {
        switch simctlName {
        case "Creating": self = .creating
        case "Shutdown": self = .shutdown
        case "Booting": self = .booting
        case "Booted": self = .booted
        case "Shutting Down": self = .shuttingDown
        default: return nil
        }
    }

    var isBooted: Bool { self == .booted }
}

/// One installed device. `udid` is the identity — a session persists that and never a model name,
/// so renaming a device or installing a second one of the same model cannot move a session.
struct SimulatorDeviceInfo: Identifiable, Hashable, Sendable {
    var udid: String
    /// "iPhone 16" — the user-visible device name, which is editable and not an identity.
    var name: String
    /// "iOS 18.6".
    var runtimeName: String
    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-6".
    var runtimeIdentifier: String
    /// "com.apple.CoreSimulator.SimDeviceType.iPhone-16".
    var deviceTypeIdentifier: String
    /// "iPhone17,3" — the real hardware this device impersonates, which is what the drawn
    /// hardware frame is resolved from rather than parsing the session's name.
    var modelIdentifier: String?
    /// The framebuffer's pixel size, from the device type's profile, available before boot.
    var screenPixelSize: CGSize?
    /// The backing-scale factor, so the pane can lay the stream out at true viewport size.
    var screenScale: CGFloat?
    var state: SimulatorDeviceState
    /// False when the runtime the device needs is not installed; such a device cannot be booted.
    var isAvailable: Bool

    var id: String { udid }
    var isBooted: Bool { state.isBooted }
    /// The viewport size in points, which is what a layout wants.
    var screenPointSize: CGSize? {
        guard let screenPixelSize, let screenScale, screenScale > 0 else { return nil }
        return CGSize(width: screenPixelSize.width / screenScale,
                      height: screenPixelSize.height / screenScale)
    }
}

/// An installed runtime, for grouping the picker.
struct SimulatorRuntimeInfo: Identifiable, Hashable, Sendable {
    var identifier: String
    var name: String
    var version: String
    var platform: String
    var isAvailable: Bool

    var id: String { identifier }
}

/// What asking a device to boot actually did. The distinction is the whole of Synth's claim
/// bookkeeping: `.booted` means Synth turned this device on and therefore owes it a shutdown, and
/// `.alreadyRunning` means Synth joined a device somebody else started — the user, another Synth, a
/// terminal — and must never shut that one down (ADR-0015: a device is never owned).
enum SimulatorBootOutcome: Sendable {
    case alreadyRunning
    case booted
}

enum SimulatorCatalogFailure: Error, CustomStringConvertible {
    case malformedListing(String)
    case bootTimedOut(udid: String, after: TimeInterval, lastState: SimulatorDeviceState?)
    case unavailableRuntime(udid: String)

    var description: String {
        switch self {
        case let .malformedListing(detail):
            return "Could not read simctl's device listing: \(detail)"
        case let .bootTimedOut(udid, after, lastState):
            let state = lastState.map { "\($0)" } ?? "unknown"
            return "Device \(udid) was still \(state) after \(Int(after))s."
        case let .unavailableRuntime(udid):
            return "Device \(udid)'s runtime is not installed, so it cannot be booted."
        }
    }
}

// MARK: - Catalog

enum SimulatorDeviceCatalog {

    /// Whether simulator sessions are possible at all: they need a full Xcode, located through
    /// `xcode-select` / `DEVELOPER_DIR`. A surface that cannot offer this has to say so plainly.
    static var isXcodeAvailable: Bool {
        guard let developer = SimulatorPrivateRuntime.developerDirectory else { return false }
        // `simctl` and nothing else. Every path through this feature needs it — listing, booting,
        // launching, and the degraded screenshot fallback — so its absence means there is nothing to
        // offer, and its presence means there is at least the degraded mode. The private frameworks
        // are deliberately NOT part of this test: missing those is a degradation the source reports
        // per capability, not a reason to hide the feature.
        //
        // This used to accept any one of three paths, which made the Command Line Tools look like a
        // full Xcode: `CommandLineTools/Library/PrivateFrameworks` exists, so the feature advertised
        // itself as working and then failed with `xcrun: error: unable to find utility "simctl"`.
        // Claiming to work and then not is worse than saying plainly that it cannot.
        return FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/simctl")
    }

    // MARK: Enumeration

    /// Every installed device, newest runtime first and alphabetical within a runtime — the order
    /// a picker wants. Unavailable devices are included but flagged, because hiding them makes a
    /// missing runtime look like a missing device.
    static func devices() throws -> [SimulatorDeviceInfo] {
        let listing = try simctlJSON(["list", "devices", "--json"])
        guard let byRuntime = listing["devices"] as? [String: [[String: Any]]] else {
            throw SimulatorCatalogFailure.malformedListing("no 'devices' object")
        }
        let runtimeIndex = Dictionary(
            uniqueKeysWithValues: (try? runtimes())?.map { ($0.identifier, $0) } ?? [])
        let profiles = deviceTypeProfiles()

        var devices: [SimulatorDeviceInfo] = []
        for (runtimeIdentifier, entries) in byRuntime {
            for entry in entries {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String
                else { continue }
                let typeIdentifier = entry["deviceTypeIdentifier"] as? String ?? ""
                let profile = profiles[typeIdentifier]
                devices.append(SimulatorDeviceInfo(
                    udid: udid,
                    name: name,
                    runtimeName: runtimeIndex[runtimeIdentifier]?.name
                        ?? runtimeDisplayName(fromIdentifier: runtimeIdentifier),
                    runtimeIdentifier: runtimeIdentifier,
                    deviceTypeIdentifier: typeIdentifier,
                    modelIdentifier: profile?.modelIdentifier,
                    screenPixelSize: profile?.pixelSize,
                    screenScale: profile?.scale,
                    state: SimulatorDeviceState(simctlName: entry["state"] as? String ?? "")
                        ?? .shutdown,
                    isAvailable: entry["isAvailable"] as? Bool ?? false))
            }
        }
        return devices.sorted {
            $0.runtimeIdentifier == $1.runtimeIdentifier
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.runtimeIdentifier > $1.runtimeIdentifier
        }
    }

    static func device(udid: String) throws -> SimulatorDeviceInfo {
        let wanted = udid.lowercased()
        guard let device = try devices().first(where: { $0.udid.lowercased() == wanted }) else {
            throw SimulatorRuntimeFailure.deviceNotFound(udid: udid)
        }
        return device
    }

    static func runtimes() throws -> [SimulatorRuntimeInfo] {
        let listing = try simctlJSON(["list", "runtimes", "--json"])
        guard let entries = listing["runtimes"] as? [[String: Any]] else {
            throw SimulatorCatalogFailure.malformedListing("no 'runtimes' array")
        }
        return entries.compactMap { entry in
            guard let identifier = entry["identifier"] as? String else { return nil }
            return SimulatorRuntimeInfo(
                identifier: identifier,
                name: entry["name"] as? String ?? identifier,
                version: entry["version"] as? String ?? "",
                platform: entry["platform"] as? String ?? "",
                isAvailable: entry["isAvailable"] as? Bool ?? false)
        }
    }

    // MARK: Lifecycle

    /// Boots the device if it is shut down, and does nothing if it is already up — devices are
    /// machine-global state, so a session joins a running device rather than fighting it.
    /// `simctl boot` returns as soon as the boot is under way; `waitUntilBooted` is the wait.
    ///
    /// The return value is load-bearing and not a convenience: it is the only honest answer to
    /// "did Synth start this device?", and the only thing that may authorise shutting it down
    /// later. A device that was already booted comes back `.alreadyRunning` — including when the
    /// race below fires, because losing a boot race means somebody else started it.
    @discardableResult
    static func boot(udid: String) throws -> SimulatorBootOutcome {
        let device = try device(udid: udid)
        guard device.isAvailable else { throw SimulatorCatalogFailure.unavailableRuntime(udid: udid) }
        switch device.state {
        case .booted, .booting: return .alreadyRunning
        case .creating, .shutdown, .shuttingDown:
            // iOS 26.5 and later cache the guest's accessibility preferences at boot, so the keys
            // that let an out-of-process client read the accessibility tree have to be in place
            // before `simctl boot` — this is the only moment writing them does anything.
            SimulatorAccessibility.prepareForBoot(
                udid: udid, runtimeVersion: runtimeVersion(of: device))
            do {
                try SimulatorShell.simctl(["boot", udid], timeout: 120)
            } catch let failure as SimulatorShell.Failure {
                // A concurrent boot of the same device is success, not failure: the outcome the
                // caller asked for is what happened. It is somebody else's boot, though, so this
                // is `.alreadyRunning` — Synth did not start this device and may not stop it.
                guard case let .exited(_, _, message) = failure,
                      message.lowercased().contains("current state: booted")
                        || message.lowercased().contains("unable to boot device in current state: booted")
                else { throw failure }
                return .alreadyRunning
            }
            return .booted
        }
    }

    /// Blocks until the device reports Booted. `simctl bootstatus` is the supported wait and also
    /// waits for the system apps to come up, which is what "the pane can show something" means.
    static func waitUntilBooted(udid: String, timeout: TimeInterval = 120) throws {
        let deadline = Date().addingTimeInterval(timeout)
        // -b exits once the boot completes rather than streaming forever.
        _ = try? SimulatorShell.run(
            "/usr/bin/xcrun", ["simctl", "bootstatus", udid, "-b"], timeout: timeout)
        var lastState: SimulatorDeviceState?
        while Date() < deadline {
            let state = (try? device(udid: udid))?.state
            lastState = state
            if state == .booted { return }
            usleep(200_000)
        }
        throw SimulatorCatalogFailure.bootTimedOut(udid: udid, after: timeout, lastState: lastState)
    }

    /// Shuts the device down. Only ever for a device Synth booted, and only once the last session
    /// holding it has let go — `SimulatorClaims` is what decides both.
    ///
    /// Bounded, because the quit path calls this synchronously: an unbounded `waitUntilExit()` on a
    /// wedged `simctl` would hang the app between the user's ⌘Q and the process actually leaving.
    static func shutdown(udid: String) throws {
        do {
            try SimulatorShell.simctl(["shutdown", udid], timeout: 30)
        } catch let failure as SimulatorShell.Failure {
            guard case let .exited(_, _, message) = failure,
                  message.lowercased().contains("current state: shutdown")
            else { throw failure }
        }
    }

    // MARK: App plumbing

    /// `simctl` app verbs. These are genuinely `simctl` work, so the app shells out and the agent
    /// and the user are always talking about the same device (ADR-0015).
    ///
    /// Every one is bounded. They are reached from a control connection's own thread, and an
    /// unbounded `waitUntilExit()` parks that thread and its fd for the life of the app — a wedged
    /// `simctl` against a half-dead device is not hypothetical, which is exactly why `boot`,
    /// `bootstatus` and `io screenshot` were already bounded. `install` gets the longest budget
    /// because copying a large app bundle onto a device legitimately takes a while.
    static func install(udid: String, appPath: String) throws {
        try SimulatorShell.simctl(["install", udid, appPath], timeout: 300)
    }

    @discardableResult
    static func launch(udid: String, bundleIdentifier: String, arguments: [String] = []) throws -> String {
        try SimulatorShell.simctl(
            ["launch", udid, bundleIdentifier] + arguments, timeout: 60).trimmedOutput
    }

    static func terminate(udid: String, bundleIdentifier: String) throws {
        try SimulatorShell.simctl(["terminate", udid, bundleIdentifier], timeout: 30)
    }

    static func open(udid: String, url: String) throws {
        try SimulatorShell.simctl(["openurl", udid, url], timeout: 30)
    }

    /// A PNG of the device's screen. The degraded screen source polls this; it is also the
    /// honest answer to "give me a screenshot" when the framebuffer path is unavailable.
    static func screenshotPNG(udid: String) throws -> Data {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("synth-simulator-\(udid)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }
        try SimulatorShell.simctl(["io", udid, "screenshot", path.path], timeout: 20)
        return try Data(contentsOf: path)
    }

    // MARK: Device type profiles

    private struct DeviceTypeProfile {
        var modelIdentifier: String?
        var pixelSize: CGSize?
        var scale: CGFloat?
    }

    /// Model identifier and screen geometry per device type. `simctl list devicetypes` carries the
    /// model identifier; the scale and pixel size come from the device type bundle's own
    /// `profile.plist`, which is a plain file read and available before the device boots.
    private static func deviceTypeProfiles() -> [String: DeviceTypeProfile] {
        guard let listing = try? simctlJSON(["list", "devicetypes", "--json"]),
              let entries = listing["devicetypes"] as? [[String: Any]] else { return [:] }
        var profiles: [String: DeviceTypeProfile] = [:]
        for entry in entries {
            guard let identifier = entry["identifier"] as? String else { continue }
            var profile = DeviceTypeProfile(
                modelIdentifier: entry["modelIdentifier"] as? String, pixelSize: nil, scale: nil)
            if let bundlePath = entry["bundlePath"] as? String {
                let plistPath = bundlePath + "/Contents/Resources/profile.plist"
                if let data = FileManager.default.contents(atPath: plistPath),
                   let plist = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any] {
                    if let width = plist["mainScreenWidth"] as? NSNumber,
                       let height = plist["mainScreenHeight"] as? NSNumber {
                        profile.pixelSize = CGSize(
                            width: width.doubleValue, height: height.doubleValue)
                    }
                    if let scale = plist["mainScreenScale"] as? NSNumber {
                        profile.scale = CGFloat(scale.doubleValue)
                    }
                    if profile.modelIdentifier == nil {
                        profile.modelIdentifier = plist["modelIdentifier"] as? String
                    }
                }
            }
            profiles[identifier] = profile
        }
        return profiles
    }

    // MARK: Helpers

    private static func simctlJSON(_ arguments: [String]) throws -> [String: Any] {
        let output = try SimulatorShell.simctl(arguments, timeout: 60)
        guard let data = output.standardOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SimulatorCatalogFailure.malformedListing(
                "simctl \(arguments.joined(separator: " ")) did not return JSON")
        }
        return object
    }

    /// "18.4" out of "iOS 18.4" (or out of the runtime identifier when the name is odd). Only
    /// version-gated behaviour needs this, so it stays here rather than widening
    /// `SimulatorDeviceInfo` with a field nothing else reads.
    private static func runtimeVersion(of device: SimulatorDeviceInfo) -> String {
        let fromName = device.runtimeName.split(separator: " ").last.map(String.init) ?? ""
        if fromName.first?.isNumber == true { return fromName }
        let fromIdentifier = runtimeDisplayName(fromIdentifier: device.runtimeIdentifier)
        return fromIdentifier.split(separator: " ").last.map(String.init) ?? fromIdentifier
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-6" → "iOS 18.6", for the case where the runtime
    /// listing does not mention a runtime a device claims (an orphaned device).
    private static func runtimeDisplayName(fromIdentifier identifier: String) -> String {
        guard let tail = identifier.split(separator: ".").last else { return identifier }
        let parts = tail.split(separator: "-")
        guard parts.count > 1 else { return String(tail) }
        return parts[0] + " " + parts.dropFirst().joined(separator: ".")
    }
}

// MARK: - Claims

/// Which devices **this** Synth booted, and why one would not boot. The record that decides whether
/// Synth may ever shut a device down.
///
/// Two properties are the point, and the first version of this had neither.
///
/// **It records a boot, not an intention.** A claim is written only after `simctl boot` moved a
/// device from shutdown to booted. `boot` no-ops on a device that is already up, so recording at the
/// start of a claim marked the user's own device as Synth's — and closing the row, quitting, or the
/// next launch's sweep then shut it down, killing their app state and any attached Xcode debug
/// session with no warning. A device is never owned (ADR-0015); this is only a note of who turned
/// the light on.
///
/// **It is per instance.** It used to be one `UserDefaults` key shared by every Synth on the
/// machine, so launching a second instance swept the first one's devices out from under it. Each
/// instance writes `simulator-claims/<pid>.json` and the launch sweep only reads files whose pid is
/// gone — the same shape, and the same pid-reuse caveat, as `InstanceRegistry`'s advertisements.
enum SimulatorClaims {
    private static let lock = NSLock()
    /// Devices this process booted and therefore owes a shutdown.
    private static var booted: Set<String> = []
    /// Devices this process has *asked* for, booted by us or not. Never a licence to shut one down.
    /// It exists so the launch sweep does not turn off a device a restored session of this instance
    /// is in the middle of attaching to.
    private static var interest: Set<String> = []
    private static var bootFailures: [String: String] = [:]

    private static var directory: URL { AppSupport.dir("simulator-claims") }

    /// UDIDs reach here from `simctl` listings, from persisted sessions and from tool arguments, so
    /// membership is case-insensitive. What is handed to `simctl` is always a caller's own string —
    /// never one this canonicalisation invented.
    private static func key(_ udid: String) -> String { udid.uppercased() }

    // MARK: This instance

    static func noteInterest(in udid: String) {
        lock.lock(); interest.insert(key(udid)); lock.unlock()
    }

    static func dropInterest(in udid: String) {
        lock.lock(); interest.remove(key(udid)); lock.unlock()
    }

    /// Whether this process has asked for the device, already keyed. A function of its own so the
    /// sweep's `async` body never takes the lock itself — `NSLock` is unavailable from an async
    /// context under Swift 6.
    private static func wanted(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return interest.contains(key)
    }

    /// Synth booted this device. Called only on a shutdown → booted transition.
    ///
    /// The file write happens under the lock, not after it: two devices claimed and released
    /// concurrently would otherwise race to write their own snapshot, and the loser's write would
    /// resurrect a claim that had been given up or drop one that had just been made.
    static func record(_ udid: String) {
        lock.lock(); defer { lock.unlock() }
        guard booted.insert(key(udid)).inserted else { return }
        persist(booted)
    }

    /// Forgets a claim, answering whether there was one — i.e. whether Synth booted this device and
    /// may therefore shut it down. Every release route asks this before touching a device.
    @discardableResult
    static func forget(_ udid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard booted.remove(key(udid)) != nil else { return false }
        persist(booted)
        return true
    }

    static func synthBooted(_ udid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return booted.contains(key(udid))
    }

    // MARK: Boot failures

    static func recordBootFailure(_ detail: String, for udid: String) {
        lock.lock(); bootFailures[key(udid)] = detail; lock.unlock()
    }

    static func clearBootFailure(for udid: String) {
        lock.lock(); bootFailures[key(udid)] = nil; lock.unlock()
    }

    /// Why the last claim on this device did not reach a booted device, if it did not. Read by the
    /// screen source when the live path finds no display and by `simulator_list`, because the honest
    /// answer to "why is there no picture" is usually "because `simctl boot` said this".
    static func bootFailure(for udid: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return bootFailures[key(udid)]
    }

    // MARK: Orphan reconciliation
    //
    // A quit-time handler cannot be the only thing that releases a device, because plenty of exits
    // never reach one: SIGKILL, a crash, and — measured — a bare SIGTERM when no browser session has
    // ever initialised CEF, since the signal source that routes signals through `NSApp.terminate`
    // is installed by the CEF supervisor. In every one of those cases the device stays booted at
    // well over a gigabyte with nothing in any UI to explain it.
    //
    // So a boot is recorded when it happens and reconciled on the next launch, the way the browser
    // sweeps profile directories orphaned by a dead instance. Only a *dead* instance's file is read:
    // a live sibling's devices are its own business, and a device nobody recorded was never Synth's.

    /// Shut down devices a previous run of Synth booted and never released. Off the main actor: each
    /// shutdown is a `simctl` spawn.
    static func reconcileOrphanedInstances() {
        let orphans = orphanedFiles()
        guard !orphans.isEmpty else { return }
        let abandoned = Set(orphans.flatMap(\.udids))
        Task.detached(priority: .utility) {
            let bootedNow = Dictionary(
                ((try? SimulatorDeviceCatalog.devices()) ?? []).filter(\.isBooted)
                    .map { (key($0.udid), $0.udid) },
                uniquingKeysWith: { first, _ in first })
            for claimed in abandoned {
                guard let udid = bootedNow[claimed] else { continue }
                // A restored session of *this* instance may already be attaching to it. Shutting it
                // down here would be the same fault this whole file exists to fix, one instance later.
                guard !wanted(claimed) else { continue }
                NSLog("Synth: releasing simulator %@ left booted by a previous run", udid)
                try? SimulatorDeviceCatalog.shutdown(udid: udid)
            }
            for orphan in orphans { try? FileManager.default.removeItem(at: orphan.file) }
        }
    }

    // MARK: Storage

    private static func file(pid: pid_t) -> URL {
        directory.appendingPathComponent("\(pid).json")
    }

    private static func persist(_ udids: Set<String>) {
        let url = file(pid: getpid())
        guard !udids.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: Array(udids).sorted()) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func orphanedFiles() -> [(file: URL, udids: [String])] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            ?? []
        var orphans: [(file: URL, udids: [String])] = []
        for entry in entries where entry.pathExtension == "json" {
            guard let pid = pid_t(entry.deletingPathExtension().lastPathComponent),
                  pid != getpid() else { continue }
            // Alive, or alive and owned by another user: either way not ours to reconcile.
            guard kill(pid, 0) != 0, errno == ESRCH else { continue }
            let udids = (try? Data(contentsOf: entry))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
            orphans.append((entry, udids.map(key)))
        }
        return orphans
    }
}

// MARK: - Fleet seam

/// The engine's answer to `SimulatorFleet` (Store.swift): the tree asks what devices exist and
/// claims/releases one, and the catalog does it with `simctl`. Boot and shutdown run off the main
/// actor — a boot takes seconds and must never block a keystroke.
///
/// The device listing is cached and refreshed in the background, because `devices()` shells out
/// three times and the picker reads it synchronously while drawing.
@MainActor final class SimulatorCatalogFleet: SimulatorFleet {
    private var cache: [SimulatorDevice] = []
    private var index: [String: SimulatorDevice] = [:]
    private var isRefreshing = false

    init() { refresh() }

    func devices() -> [SimulatorDevice] {
        refresh()
        return cache
    }

    /// A cache read, never a `simctl` call. `refresh()` is asked for afterwards so the answer is
    /// fresh *next* time; returning a slightly stale device is right, because the alternative is
    /// three subprocess spawns on the main actor while the user is typing.
    func device(udid: String) -> SimulatorDevice? {
        defer { refresh() }
        return index[udid.lowercased()]
    }

    func refreshSoon() { refresh() }

    /// Joins the device, booting it if it is shut down. A claim is recorded **only** when this boot
    /// is the one that started the device: `boot` no-ops on a device that is already up, so
    /// recording before the attempt made Synth believe it owned the device the user was already
    /// looking at — and closing the row, or quitting, then shut that device down under them, taking
    /// their app state and any attached Xcode debug session with it.
    ///
    /// A boot that does not happen is recorded too, and reported: the pane retries an attach for
    /// ninety seconds, and "no screen" with no reason is the worst version of that.
    func claim(_ udid: String) {
        SimulatorClaims.noteInterest(in: udid)
        Task.detached(priority: .userInitiated) {
            do {
                if try SimulatorDeviceCatalog.boot(udid: udid) == .booted {
                    // Recorded here and not a line earlier: this is the shutdown → booted
                    // transition, and it is the only thing that licenses a later shutdown.
                    SimulatorClaims.record(udid)
                }
                try SimulatorDeviceCatalog.waitUntilBooted(udid: udid)
                SimulatorClaims.clearBootFailure(for: udid)
            } catch {
                SimulatorClaims.recordBootFailure(String(describing: error), for: udid)
                NSLog("Synth: simulator %@ would not boot: %@", udid, String(describing: error))
            }
            // Refresh so the picker shows the device as booted. `self`, not `Simulators.fleet`:
            // the cache being updated must be the one this claim came through.
            await MainActor.run { self.refresh() }
        }
    }

    /// Lets go of the device, and shuts it down only if Synth is the one that booted it. A device
    /// somebody else started outlives every session Synth had on it, by design (ADR-0015).
    func release(_ udid: String) {
        SimulatorClaims.dropInterest(in: udid)
        guard SimulatorClaims.forget(udid) else { return }
        Task.detached(priority: .utility) {
            try? SimulatorDeviceCatalog.shutdown(udid: udid)
        }
    }

    /// The quit path's release: the same rule, run synchronously because `willTerminate` shares a
    /// stack with the imminent `exit()` and a detached task does not outlive the process.
    static func releaseSynchronously(_ udid: String) {
        SimulatorClaims.dropInterest(in: udid)
        guard SimulatorClaims.forget(udid) else { return }
        try? SimulatorDeviceCatalog.shutdown(udid: udid)
    }

    static func reconcileOrphanedClaims() { SimulatorClaims.reconcileOrphanedInstances() }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .userInitiated) {
            let listed = (try? SimulatorDeviceCatalog.devices()) ?? []
            let devices = listed.filter(\.isAvailable).map {
                SimulatorDevice(
                    udid: $0.udid, name: $0.name, runtime: $0.runtimeName, isBooted: $0.isBooted,
                    modelIdentifier: $0.modelIdentifier, screenPixelSize: $0.screenPixelSize,
                    screenScale: $0.screenScale)
            }
            await MainActor.run { [devices] in
                self.cache = devices
                self.index = Dictionary(devices.map { ($0.udid.lowercased(), $0) },
                                        uniquingKeysWith: { first, _ in first })
                self.isRefreshing = false
            }
        }
    }
}
