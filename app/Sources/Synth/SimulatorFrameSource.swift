import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import ObjectiveC

// The live framebuffer path (ADR-0015): a booted device publishes its display as an IOSurface on a
// port hanging off `SimDevice.io`, and we read that surface in-process. Simulator.app is never
// launched and never involved.
//
// Four measured facts are load-bearing here and each one is a trap if ignored:
//
//   * A booted device exposes TWO ports with `portIdentifier == "com.apple.framebuffer.display"`,
//     the same proxy class and the same proxy UUID. The first is inert — 0×0 `displaySize` and a
//     nil surface — so selecting on protocol conformance alone binds to a display that never
//     delivers a frame. A live port needs a non-zero size AND a non-nil surface.
//   * Descriptors are `ROCKRemoteProxy` objects: every property read is an XPC round trip. The
//     surface is resolved once and retained, and re-read only when the surface-change callback
//     fires. Never per frame.
//   * The first `CVPixelBufferCreateWithIOSurface` costs 11–28 ms against 22 µs steady state
//     (lazy CoreVideo setup), so it is primed off the source's own queue at start.
//   * Damage callbacks burst — the minimum observed gap was 0.00 ms, two callbacks inside the same
//     nanosecond. Work is coalesced to a frame interval rather than done per callback.

// MARK: - Runtime-only messaging surface

/// The display port descriptor. On Xcode 16 these selectors come from SimulatorKit's
/// `SimDisplayIOSurfaceRenderable` / `SimDisplayRenderable`; on Xcode 27 the same selectors come
/// from CoreSimDeviceIO. Because everything is reached by selector, that move is invisible here.
@objc private protocol SimDisplayMessaging {
    @objc var displaySize: CGSize { get }
    @objc var displayPitch: Int64 { get }
    /// Xcode 13.2 and later. The unmasked framebuffer: what the device actually renders.
    @objc var framebufferSurface: AnyObject? { get }
    /// Pre-13.2 name for the same thing.
    @objc var ioSurface: AnyObject? { get }
    @objc var portIdentifier: String? { get }

    @objc(registerCallbackWithUUID:ioSurfacesChangeCallback:)
    func registerSurfacesChange(uuid: NSUUID, callback: @escaping (AnyObject?) -> Void)
    @objc(registerCallbackWithUUID:ioSurfaceChangeCallback:)
    func registerSurfaceChange(uuid: NSUUID, callback: @escaping (AnyObject?) -> Void)
    @objc(unregisterIOSurfacesChangeCallbackWithUUID:)
    func unregisterSurfacesChange(uuid: NSUUID)
    @objc(unregisterIOSurfaceChangeCallbackWithUUID:)
    func unregisterSurfaceChange(uuid: NSUUID)

    @objc(registerCallbackWithUUID:damageRectanglesCallback:)
    func registerDamageRectangles(uuid: NSUUID, callback: @escaping (NSArray?) -> Void)
    @objc(unregisterDamageRectanglesCallbackWithUUID:)
    func unregisterDamageRectangles(uuid: NSUUID)

    /// Xcode 27's single registration for all three signals. Preferred when present; the blocks are
    /// declared with the fewest arguments their names imply, because a block called with more
    /// arguments than it declares is harmless while the reverse is not.
    @objc(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
    func registerScreenCallbacks(
        uuid: NSUUID,
        callbackQueue: DispatchQueue,
        frameCallback: @escaping () -> Void,
        surfacesChangedCallback: @escaping (AnyObject?) -> Void,
        propertiesChangedCallback: @escaping () -> Void)
    @objc(unregisterScreenCallbacksWithUUID:)
    func unregisterScreenCallbacks(uuid: NSUUID)
}

// MARK: - Frame source

/// Reads a booted device's framebuffer and hands each new frame out as a `CVPixelBuffer` wrapping
/// the live surface. Deliberately does not copy the surface: tearing is inherent to handing over a
/// live surface and at a measured 1.3% it is the right trade, so frames are marked torn rather
/// than made safe.
/// Raised only by `SYNTH_SIM_FORCE_DEGRADED`, and says so, because a degradation notice that
/// invented a cause would be worse than no notice at all.
struct ForcedDegradation: Error, CustomStringConvertible {
    var description: String {
        "SYNTH_SIM_FORCE_DEGRADED is set, so the private live paths were skipped deliberately."
    }
}

final class SimulatorFrameSource: SimulatorScreenSource {

    let udid: String

    // Every mutable field below is touched from at least two threads: the owner's (start, stop, the
    // pane setting callbacks and reading `displaySize`) and `queue`'s (the device's callbacks, and
    // production). All of them are therefore behind `stateLock` and reached only through the
    // accessors underneath, because the ones holding an object are the dangerous ones: an
    // unsynchronised store to a strong `AnyObject` ivar against a load on another thread is a
    // double release, and a double release in this process is not a degraded pane — it takes the
    // user's terminals and agent sessions with it. `statistics` counts for that too: it owns two
    // arrays, so recording a frame while the pane reads the summary races on their buffers.
    private let stateLock = NSLock()
    private var _callbackQueue: DispatchQueue = .main
    private var _onFrame: ((SimulatorFrame) -> Void)?
    private var _onDisplaySizeChange: ((CGSize) -> Void)?
    private var _onLiveScreenLost: ((String) -> Void)?
    private var _minimumFrameInterval: TimeInterval = 1.0 / 120.0
    private var _displaySize: CGSize = .zero
    private var _displayPitch: Int64 = 0
    private var _resolvedSelectors: [String: Bool] = [:]
    private var _statistics = SimulatorFrameStatistics()
    private var _display: AnyObject?
    /// Resolved once and retained. Reading it per frame would be an XPC round trip per frame.
    private var _surface: AnyObject?
    private var _lastSeed: UInt32?
    private var _frameIndex: UInt64 = 0
    private var _lastProductionTime: UInt64 = 0
    private var _isProductionScheduled = false
    private var _isStarted = false

    /// `NSLock` is not recursive, so nothing inside a `locked` block may call an accessor: read the
    /// underscored fields directly in there.
    private func locked<Value>(_ body: () -> Value) -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Where `onFrame` is delivered. `.main` by default: production costs 22 µs, and the pane
    /// enqueueing on the main thread is both the simplest and the least surprising contract.
    var callbackQueue: DispatchQueue {
        get { locked { _callbackQueue } }
        set { locked { _callbackQueue = newValue } }
    }

    var onFrame: ((SimulatorFrame) -> Void)? {
        get { locked { _onFrame } }
        set { locked { _onFrame = newValue } }
    }

    /// Fires when the device replaces its surface — a rotation or a display reconfiguration. The
    /// pane needs it because the new surface can have a different size.
    var onDisplaySizeChange: ((CGSize) -> Void)? {
        get { locked { _onDisplaySizeChange } }
        set { locked { _onDisplaySizeChange = newValue } }
    }

    /// Fires when the descriptor replaces the framebuffer with something that is not an IOSurface —
    /// the shape a future Xcode changing the surface type would take. The last good surface is kept
    /// and frames go stale, so whoever owns this source has to degrade and say why.
    var onLiveScreenLost: ((String) -> Void)? {
        get { locked { _onLiveScreenLost } }
        set { locked { _onLiveScreenLost = newValue } }
    }

    /// The floor on how often a frame is produced. Damage callbacks burst inside the same
    /// nanosecond, so the ceiling is set a little above the fastest display Synth runs on rather
    /// than left to the guest's callback cadence.
    var minimumFrameInterval: TimeInterval {
        get { locked { _minimumFrameInterval } }
        set { locked { _minimumFrameInterval = newValue } }
    }

    var displaySize: CGSize { locked { _displaySize } }
    var displayPitch: Int64 { locked { _displayPitch } }
    /// Which display selectors this Xcode's descriptor actually answers to. Diagnostic only, but
    /// it is the first thing worth knowing when a new Xcode moves something.
    var resolvedSelectors: [String: Bool] { locked { _resolvedSelectors } }
    var statistics: SimulatorFrameStatistics { locked { _statistics } }

    private let queue = DispatchQueue(label: "com.synth.simulator.frames", qos: .userInteractive)
    private let registrationUUID = NSUUID()

    init(udid: String) {
        self.udid = udid
    }

    /// No `queue.sync` barrier here, unlike `stop()`: the last reference can be dropped by a block
    /// running on `queue`, and waiting on the queue we are being deallocated from is a deadlock.
    deinit { unregister(from: locked { _display }) }

    // MARK: Lifecycle

    /// Binds to the device's live display and starts delivering frames. Throws with the reason the
    /// live path could not be used, which is what the degraded fallback reports to the user.
    func start() throws {
        guard !locked({ _isStarted }) else { return }
        // Testability seam, in the spirit of SYNTH_AUTOMATION: the `simctl`-only fallback is part of
        // the design (ADR-0015), so it has to be reachable on a machine where the live path works —
        // otherwise the degraded mode is only ever exercised by the Xcode release that breaks it.
        if ProcessInfo.processInfo.environment["SYNTH_SIM_FORCE_DEGRADED"] != nil {
            throw ForcedDegradation()
        }
        let device = try SimulatorPrivateRuntime.bootedDevice(udid: udid)
        let resolved = try Self.resolveDisplay(device: device)
        locked {
            _display = resolved.descriptor
            _displaySize = resolved.size
            _displayPitch = resolved.pitch
            _surface = resolved.surface
            _resolvedSelectors = resolved.selectors
            _isStarted = true
        }

        register(on: resolved.descriptor)

        // Pay the 11–28 ms lazy CoreVideo initialisation on our own queue, before any callback can
        // arrive, so opening a pane does not visibly hitch.
        queue.async { [weak self] in
            self?.primeCoreVideo()
            self?.produce(force: true)
        }
    }

    /// Takes the display out from under the lock before unregistering, so the callbacks come down
    /// exactly once however this races with `deinit`, and drains `queue` afterwards so that `stop()`
    /// is genuinely the point after which no frame arrives.
    func stop() {
        let display: AnyObject? = locked {
            let current = _display
            _display = nil
            _surface = nil
            _lastSeed = nil
            _isStarted = false
            return current
        }
        unregister(from: display)
        queue.sync {}
    }

    /// The surface as it stands right now, for a one-shot read (a screenshot, an agent's observe)
    /// that should not wait for the next damage callback.
    func captureCurrentFrame() -> SimulatorFrame? {
        queue.sync { makeFrame(force: true) }
    }

    // MARK: Display resolution

    private struct ResolvedDisplay {
        var descriptor: AnyObject
        var size: CGSize
        var pitch: Int64
        var surface: AnyObject
        var selectors: [String: Bool]
    }

    private static let requiredSurfaceSelectors = ["framebufferSurface", "ioSurface"]
    private static let requiredRegistrationSelectors = [
        "registerCallbackWithUUID:ioSurfacesChangeCallback:",
        "registerCallbackWithUUID:ioSurfaceChangeCallback:",
        "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:",
    ]

    /// Finds the one display port that will actually deliver frames.
    ///
    /// Selection is by selector rather than by `conformsToProtocol:`, which is both a stronger
    /// check and immune to the protocols moving framework — but the decisive filter is neither: it
    /// is that the port reports a non-zero `displaySize` and vends a non-nil surface. The first
    /// framebuffer port a booted device publishes satisfies every protocol and conformance test and
    /// is inert.
    private static func resolveDisplay(device: AnyObject) throws -> ResolvedDisplay {
        guard device.responds(to: NSSelectorFromString("io")),
              let io = unsafeBitCast(device, to: SimDeviceMessaging.self).io
        else {
            throw SimulatorRuntimeFailure.selectorUnavailable(
                className: String(describing: type(of: device)), selector: "io")
        }
        guard io.responds(to: NSSelectorFromString("ioPorts")) else {
            throw SimulatorRuntimeFailure.selectorUnavailable(
                className: String(describing: type(of: io)), selector: "ioPorts")
        }
        guard let ports = unsafeBitCast(io, to: SimDeviceIOMessaging.self).ioPorts else {
            throw SimulatorRuntimeFailure.selectorReturnedNil(
                className: String(describing: type(of: io)), selector: "ioPorts")
        }

        var inspected = 0
        var inert = 0
        var unusableSurfaceClass: String?
        for port in ports {
            inspected += 1
            guard port.responds(to: NSSelectorFromString("descriptor")),
                  let descriptor = unsafeBitCast(port, to: SimDeviceIOPortMessaging.self).descriptor
            else { continue }

            func responds(_ selector: String) -> Bool {
                descriptor.responds(to: NSSelectorFromString(selector))
            }
            guard responds("displaySize"),
                  requiredSurfaceSelectors.contains(where: responds),
                  requiredRegistrationSelectors.contains(where: responds)
            else { continue }

            let messaging = unsafeBitCast(descriptor, to: SimDisplayMessaging.self)
            let size = messaging.displaySize
            let surface = responds("framebufferSurface")
                ? messaging.framebufferSurface ?? (responds("ioSurface") ? messaging.ioSurface : nil)
                : messaging.ioSurface
            guard size.width >= 1, size.height >= 1, let surface else {
                inert += 1
                continue
            }
            // The surface arrives as `id`. Nothing but the runtime says it is an IOSurface, and
            // every read below is a C call that would be undefined behaviour on anything else, so
            // a port whose framebuffer is not one is not a port we can use.
            guard ioSurfaceReference(surface) != nil else {
                unusableSurfaceClass = String(describing: type(of: surface))
                continue
            }

            var selectors: [String: Bool] = [:]
            for selector in requiredSurfaceSelectors + requiredRegistrationSelectors + [
                "displayPitch", "portIdentifier",
                "registerCallbackWithUUID:damageRectanglesCallback:",
                "unregisterIOSurfacesChangeCallbackWithUUID:",
                "unregisterDamageRectanglesCallbackWithUUID:",
            ] {
                selectors[selector] = responds(selector)
            }
            return ResolvedDisplay(
                descriptor: descriptor,
                size: size,
                pitch: responds("displayPitch") ? messaging.displayPitch : 0,
                surface: surface,
                selectors: selectors)
        }
        // A live port with an unreadable framebuffer is a different failure from no port at all, and
        // it is the one a future Xcode would produce, so it is reported as itself.
        if let unusableSurfaceClass {
            throw SimulatorRuntimeFailure.displaySurfaceUnusable(className: unusableSurfaceClass)
        }
        throw SimulatorRuntimeFailure.noDisplayPort(
            portsInspected: inspected, inertPortsSkipped: inert)
    }

    /// `framebufferSurface` is typed `id`, and the only thing that makes it an IOSurface is what the
    /// runtime says. `IOSurfaceGetWidth` on anything else is undefined behaviour, so the CF type is
    /// checked before the cast rather than after the crash.
    private static func ioSurfaceReference(_ object: AnyObject) -> IOSurfaceRef? {
        guard CFGetTypeID(object) == IOSurfaceGetTypeID() else { return nil }
        return unsafeBitCast(object, to: IOSurfaceRef.self)
    }

    // MARK: Callback registration

    private func register(on descriptor: AnyObject) {
        let messaging = unsafeBitCast(descriptor, to: SimDisplayMessaging.self)
        func responds(_ selector: String) -> Bool {
            descriptor.responds(to: NSSelectorFromString(selector))
        }

        // Xcode 27's combined registration is preferred when it exists. It does not exist on
        // Xcode 16, so a watchdog installs the two-callback form if no frame arrives — that keeps
        // the newer path preferred without betting the pane on an unverified block signature.
        if responds(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"
        ) {
            messaging.registerScreenCallbacks(
                uuid: registrationUUID,
                callbackQueue: queue,
                frameCallback: { [weak self] in self?.frameSignalled() },
                surfacesChangedCallback: { [weak self] surface in self?.surfaceReplaced(surface) },
                propertiesChangedCallback: { [weak self] in self?.displayPropertiesChanged() })
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self,
                      locked({ self._isStarted && self._statistics.frames == 0 })
                else { return }
                registerLegacyCallbacks(on: descriptor)
            }
            return
        }
        registerLegacyCallbacks(on: descriptor)
    }

    private func registerLegacyCallbacks(on descriptor: AnyObject) {
        let messaging = unsafeBitCast(descriptor, to: SimDisplayMessaging.self)
        func responds(_ selector: String) -> Bool {
            descriptor.responds(to: NSSelectorFromString(selector))
        }

        // One block parameter, deliberately. The runtime may pass two (unmasked and masked
        // surfaces); an extra argument is harmless, whereas declaring a parameter that is never
        // passed reads whatever happened to be in the register.
        if responds("registerCallbackWithUUID:ioSurfacesChangeCallback:") {
            messaging.registerSurfacesChange(uuid: registrationUUID) { [weak self] surface in
                self?.surfaceReplaced(surface)
            }
        } else if responds("registerCallbackWithUUID:ioSurfaceChangeCallback:") {
            messaging.registerSurfaceChange(uuid: registrationUUID) { [weak self] surface in
                self?.surfaceReplaced(surface)
            }
        }

        if responds("registerCallbackWithUUID:damageRectanglesCallback:") {
            // The rectangles are ignored on purpose: on modern CoreSimulator the compositor
            // computes no changed regions and always passes an empty array. This is a "a frame was
            // rendered" signal, not geometry.
            messaging.registerDamageRectangles(uuid: registrationUUID) { [weak self] _ in
                self?.frameSignalled()
            }
        }
    }

    /// Takes down every registration this source could have made, on the descriptor the caller
    /// already has in hand — never on an ivar, so this cannot race with `stop()` nilling it. Both
    /// registration paths are undone unconditionally: the modern one installs the legacy callbacks
    /// too when no frame arrives, so which ones are live is not knowable from a single flag.
    private func unregister(from display: AnyObject?) {
        guard let display else { return }
        func responds(_ selector: String) -> Bool {
            display.responds(to: NSSelectorFromString(selector))
        }
        let messaging = unsafeBitCast(display, to: SimDisplayMessaging.self)
        if responds("unregisterScreenCallbacksWithUUID:") {
            messaging.unregisterScreenCallbacks(uuid: registrationUUID)
        }
        if responds("unregisterDamageRectanglesCallbackWithUUID:") {
            messaging.unregisterDamageRectangles(uuid: registrationUUID)
        }
        if responds("unregisterIOSurfacesChangeCallbackWithUUID:") {
            messaging.unregisterSurfacesChange(uuid: registrationUUID)
        } else if responds("unregisterIOSurfaceChangeCallbackWithUUID:") {
            messaging.unregisterSurfaceChange(uuid: registrationUUID)
        }
    }

    // MARK: Callbacks

    /// A frame was rendered. Callbacks burst, so this only ever sets a flag and schedules one
    /// production at the frame interval — never does the work inline.
    private func frameSignalled() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            let earliest: UInt64? = locked {
                guard !self._isProductionScheduled else { return nil }
                let interval = UInt64(max(0, self._minimumFrameInterval) * 1_000_000_000)
                let earliest = self._lastProductionTime + interval
                if now < earliest { self._isProductionScheduled = true }
                return earliest
            }
            guard let earliest else { return }
            guard now < earliest else { return produce(force: false) }
            queue.asyncAfter(deadline: .now() + Double(earliest - now) / 1_000_000_000) {
                [weak self] in
                guard let self else { return }
                locked { self._isProductionScheduled = false }
                produce(force: false)
            }
        }
    }

    private func surfaceReplaced(_ replacement: AnyObject?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let replacement else {
                locked {
                    self._surface = nil
                    self._lastSeed = nil
                }
                return
            }
            // A replacement that is not an IOSurface cannot be read, and reinterpreting it anyway
            // is the undefined behaviour this guard exists for. The last good surface is kept, so
            // the pane goes stale rather than wrong, and the owner is told why.
            guard let reference = Self.ioSurfaceReference(replacement) else {
                let detail = "The device replaced its framebuffer with a "
                    + "\(String(describing: type(of: replacement))), which is not an IOSurface, so "
                    + "the live screen stopped at the last frame Synth could read."
                let callback = locked { self._onLiveScreenLost }
                let queue = locked { self._callbackQueue }
                queue.async { callback?(detail) }
                return
            }
            locked {
                self._surface = replacement
                self._lastSeed = nil
            }
            publish(displaySize: CGSize(
                width: IOSurfaceGetWidth(reference), height: IOSurfaceGetHeight(reference)))
            produce(force: true)
        }
    }

    /// The display's geometry moved. `displaySize` is a proxy read, so it is only re-read here —
    /// on the signal that it changed — and never per frame.
    private func displayPropertiesChanged() {
        queue.async { [weak self] in
            guard let self, let display = locked({ self._display }),
                  display.responds(to: NSSelectorFromString("displaySize")) else { return }
            publish(displaySize: unsafeBitCast(display, to: SimDisplayMessaging.self).displaySize)
        }
    }

    /// Records a size the device reported and tells the pane once, off the lock — a callback is
    /// somebody else's code and must never run inside `stateLock`.
    private func publish(displaySize size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }
        stateLock.lock()
        guard size != _displaySize else { return stateLock.unlock() }
        _displaySize = size
        let callback = _onDisplaySizeChange
        let queue = _callbackQueue
        stateLock.unlock()
        queue.async { callback?(size) }
    }

    // MARK: Production

    /// The first `CVPixelBufferCreateWithIOSurface` in a process costs 11–28 ms of lazy CoreVideo
    /// setup against 22 µs steady state. Paid here, off the caller's thread, and thrown away.
    private func primeCoreVideo() {
        guard let surface = locked({ _surface }),
              let reference = Self.ioSurfaceReference(surface) else { return }
        var created: Unmanaged<CVPixelBuffer>?
        _ = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, reference, nil, &created)
        created?.release()
    }

    private func produce(force: Bool) {
        guard let frame = makeFrame(force: force) else { return }
        stateLock.lock()
        let callback = _onFrame
        let queue = _callbackQueue
        stateLock.unlock()
        queue.async { callback?(frame) }
    }

    /// Wraps the live surface. Frames are deduped on `IOSurfaceGetSeed`, and a seed that moves
    /// while we wrap means the guest drew underneath us — recorded as torn, not prevented.
    private func makeFrame(force: Bool) -> SimulatorFrame? {
        // A strong local copy taken under the lock, which is the whole reason the lock is here: the
        // surface must not be released by `stop()` on another thread between this read and the C
        // calls below.
        stateLock.lock()
        let held = _surface
        let previousSeed = _lastSeed
        stateLock.unlock()
        guard let held, let reference = Self.ioSurfaceReference(held) else { return nil }
        let seedBefore = IOSurfaceGetSeed(reference)
        if !force, seedBefore == previousSeed { return nil }

        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        var created: Unmanaged<CVPixelBuffer>?
        let result = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, reference, nil, &created)
        let end = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        guard result == kCVReturnSuccess, let buffer = created?.takeRetainedValue() else { return nil }
        let seedAfter = IOSurfaceGetSeed(reference)

        stateLock.lock()
        _lastSeed = seedAfter
        _frameIndex += 1
        let index = _frameIndex
        _statistics.record(
            gap: _lastProductionTime == 0 ? nil : start - _lastProductionTime,
            cost: end - start,
            torn: seedAfter != seedBefore)
        _lastProductionTime = start
        stateLock.unlock()

        return SimulatorFrame(
            pixelBuffer: buffer,
            pixelSize: CGSize(
                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
            seed: seedAfter,
            isTorn: seedAfter != seedBefore,
            index: index,
            producedAt: start)
    }
}
