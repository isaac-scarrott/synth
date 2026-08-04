import CoreGraphics
import Foundation
import ObjectiveC

// The one place Synth reaches into Apple's private simulator frameworks (ADR-0015). Everything
// here is resolved by name at runtime — dlopen for the bundles, objc_lookUpClass for the classes,
// dlsym for the C builders, respondsToSelector: before every message — and nothing is linked.
// Xcode 27 alone moved SimulatorKit's bundle, migrated the display protocols to CoreSimDeviceIO
// and renamed callbacks; each of those survives a name lookup and would be fatal to a link.
//
// The runtime-only classes are messaged through `@objc` "Messaging" protocols plus
// `unsafeBitCast`, which compiles to a plain objc_msgSend with no link-time class reference.

/// Every number that crosses the private-API boundary — or arrives from an agent — converts through
/// here. `Int(someDouble)` traps on NaN, on infinity, and on anything outside `Int`'s range, and a
/// private property whose real type is not the one we messaged it as returns whatever was in the
/// register: that is exactly how `mainScreenScale` produced a NaN that reached `Int(_:)`. A trap in
/// this process is not a degraded simulator pane, it is the loss of the user's terminals and agent
/// sessions, so nothing derived from a private read or a tool argument is converted directly.
func safeInt(_ value: Double, fallback: Int = 0) -> Int {
    Int(exactly: value.rounded()) ?? fallback
}

func safeInt(_ value: CGFloat, fallback: Int = 0) -> Int {
    safeInt(Double(value), fallback: fallback)
}

/// A finite, in-range duration in seconds. Guards the same trap from the other direction: a negative
/// duration converts to an unsigned `useconds_t` by trapping, and a huge one turns a gesture into a
/// multi-minute blocking loop on the control-socket thread.
func safeDuration(_ value: Double, default fallback: Double, range: ClosedRange<Double>) -> Double {
    guard value.isFinite else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
}
// Declaring the real class as a Swift type would emit `_OBJC_CLASS_$_…` pinned to one framework.

// MARK: - Failures

/// Why a private-runtime lookup failed. Every case carries enough detail to put in front of a
/// user, because a simulator session that cannot resolve the framebuffer path has to say why it
/// is degraded rather than silently showing nothing.
enum SimulatorRuntimeFailure: Error, CustomStringConvertible {
    case noDeveloperDirectory
    case frameworkUnavailable(name: String, candidates: [String], dlerror: String?)
    case classUnavailable(String)
    case selectorUnavailable(className: String, selector: String)
    /// `respondsToSelector:` proves a selector exists. It proves nothing about what the selector
    /// returns, so every object-returning private read is optional and lands here when it is nil.
    case selectorReturnedNil(className: String, selector: String)
    case displaySurfaceUnusable(className: String)
    case symbolUnavailable(name: String, framework: String)
    case serviceContextUnavailable(String)
    case deviceSetUnavailable(String)
    case deviceNotFound(udid: String)
    case deviceNotBooted(udid: String)
    case noDisplayPort(portsInspected: Int, inertPortsSkipped: Int)
    case hidClientCreationFailed(String)

    var description: String {
        switch self {
        case .noDeveloperDirectory:
            return "No Xcode developer directory: set DEVELOPER_DIR or run xcode-select --switch."
        case let .frameworkUnavailable(name, candidates, dlerror):
            return "Could not load \(name) from any of \(candidates.joined(separator: ", "))"
                + (dlerror.map { ": \($0)" } ?? "")
        case let .classUnavailable(name):
            return "Class \(name) is not present in this Xcode's runtime."
        case let .selectorUnavailable(className, selector):
            return "\(className) does not respond to -\(selector) in this Xcode."
        case let .selectorReturnedNil(className, selector):
            return "\(className) answered -\(selector) with nil, which is not a shape Synth knows "
                + "how to read in this Xcode."
        case let .displaySurfaceUnusable(className):
            return "The display port's framebuffer is a \(className), not an IOSurface, so this "
                + "Xcode's framebuffer cannot be read as one."
        case let .symbolUnavailable(name, framework):
            return "Symbol \(name) is not exported by \(framework) in this Xcode."
        case let .serviceContextUnavailable(detail):
            return "SimServiceContext refused a shared context: \(detail)"
        case let .deviceSetUnavailable(detail):
            return "No default device set: \(detail)"
        case let .deviceNotFound(udid):
            return "No simulator device with UDID \(udid) in the default device set."
        case let .deviceNotBooted(udid):
            return "Device \(udid) is not booted, so it publishes no display."
        case let .noDisplayPort(inspected, inert):
            return "No live display port among \(inspected) IO ports "
                + "(\(inert) inert framebuffer port(s) skipped: 0×0 size or nil surface)."
        case let .hidClientCreationFailed(detail):
            return "SimDeviceLegacyHIDClient could not attach to the device: \(detail)"
        }
    }
}

// MARK: - Runtime-only messaging surfaces

/// `+[SimServiceContext sharedServiceContextForDeveloperDir:error:]`. Declared as an *instance*
/// method and messaged against the class object: a class is an object, so instance dispatch on it
/// resolves through the metaclass and finds the class method — which keeps this a name lookup.
@objc private protocol SimServiceContextClassMessaging {
    @objc(sharedServiceContextForDeveloperDir:error:)
    func sharedServiceContext(forDeveloperDir dir: String, error: NSErrorPointer) -> AnyObject?
}

@objc private protocol SimServiceContextMessaging {
    @objc(defaultDeviceSetWithError:)
    func defaultDeviceSet(error: NSErrorPointer) -> AnyObject?
}

// Every object-returning member below is optional, and that is the whole point: `respondsToSelector:`
// establishes that a selector exists, never that it answers with something. A nil arriving in a
// non-optional Swift reference traps on the implicit unwrap, and a trap here is not a degraded
// simulator pane — it is the loss of the user's terminals and agent sessions. The only non-optional
// members are the ones whose return rides in a register (`state`), where there is no nil to have.

@objc private protocol SimDeviceSetMessaging {
    @objc var devices: [AnyObject]? { get }
}

@objc protocol SimDeviceMessaging {
    @objc var name: String? { get }
    /// CoreSimulator spells this `UDID`, and ObjC selectors are case-sensitive: without the
    /// explicit name Swift synthesises `udid`, `respondsToSelector:` is false for every device,
    /// and lookup fails with "no device with that UDID" against a device that is right there.
    @objc(UDID) var udid: NSUUID? { get }
    /// CoreSimulator's SimDeviceState. 3 is Booted; a non-booted device publishes no display.
    @objc var state: UInt { get }
    @objc var io: AnyObject? { get }
}

@objc protocol SimDeviceIOMessaging {
    @objc var ioPorts: [AnyObject]? { get }
}

@objc protocol SimDeviceIOPortMessaging {
    @objc var descriptor: AnyObject? { get }
}

// MARK: - Runtime

enum SimulatorPrivateRuntime {

    /// Booted, per CoreSimulator's SimDeviceState.
    static let bootedState: UInt = 3

    // MARK: Developer directory

    /// The active Xcode's Developer directory. `DEVELOPER_DIR` wins (that is the contract every
    /// Apple tool honours), then `xcode-select -p`. Never a hardcoded /Applications path.
    static let developerDirectory: String? = {
        if let fromEnvironment = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           !fromEnvironment.isEmpty,
           FileManager.default.fileExists(atPath: fromEnvironment) {
            return fromEnvironment
        }
        guard let output = try? SimulatorShell.run("/usr/bin/xcode-select", ["-p"]),
              output.status == 0 else { return nil }
        let path = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty || !FileManager.default.fileExists(atPath: path) ? nil : path
    }()

    // MARK: Framework loading

    /// CoreSimulator ships outside Xcode (it is part of the OS-level developer install), but a
    /// second copy has lived inside the Developer dir before now, so both are tried.
    private static func coreSimulatorCandidates() -> [String] {
        var candidates = ["/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"]
        if let dev = developerDirectory {
            candidates.append(dev + "/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator")
        }
        return candidates
    }

    /// SimulatorKit lives in the Developer dir's PrivateFrameworks up to Xcode 16 and moves to
    /// Xcode.app/Contents/SharedFrameworks in Xcode 27, so both are tried in that order.
    private static func simulatorKitCandidates() -> [String] {
        guard let dev = developerDirectory else { return [] }
        return [
            dev + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            dev + "/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            dev + "/Library/Frameworks/SimulatorKit.framework/SimulatorKit",
        ]
    }

    /// Xcode 27 re-homes the display protocols in CoreSimDeviceIO. Loading it is best-effort: the
    /// port descriptor is resolved by selector, so a missing bundle costs nothing on Xcode 16.
    private static func coreSimDeviceIOCandidates() -> [String] {
        var candidates = ["/Library/Developer/PrivateFrameworks/CoreSimDeviceIO.framework/CoreSimDeviceIO"]
        if let dev = developerDirectory {
            candidates.append(dev + "/../SharedFrameworks/CoreSimDeviceIO.framework/CoreSimDeviceIO")
        }
        return candidates
    }

    private static func dlopenFirst(_ candidates: [String]) -> (handle: UnsafeMutableRawPointer?, error: String?) {
        var lastError: String?
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else {
                lastError = "\(path): no such file"
                continue
            }
            if let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) { return (handle, nil) }
            lastError = dlerror().map { String(cString: $0) } ?? "\(path): dlopen failed"
        }
        return (nil, lastError)
    }

    private static let coreSimulator: Result<UnsafeMutableRawPointer, SimulatorRuntimeFailure> = {
        guard developerDirectory != nil else { return .failure(.noDeveloperDirectory) }
        let candidates = coreSimulatorCandidates()
        let loaded = dlopenFirst(candidates)
        // Best-effort: on Xcode 27 the display protocols come from here, and it re-exports.
        _ = dlopenFirst(coreSimDeviceIOCandidates())
        guard let handle = loaded.handle else {
            return .failure(.frameworkUnavailable(
                name: "CoreSimulator", candidates: candidates, dlerror: loaded.error))
        }
        return .success(handle)
    }()

    private static let simulatorKit: Result<UnsafeMutableRawPointer, SimulatorRuntimeFailure> = {
        // SimulatorKit links against CoreSimulator; load the dependency first so a failure is
        // reported against the framework that actually went missing.
        if case let .failure(failure) = coreSimulator { return .failure(failure) }
        let candidates = simulatorKitCandidates()
        guard !candidates.isEmpty else { return .failure(.noDeveloperDirectory) }
        let loaded = dlopenFirst(candidates)
        guard let handle = loaded.handle else {
            return .failure(.frameworkUnavailable(
                name: "SimulatorKit", candidates: candidates, dlerror: loaded.error))
        }
        return .success(handle)
    }()

    static func loadCoreSimulator() throws -> UnsafeMutableRawPointer { try coreSimulator.get() }

    static func loadSimulatorKit() throws -> UnsafeMutableRawPointer { try simulatorKit.get() }

    /// A `dlsym` in a loaded bundle, reinterpreted as a C function type. `RTLD_LOCAL` above means
    /// the handle — not the global namespace — is what gets searched, so a same-named symbol from
    /// somewhere else cannot be picked up by accident.
    static func symbol<Function>(
        _ name: String, in handle: UnsafeMutableRawPointer, framework: String, as: Function.Type
    ) throws -> Function {
        guard let pointer = dlsym(handle, name) else {
            throw SimulatorRuntimeFailure.symbolUnavailable(name: name, framework: framework)
        }
        return unsafeBitCast(pointer, to: Function.self)
    }

    /// Whether a symbol exists, without binding it. Used to report which Indigo builders this
    /// Xcode actually exports.
    static func hasSymbol(_ name: String, in handle: UnsafeMutableRawPointer) -> Bool {
        dlsym(handle, name) != nil
    }

    // MARK: Class lookup

    /// Looks a runtime-only class up by name, trying each candidate in turn. SimulatorKit is a
    /// Swift framework, so its classes register under their mangled `Module.Class` name and
    /// `objc_lookUpClass("SimDeviceLegacyHIDClient")` alone misses them.
    static func lookUpClass(_ names: [String]) -> AnyClass? {
        for name in names {
            if let cls = objc_lookUpClass(name) { return cls }
            if let cls = NSClassFromString(name) { return cls }
        }
        return nil
    }

    // MARK: Device handles

    /// The shared `SimServiceContext` for the active Xcode.
    static func serviceContext() throws -> AnyObject {
        _ = try loadCoreSimulator()
        guard let developerDirectory else { throw SimulatorRuntimeFailure.noDeveloperDirectory }
        guard let contextClass = lookUpClass(["SimServiceContext"]) else {
            throw SimulatorRuntimeFailure.classUnavailable("SimServiceContext")
        }
        let selector = "sharedServiceContextForDeveloperDir:error:"
        // `as AnyObject`, not a bit cast: `AnyClass` is an existential metatype and reinterpreting
        // it as an object reference does not survive the optimiser.
        let classObject = contextClass as AnyObject
        guard classObject.responds(to: NSSelectorFromString(selector)) else {
            throw SimulatorRuntimeFailure.selectorUnavailable(
                className: "SimServiceContext", selector: selector)
        }
        var error: NSError?
        let context = unsafeBitCast(classObject, to: SimServiceContextClassMessaging.self)
            .sharedServiceContext(forDeveloperDir: developerDirectory, error: &error)
        guard let context else {
            throw SimulatorRuntimeFailure.serviceContextUnavailable(
                error?.localizedDescription ?? "returned nil for \(developerDirectory)")
        }
        return context
    }

    /// Every device in the default device set, as opaque `SimDevice` handles.
    static func devices() throws -> [AnyObject] {
        let context = try serviceContext()
        let selector = "defaultDeviceSetWithError:"
        guard context.responds(to: NSSelectorFromString(selector)) else {
            throw SimulatorRuntimeFailure.selectorUnavailable(
                className: String(describing: type(of: context)), selector: selector)
        }
        var error: NSError?
        guard let deviceSet = unsafeBitCast(context, to: SimServiceContextMessaging.self)
            .defaultDeviceSet(error: &error)
        else {
            throw SimulatorRuntimeFailure.deviceSetUnavailable(
                error?.localizedDescription ?? "returned nil")
        }
        guard deviceSet.responds(to: NSSelectorFromString("devices")) else {
            throw SimulatorRuntimeFailure.selectorUnavailable(
                className: String(describing: type(of: deviceSet)), selector: "devices")
        }
        guard let devices = unsafeBitCast(deviceSet, to: SimDeviceSetMessaging.self).devices else {
            throw SimulatorRuntimeFailure.selectorReturnedNil(
                className: String(describing: type(of: deviceSet)), selector: "devices")
        }
        return devices
    }

    /// The `SimDevice` handle for a UDID. Matched case-insensitively — `simctl` prints UDIDs
    /// upper-cased and `-[SimDevice udid]` vends an `NSUUID`.
    static func device(udid: String) throws -> AnyObject {
        let wanted = udid.lowercased()
        for device in try devices() {
            guard device.responds(to: NSSelectorFromString("UDID")),
                  let identifier = unsafeBitCast(device, to: SimDeviceMessaging.self).udid
            else { continue }
            if identifier.uuidString.lowercased() == wanted { return device }
        }
        throw SimulatorRuntimeFailure.deviceNotFound(udid: udid)
    }

    /// A booted `SimDevice` handle, or a failure naming which precondition was not met. Callers
    /// need this before touching the display: an unbooted device's framebuffer port is inert.
    static func bootedDevice(udid: String) throws -> AnyObject {
        let device = try device(udid: udid)
        guard device.responds(to: NSSelectorFromString("state")) else {
            throw SimulatorRuntimeFailure.selectorUnavailable(
                className: String(describing: type(of: device)), selector: "state")
        }
        guard unsafeBitCast(device, to: SimDeviceMessaging.self).state == bootedState else {
            throw SimulatorRuntimeFailure.deviceNotBooted(udid: udid)
        }
        return device
    }
}

// MARK: - Shell

/// The subprocess runner the simulator engine uses for `xcode-select` and `simctl`. `simctl` is
/// the supported, stable lifecycle interface (ADR-0015), so shelling out to it is a design choice,
/// not a shortcut — CoreSimulator is reserved for the things `simctl` has no verb for.
enum SimulatorShell {
    struct Output {
        var status: Int32
        var standardOutput: String
        var standardError: String

        var trimmedOutput: String { standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) }
        /// Whichever stream carries the explanation, preferring stderr.
        var failureMessage: String {
            let stderr = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return stderr.isEmpty ? trimmedOutput : stderr
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case launchFailed(command: String, underlying: String)
        case exited(command: String, status: Int32, message: String)

        var description: String {
            switch self {
            case let .launchFailed(command, underlying):
                return "Could not run \(command): \(underlying)"
            case let .exited(command, status, message):
                return "\(command) exited \(status)\(message.isEmpty ? "" : ": \(message)")"
            }
        }
    }

    @discardableResult
    static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval? = nil
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            throw Failure.launchFailed(
                command: ([executable] + arguments).joined(separator: " "),
                underlying: error.localizedDescription)
        }

        // Read both pipes concurrently: simctl can fill either buffer, and reading them in
        // sequence deadlocks the child once the unread one hits the pipe limit.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, sink) in [(outPipe, { outData = $0 }), (errPipe, { errData = $0 })] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                sink(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { usleep(5_000) }
            if process.isRunning {
                // SIGTERM, then SIGKILL. `waitUntilExit()` below is unbounded, so a child that
                // ignores SIGTERM would park this thread and its two pipe fds for the life of the
                // app — and these run on control-connection threads, one fd each. A bounded call
                // that waits forever after its own timeout fires is not bounded.
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning, Date() < grace { usleep(5_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process.waitUntilExit()
        group.wait()

        return Output(
            status: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self))
    }

    /// `xcrun simctl …`, failing with the message `simctl` printed rather than a bare status.
    @discardableResult
    static func simctl(_ arguments: [String], timeout: TimeInterval? = nil) throws -> Output {
        let output = try run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: timeout)
        guard output.status == 0 else {
            throw Failure.exited(
                command: "simctl " + arguments.joined(separator: " "),
                status: output.status, message: output.failureMessage)
        }
        return output
    }
}
