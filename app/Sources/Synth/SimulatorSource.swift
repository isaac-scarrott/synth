import CoreGraphics
import CryptoKit
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

// What the simulator pane talks to. One surface, two ways of filling it (ADR-0015): the live
// framebuffer, and a `simctl`-only degraded mode that exists in the design rather than as a later
// rescue. A source that had to fall back says so and says why, because a pane that quietly shows a
// stale screenshot at 2 fps is worse than one that admits it.
//
// The same object serves the user's pointer and Claude's tool calls. That is the whole point: a tap
// from the agent and a tap from the mouse are the same Indigo message on the same device.

// MARK: - Frames

/// One frame of the device's screen, as a `CVPixelBuffer` ready for
/// `AVSampleBufferDisplayLayer.enqueue`. Setting `layer.contents` to the IOSurface instead does not
/// work — the layer will not re-composite when the surface mutates underneath it.
struct SimulatorFrame {
    let pixelBuffer: CVPixelBuffer
    let pixelSize: CGSize
    /// `IOSurfaceGetSeed` at capture, which is what frames are deduped on.
    let seed: UInt32
    /// The guest drew into the surface while we were wrapping it. Measured at ~1.3% and inherent to
    /// handing over a live surface rather than copying it: detected, not prevented.
    let isTorn: Bool
    let index: UInt64
    /// `CLOCK_MONOTONIC_RAW` nanoseconds at production.
    let producedAt: UInt64

    /// A sample buffer for `AVSampleBufferDisplayLayer`, tagged to display immediately — this is a
    /// live mirror, so a frame that is not shown now has no reason to be shown later.
    func makeSampleBuffer() -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
            == noErr, let format
        else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample
        else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                entry,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// Frame cadence and our own cost in it. Kept because the numbers are the argument: our production
/// step is 22 µs against a 16.7 ms frame, so when a pane feels slow this says whether that is us.
struct SimulatorFrameStatistics {
    private static let sampleLimit = 4096

    private(set) var frames = 0
    private(set) var tornFrames = 0
    private var gaps: [UInt64] = []
    private var costs: [UInt64] = []

    mutating func record(gap: UInt64?, cost: UInt64, torn: Bool) {
        frames += 1
        if torn { tornFrames += 1 }
        if let gap { append(gap, to: &gaps) }
        append(cost, to: &costs)
    }

    private func append(_ sample: UInt64, to samples: inout [UInt64]) {
        if samples.count >= Self.sampleLimit { samples.removeFirst(Self.sampleLimit / 4) }
        samples.append(sample)
    }

    /// Frames per second implied by the mean inter-frame gap.
    var meanFrameRate: Double {
        guard !gaps.isEmpty else { return 0 }
        let mean = Double(gaps.reduce(0, +)) / Double(gaps.count)
        return mean > 0 ? 1_000_000_000 / mean : 0
    }

    var tornFraction: Double { frames == 0 ? 0 : Double(tornFrames) / Double(frames) }

    /// Inter-frame gap at a percentile, in milliseconds.
    func gapMilliseconds(percentile: Double) -> Double { Self.percentile(gaps, percentile) }
    /// Our production cost at a percentile, in milliseconds.
    func costMilliseconds(percentile: Double) -> Double { Self.percentile(costs, percentile) }

    private static func percentile(_ samples: [UInt64], _ fraction: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, max(0, Int(fraction * Double(sorted.count - 1))))
        return Double(sorted[index]) / 1_000_000
    }

    var summary: String {
        String(
            format: "%d frames, %.1f fps mean, gap p50 %.2fms p95 %.2fms p99 %.2fms, "
                + "cost p50 %.3fms p99 %.3fms, torn %.1f%%",
            frames, meanFrameRate,
            gapMilliseconds(percentile: 0.50), gapMilliseconds(percentile: 0.95),
            gapMilliseconds(percentile: 0.99),
            costMilliseconds(percentile: 0.50), costMilliseconds(percentile: 0.99),
            tornFraction * 100)
    }
}

// MARK: - Degradation

/// Why a source is not running at full fidelity. Carried, not logged: a degraded simulator session
/// has to say what it lost and what it fell back to.
struct SimulatorSourceDegradation {
    enum Capability: String {
        case screen
        case input
        case accessibility
        case orientation
    }

    struct Reason {
        var capability: Capability
        /// Why the live path could not be used, in the words of the failure itself.
        var detail: String
        /// What is being used instead.
        var fallback: String
    }

    var reasons: [Reason]

    var affectsScreen: Bool { reasons.contains { $0.capability == .screen } }
    var affectsInput: Bool { reasons.contains { $0.capability == .input } }
    var affectsAccessibility: Bool { reasons.contains { $0.capability == .accessibility } }
    var affectsOrientation: Bool { reasons.contains { $0.capability == .orientation } }

    var summary: String {
        reasons.map { "\($0.capability.rawValue.capitalized): \($0.fallback). \($0.detail)" }
            .joined(separator: " ")
    }
}

/// Why a source could not start at all — both the live path and its fallback gone. Carries both
/// reasons because the first one is the one worth reading and the second explains why there was no
/// safety net.
enum SimulatorSourceFailure: Error, CustomStringConvertible {
    case screenUnavailable(live: String, fallback: String)

    var description: String {
        switch self {
        case let .screenUnavailable(live, fallback):
            return "\(live) The `simctl` screenshot fallback did not work either: \(fallback)"
        }
    }
}

// MARK: - Protocols

/// Where the pane's pixels come from.
protocol SimulatorScreenSource: AnyObject {
    var displaySize: CGSize { get }
    var onFrame: ((SimulatorFrame) -> Void)? { get set }
    var onDisplaySizeChange: ((CGSize) -> Void)? { get set }
    var callbackQueue: DispatchQueue { get set }
    var statistics: SimulatorFrameStatistics { get }

    func start() throws
    func stop()
    /// The screen as it stands right now, without waiting for the next frame.
    func captureCurrentFrame() -> SimulatorFrame?
}

/// Where the pane's input goes.
protocol SimulatorInputSink: AnyObject {
    /// Opens the input session. Separate from construction because opening it costs over a second.
    func prepare() throws
    func invalidate()

    // Every input verb throws. Delivery is asynchronous — a message is built on main and sent on a
    // private queue — so these cannot report the outcome of their own send; what they *can* do is
    // refuse when input demonstrably is not reaching the device, and surface the failure a send
    // already in flight recorded. Returning success for a tap that never left the process is the one
    // answer an agent cannot recover from: it re-reads the screen, sees nothing, and taps again.
    func tap(at point: CGPoint) throws
    func touchDown(at point: CGPoint) throws
    func touchMove(to point: CGPoint) throws
    func touchUp(at point: CGPoint) throws
    func type(text: String) throws
    func press(_ button: SimulatorHardwareButton) throws
}

/// Where the pane's and the agent's structural view of the screen comes from. Separate from the
/// screen because it is a different channel entirely: the framebuffer says what the device *looks*
/// like, this says what is *there*, for a fraction of the tokens.
protocol SimulatorAccessibilityReader: AnyObject {
    /// Which way up Synth last *asked* the device to be. A hint only: AXP reports element frames in
    /// the interface's coordinate space while `tap` addresses the display, and which of the four ways
    /// the one sits on the other is real gets confirmed against the device per read — because an app
    /// may refuse to rotate and nothing outside it can tell.
    var orientation: SimulatorOrientation { get set }

    func describeFrontmostApplication() throws -> SimulatorAccessibilityTree
    /// The element under a point, normalised 0..1 from the top-left — the same coordinates `tap`
    /// takes, so a hit test and a tap talk about the same place.
    func describe(at point: CGPoint) throws -> SimulatorAccessibilityTree
}

/// The simulator engine, as the pane and the MCP server see it. All coordinates are normalised
/// 0..1 from the top-left of the display, which is Indigo's own convention and means neither the
/// pane's scale factor nor the device's pixel density leaks into a caller.
protocol SimulatorSource: AnyObject {
    var udid: String { get }
    /// The framebuffer's pixel size. It does NOT change when the device rotates (ADR-0015): the
    /// guest draws its landscape interface sideways into the same portrait surface.
    var displaySize: CGSize { get }
    /// The orientation Synth last set — the only thing anybody can know, because the guest publishes
    /// no read-back for it. `.portrait` until this source rotates the device itself.
    var orientation: SimulatorOrientation { get }
    /// The most recent frame, so a resize or a re-attach can re-present without waiting.
    var latestFrame: SimulatorFrame? { get }
    var onFrame: ((SimulatorFrame) -> Void)? { get set }
    var onDisplaySizeChange: ((CGSize) -> Void)? { get set }
    /// Where callbacks are delivered. `.main` by default.
    var callbackQueue: DispatchQueue { get set }
    /// Nil when the live framebuffer and Indigo HID paths both resolved.
    var degradation: SimulatorSourceDegradation? { get }
    var frameStatistics: SimulatorFrameStatistics { get }

    func start() throws
    func stop()
    func captureCurrentFrame() -> SimulatorFrame?

    // Every input verb throws. Delivery is asynchronous — a message is built on main and sent on a
    // private queue — so these cannot report the outcome of their own send; what they *can* do is
    // refuse when input demonstrably is not reaching the device, and surface the failure a send
    // already in flight recorded. Returning success for a tap that never left the process is the one
    // answer an agent cannot recover from: it re-reads the screen, sees nothing, and taps again.
    func tap(at point: CGPoint) throws
    func touchDown(at point: CGPoint) throws
    func touchMove(to point: CGPoint) throws
    func touchUp(at point: CGPoint) throws
    func type(text: String) throws
    func press(_ button: SimulatorHardwareButton) throws

    /// Rotates the device. Throws rather than no-opping when the capability is unavailable: `simctl`
    /// has no orientation verb at any version and `devicectl device orientation set` needs Xcode 27,
    /// so there is nothing to degrade to — the same shape `describeAccessibility` has.
    ///
    /// A send that succeeds says the guest was told, not that it turned: an app declaring
    /// portrait-only stays portrait and reports nothing, and no host-side read exists to catch it.
    func setOrientation(_ orientation: SimulatorOrientation) throws
    /// Shakes the device — the RN / Expo dev menu, and UIKit's shake-to-undo.
    func shake() throws

    /// What is on the screen, structurally. Throws rather than answering an empty tree when the
    /// capability is unavailable: `simctl` has no accessibility verb at any version, so there is
    /// nothing to degrade to, and "no elements" would read as "the screen is blank".
    func describeAccessibility() throws -> SimulatorAccessibilityTree
    func describeAccessibility(at point: CGPoint) throws -> SimulatorAccessibilityTree

    // Genuinely `simctl` work, in both modes, so the agent and the user drive the same device.
    func launch(bundleIdentifier: String) throws
    func open(url: String) throws
    func install(appAtPath path: String) throws
}

// MARK: - The device source

/// A simulator session's engine: the live framebuffer and the Indigo HID session where they
/// resolve, and the `simctl` fallback where they do not — decided per capability, because a
/// missing HID client is no reason to stop showing the screen.
final class SimulatorDeviceSource: SimulatorSource {

    let udid: String

    // Every mutable field below is written by the owner — the pane, on the main actor: `start`,
    // `stop`, the callback properties — and read from the control connection's own thread, because
    // `SimulatorControl` takes this source off main and holds it for the length of a tool call. The
    // dangerous ones are the four strong `AnyObject`-bearing handles: an unsynchronised store to a
    // strong reference against a load on another thread is a double release, and a double release
    // here is not a degraded pane, it is the loss of the user's terminals and agent sessions. The
    // window is not narrow either — the boot retry calls `stop()` once a second for up to ninety
    // seconds while a swipe holds the source through ten seconds of pacing.
    //
    // So the whole of it sits behind `stateLock` and is reached only through the accessors below,
    // which is the pattern `SimulatorFrameSource` and `SimulatorHID` already follow (ADR-0015:
    // everything crossing threads is locked or queue-confined). `NSLock` is not recursive, so
    // nothing inside a `locked` block may call an accessor or a callback: snapshot, unlock, then act.
    private let stateLock = NSLock()
    private var _degradation: SimulatorSourceDegradation?
    private var _latestFrame: SimulatorFrame?
    private var _orientation: SimulatorOrientation = .portrait
    private var _callbackQueue: DispatchQueue = .main
    private var _onFrame: ((SimulatorFrame) -> Void)?
    private var _onDisplaySizeChange: ((CGSize) -> Void)?
    private var _onDegradationChange: ((SimulatorSourceDegradation?) -> Void)?
    private var _onOrientationChange: ((SimulatorOrientation) -> Void)?
    private var _screen: SimulatorScreenSource?
    private var _input: SimulatorInputSink?
    private var _accessibility: SimulatorAccessibilityReader?
    /// The GSEvent / Darwin-notification channel. Nil when it could not be resolved, in which case
    /// `workspaceFailure` says why and every verb on it refuses with that.
    private var _workspace: SimulatorPurpleEventSender?
    private var _workspaceFailure: String?
    private var _reasons: [SimulatorSourceDegradation.Reason] = []
    /// When liveness was last confirmed, for `verifyDeviceAliveCached()`.
    private var _lastAliveCheck: UInt64?
    private var _isStarted = false

    private func locked<Value>(_ body: () -> Value) -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    var degradation: SimulatorSourceDegradation? { locked { _degradation } }

    private(set) var latestFrame: SimulatorFrame? {
        get { locked { _latestFrame } }
        set { locked { _latestFrame = newValue } }
    }

    /// What Synth last told the device it was. Not read from the device, because nothing on it
    /// answers: `SimScreenProperties.uiOrientation` resolves and reports 0 in every orientation on
    /// this Xcode. A device somebody else rotated therefore reads as portrait until this source
    /// rotates it, which is a wrong drawn frame and never a wrong device.
    var orientation: SimulatorOrientation { locked { _orientation } }

    var callbackQueue: DispatchQueue {
        get { locked { _callbackQueue } }
        set {
            let screen = locked { () -> SimulatorScreenSource? in
                _callbackQueue = newValue
                return _screen
            }
            screen?.callbackQueue = newValue
        }
    }

    var onFrame: ((SimulatorFrame) -> Void)? {
        get { locked { _onFrame } }
        set { locked { _onFrame = newValue } }
    }

    var onDisplaySizeChange: ((CGSize) -> Void)? {
        get { locked { _onDisplaySizeChange } }
        set { locked { _onDisplaySizeChange = newValue } }
    }

    /// Fires when a capability is lost or regained after `start()` — the HID session is opened
    /// asynchronously, so it can degrade a moment later than the screen does.
    var onDegradationChange: ((SimulatorSourceDegradation?) -> Void)? {
        get { locked { _onDegradationChange } }
        set { locked { _onDegradationChange = newValue } }
    }

    /// Fires after a rotation the device accepted, so the pane turns its frame and its picture in
    /// step with the agent's verb as well as with its own button.
    var onOrientationChange: ((SimulatorOrientation) -> Void)? {
        get { locked { _onOrientationChange } }
        set { locked { _onOrientationChange = newValue } }
    }

    private var screen: SimulatorScreenSource? { locked { _screen } }

    var displaySize: CGSize { screen?.displaySize ?? .zero }
    var frameStatistics: SimulatorFrameStatistics { screen?.statistics ?? SimulatorFrameStatistics() }

    /// Which display selectors this Xcode's port descriptor answered to, empty in degraded mode.
    /// The first thing worth knowing when a new Xcode moves something.
    var screenDiagnostics: [String: Bool] {
        (screen as? SimulatorFrameSource)?.resolvedSelectors ?? [:]
    }

    init(udid: String) {
        self.udid = udid
    }

    deinit { stop() }

    // MARK: Lifecycle

    /// Lands on the best available path and records what it settled for. Throws only when even the
    /// degraded path is impossible — a device that is not booted, or no Xcode at all.
    func start() throws {
        guard !locked({ _isStarted }) else { return }
        locked { _reasons = [] }
        try startScreen()
        startInput()
        startAccessibility()
        startWorkspace()
        locked { _isStarted = true }
        publishDegradation()
    }

    func stop() {
        let (screen, input) = locked { () -> (SimulatorScreenSource?, SimulatorInputSink?) in
            let handles = (_screen, _input)
            _screen = nil
            _input = nil
            _accessibility = nil
            _workspace = nil
            _isStarted = false
            return handles
        }
        screen?.stop()
        input?.invalidate()
    }

    func captureCurrentFrame() -> SimulatorFrame? {
        screen?.captureCurrentFrame() ?? latestFrame
    }

    /// A frame only if the device is still there. `captureCurrentFrame()` deliberately keeps its
    /// fallback — a pane re-presenting the last good frame during a blip is right — but anything that
    /// hands a frame to someone else as *evidence* (a screenshot verb, a comment) must not, because
    /// the surface outlives the device and the stale frame is indistinguishable from a live one.
    func captureVerifiedFrame() throws -> SimulatorFrame? {
        try verifyDeviceAlive()
        return captureCurrentFrame()
    }

    private func note(_ reason: SimulatorSourceDegradation.Reason) {
        locked { _reasons.append(reason) }
    }

    private func startScreen() throws {
        let live = SimulatorFrameSource(udid: udid)
        do {
            try attach(live)
            return
        } catch {
            note(SimulatorSourceDegradation.Reason(
                capability: .screen,
                detail: Self.describe(error),
                fallback: "polling `simctl io screenshot`"))
        }
        let polling = SimctlScreenshotSource(udid: udid)
        do {
            try attach(polling)
        } catch {
            // Both paths are gone. Surface the *live* path's reason, not the fallback's: the live
            // failure says something actionable ("this device is not booted, so it publishes no
            // display"), where the fallback's is `simctl`'s own noise about writing a PNG. The
            // recorded reason was being thrown away here and the useless one propagated in its place.
            let live = locked { _reasons.last { $0.capability == .screen }?.detail }
            // "Not booted" is a symptom; the claim that tried to boot it knows the cause. Without
            // this the pane retries for ninety seconds and then reports the symptom on its own.
            let cause = SimulatorClaims.bootFailure(for: udid)
                .map { " Synth asked this device to boot and it did not: \($0)" } ?? ""
            throw SimulatorSourceFailure.screenUnavailable(
                live: (live ?? Self.describe(error)) + cause, fallback: Self.describe(error))
        }
    }

    private func attach(_ source: SimulatorScreenSource) throws {
        source.callbackQueue = callbackQueue
        source.onFrame = { [weak self] frame in
            guard let self else { return }
            latestFrame = frame
            onFrame?(frame)
        }
        source.onDisplaySizeChange = { [weak self] size in self?.onDisplaySizeChange?(size) }
        try source.start()
        locked { _screen = source }
    }

    /// Resolving the Indigo builders and the HID class is cheap and happens now, so a missing one
    /// is reported immediately. Opening the session costs ~1.2s, so that happens off this thread
    /// and can degrade the source a moment later.
    private func startInput() {
        let hid: SimulatorHID
        do {
            hid = try SimulatorHID(udid: udid)
        } catch {
            note(SimulatorSourceDegradation.Reason(
                capability: .input,
                detail: Self.describe(error),
                fallback: "input unavailable — `simctl` has no touch-injection verb at any version"))
            locked { _input = SimulatorUnavailableInput(detail: Self.describe(error)) }
            return
        }
        locked { _input = hid }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try hid.prepare()
            } catch {
                let detail = Self.describe(error)
                locked {
                    self._input = SimulatorUnavailableInput(detail: detail)
                    self._reasons.append(SimulatorSourceDegradation.Reason(
                        capability: .input,
                        detail: detail,
                        fallback: "input unavailable — the HID session would not open"))
                }
                publishDegradation()
            }
        }
    }

    /// Resolving the translator and the device handle is cheap; the guest's accessibility server
    /// takes ~1.2s to answer the first request, and that is paid by the first describe rather than
    /// by opening a pane. So unlike the HID session there is nothing to warm up here.
    private func startAccessibility() {
        do {
            let reader = try SimulatorAccessibility(udid: udid)
            locked { _accessibility = reader }
        } catch {
            let detail = Self.describe(error)
            note(SimulatorSourceDegradation.Reason(
                capability: .accessibility,
                detail: detail,
                fallback: "no accessibility tree — `simctl` has no verb that reads one"))
            let unavailable = SimulatorUnavailableAccessibility(
                detail: "Synth cannot read this device's accessibility tree: \(detail) "
                    + "There is no fallback: `simctl` has no accessibility verb at any version, so "
                    + "read the screen with simulator_screenshot instead.")
            locked { _accessibility = unavailable }
        }
    }

    /// Resolving the bootstrap-lookup and Darwin-notification selectors is two `respondsToSelector:`
    /// calls, so it is done now and reported now. The `PurpleWorkspacePort` lookup itself is *not*
    /// warmed here: the port belongs to the guest that published it, so it is looked up per send
    /// rather than cached into a rotation that goes nowhere after a reboot.
    private func startWorkspace() {
        do {
            let sender = try SimulatorPurpleEventSender(udid: udid)
            locked {
                _workspace = sender
                _workspaceFailure = nil
            }
        } catch {
            let detail = Self.describe(error)
            locked {
                _workspace = nil
                _workspaceFailure = detail
                _reasons.append(SimulatorSourceDegradation.Reason(
                    capability: .orientation,
                    detail: detail,
                    fallback: "cannot rotate or shake — `simctl` has no orientation verb at any "
                        + "version, and `devicectl device orientation set` needs Xcode 27"))
            }
        }
    }

    /// Publishes the current degradation and tells whoever is listening — **on `callbackQueue`**,
    /// never on the thread that noticed. Every caller but `start()` is off main: the HID session
    /// opens on a global queue, and `verifyDeviceAlive()` runs on the control connection's thread on
    /// the way to a screenshot. In the app this closure writes a `@MainActor @Observable` property,
    /// so firing it where it was noticed mutates the Observation registrar off main — and
    /// `swift-tools-version:5.10` has no runtime actor assertion to catch that, so it is silent.
    private func publishDegradation() {
        let (queue, callback, degradation) = locked {
            () -> (DispatchQueue, ((SimulatorSourceDegradation?) -> Void)?, SimulatorSourceDegradation?) in
            _degradation = _reasons.isEmpty ? nil : SimulatorSourceDegradation(reasons: _reasons)
            return (_callbackQueue, _onDegradationChange, _degradation)
        }
        guard let callback else { return }
        queue.async { callback(degradation) }
    }

    /// The engine's failures are all `CustomStringConvertible`, which `String(describing:)` honours;
    /// anything else falls back to its localized description rather than a mangled case name.
    private static func describe(_ error: Error) -> String {
        error is CustomStringConvertible ? String(describing: error) : error.localizedDescription
    }

    // MARK: Input

    /// Whether the device is still there, asked of CoreSimulator rather than inferred from frames.
    /// Silence is NOT death: the cadence is damage-driven, so a static screen legitimately produces
    /// no frames for minutes. And the retained IOSurface stays mapped in our process after the device
    /// goes away, so `captureCurrentFrame()` keeps succeeding with the last screen a device that no
    /// longer exists was showing — which is how a screenshot verb ends up reporting a lie.
    ///
    /// One XPC round trip, asked only where being wrong matters: before handing a frame out as
    /// current. Publishes the loss as degradation so the pane stops claiming to be attached.
    /// As `verifyDeviceAlive()`, but at most once every 250 ms while it keeps succeeding. Input runs
    /// at pointer rate — a drag is sixty moves a second — and an XPC round trip per move would be a
    /// real cost for a fact that cannot change between two frames. A *failure* is never cached: the
    /// next verb re-asks, so recovery is immediate.
    func verifyDeviceAliveCached() throws {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        if let last = locked({ _lastAliveCheck }), now &- last < 250_000_000 { return }
        try verifyDeviceAlive()
        locked { _lastAliveCheck = now }
    }

    func verifyDeviceAlive() throws {
        do {
            _ = try SimulatorPrivateRuntime.bootedDevice(udid: udid)
        } catch {
            let detail = Self.describe(error)
            let isNew = locked { () -> Bool in
                guard !_reasons.contains(where: { $0.capability == .screen && $0.detail == detail })
                else { return false }
                _reasons.append(SimulatorSourceDegradation.Reason(
                    capability: .screen, detail: detail,
                    fallback: "nothing — the device is gone, so there is no screen to read"))
                return true
            }
            if isNew { publishDegradation() }
            throw error
        }
    }

    private func requireInput() throws -> SimulatorInputSink {
        guard let input = locked({ _input }) else {
            throw SimulatorHIDFailure.clientUnavailable("this simulator source is not started")
        }
        return input
    }

    func tap(at point: CGPoint) throws {
        try verifyDeviceAliveCached()
        try requireInput().tap(at: point)
    }

    func touchDown(at point: CGPoint) throws {
        try verifyDeviceAliveCached()
        try requireInput().touchDown(at: point)
    }

    func touchMove(to point: CGPoint) throws {
        try verifyDeviceAliveCached()
        try requireInput().touchMove(to: point)
    }

    func touchUp(at point: CGPoint) throws {
        try verifyDeviceAliveCached()
        try requireInput().touchUp(at: point)
    }

    func press(_ button: SimulatorHardwareButton) throws {
        try verifyDeviceAliveCached()
        try requireInput().press(button)
    }

    func type(text: String) throws {
        try verifyDeviceAliveCached()
        try requireInput().type(text: text)
    }

    // MARK: Orientation

    func setOrientation(_ orientation: SimulatorOrientation) throws {
        try requireWorkspace().setOrientation(orientation)
        let (queue, callback, accessibility) = locked {
            () -> (DispatchQueue, ((SimulatorOrientation) -> Void)?, SimulatorAccessibilityReader?) in
            _orientation = orientation
            return (_callbackQueue, _onOrientationChange, _accessibility)
        }
        // The accessibility tree normalises against the interface's size, which just transposed.
        accessibility?.orientation = orientation
        queue.async { callback?(orientation) }
    }

    /// Rotate without making the caller wait. The verb above stays throwing because that is the
    /// contract every input verb here has, and the agent calls it from the control connection's own
    /// thread where blocking is free — but the pane's button is on the main actor, and a send is a
    /// bootstrap lookup plus a `mach_msg` bounded at two seconds. Paying that on main would freeze
    /// the window, the user's terminals included, for the length of a wedged guest.
    func setOrientation(
        _ orientation: SimulatorOrientation, reportingFailureTo report: @escaping (String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try setOrientation(orientation)
            } catch {
                let detail = Self.describe(error)
                callbackQueue.async { report(detail) }
            }
        }
    }

    func shake() throws {
        try requireWorkspace().post(.shake)
    }

    private func requireWorkspace() throws -> SimulatorPurpleEventSender {
        let (workspace, failure) = locked { (_workspace, _workspaceFailure) }
        guard let workspace else {
            throw SimulatorOrientationFailure.unavailable(
                failure ?? "this simulator source is not started, so no device is attached")
        }
        return workspace
    }

    // MARK: Accessibility

    func describeAccessibility() throws -> SimulatorAccessibilityTree {
        try verifyDeviceAlive()
        return try reader().describeFrontmostApplication()
    }

    func describeAccessibility(at point: CGPoint) throws -> SimulatorAccessibilityTree {
        try verifyDeviceAlive()
        return try reader().describe(at: point)
    }

    private func reader() throws -> SimulatorAccessibilityReader {
        guard let accessibility = locked({ _accessibility }) else {
            throw SimulatorAccessibilityFailure.unavailable(
                "the simulator source has not been started, so no device is attached")
        }
        return accessibility
    }

    // MARK: simctl verbs

    func launch(bundleIdentifier: String) throws {
        try SimulatorDeviceCatalog.launch(udid: udid, bundleIdentifier: bundleIdentifier)
    }

    func open(url: String) throws {
        try SimulatorDeviceCatalog.open(udid: udid, url: url)
    }

    func install(appAtPath path: String) throws {
        try SimulatorDeviceCatalog.install(udid: udid, appPath: path)
    }
}

// MARK: - Degraded screen

/// The degraded screen: `simctl io screenshot` on a timer, decoded into the same `CVPixelBuffer`
/// the live path produces, so the pane's presentation code is identical either way. Frames are
/// deduped on the PNG's bytes — a static screen costs one process spawn per poll and no frames.
///
/// This is not a live mirror and does not pretend to be: a screenshot costs a few hundred
/// milliseconds, so the poll interval is the frame rate.
final class SimctlScreenshotSource: SimulatorScreenSource {

    let udid: String

    // Same rule as the live path, for the same reason: the poll queue produces frames and mutates
    // the digest, the size and the statistics, while the owner reads `displaySize` and `statistics`
    // on main and sets the callbacks there. `statistics` owns two arrays, so recording a frame while
    // the pane reads its summary races on their buffers. All of it goes through `stateLock`.
    private let stateLock = NSLock()
    private var _callbackQueue: DispatchQueue = .main
    private var _onFrame: ((SimulatorFrame) -> Void)?
    private var _onDisplaySizeChange: ((CGSize) -> Void)?
    private var _displaySize: CGSize = .zero
    private var _statistics = SimulatorFrameStatistics()

    private func locked<Value>(_ body: () -> Value) -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    var callbackQueue: DispatchQueue {
        get { locked { _callbackQueue } }
        set { locked { _callbackQueue = newValue } }
    }

    var onFrame: ((SimulatorFrame) -> Void)? {
        get { locked { _onFrame } }
        set { locked { _onFrame = newValue } }
    }

    var onDisplaySizeChange: ((CGSize) -> Void)? {
        get { locked { _onDisplaySizeChange } }
        set { locked { _onDisplaySizeChange = newValue } }
    }

    var displaySize: CGSize { locked { _displaySize } }
    var statistics: SimulatorFrameStatistics { locked { _statistics } }

    /// How often a screenshot is taken while the screen is changing. A `simctl io screenshot` round
    /// trip is a process spawn plus a PNG encode, so anything faster just queues.
    var pollInterval: TimeInterval = 0.5
    /// The slowest it backs off to. A degraded session used to spawn a process every 500 ms for the
    /// life of the app whether or not anything was happening — per session, forever. The live path
    /// costs nothing on a static screen because it is damage-driven; the fallback has to approximate
    /// that by noticing when it is wasting the spawns.
    var maxPollInterval: TimeInterval = 4.0

    private let queue = DispatchQueue(label: "com.synth.simulator.screenshots", qos: .utility)
    /// Created by the owner and read by `reschedule` on `queue`, so it is locked like everything
    /// else that holds an object across threads.
    private var _timer: DispatchSourceTimer?
    /// `queue`-confined: the poll's own bookkeeping, never read from anywhere else.
    private var currentInterval: TimeInterval = 0
    /// SHA-256 of the last PNG. Not `Data.hashValue`: that is a seeded hash over a *sample* of a
    /// large buffer, and buffers differing in the middle or in the final byte were measured to hash
    /// equal — so the real discriminator was byte count, and an equal-length screenshot of a changed
    /// screen got dropped as a duplicate. A degraded pane that silently misses changes is worse than
    /// a slow one.
    private var lastDigest: Data?
    private var frameIndex: UInt64 = 0
    private var lastProductionTime: UInt64 = 0
    /// Consecutive polls that found nothing new, which is what the backoff is keyed off.
    private var unchangedPolls = 0

    init(udid: String) {
        self.udid = udid
        // Known before the first screenshot lands, so the pane can lay out immediately.
        _displaySize = (try? SimulatorDeviceCatalog.device(udid: udid))?.screenPixelSize ?? .zero
    }

    deinit { stop() }

    func start() throws {
        // Fail now rather than silently polling a device that will never answer.
        _ = try SimulatorDeviceCatalog.screenshotPNG(udid: udid)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        locked { _timer = timer }
        queue.async { [weak self] in self?.currentInterval = self?.pollInterval ?? 0 }
        timer.resume()
    }

    func stop() {
        let timer = locked { () -> DispatchSourceTimer? in
            let running = _timer
            _timer = nil
            return running
        }
        timer?.cancel()
    }

    func captureCurrentFrame() -> SimulatorFrame? {
        queue.sync { makeFrame(force: true) }
    }

    private func poll() {
        // Nobody is observing — the pane is closed or was never bound — so there is nothing for a
        // spawn to be for.
        guard onFrame != nil else {
            reschedule(interval: maxPollInterval)
            return
        }
        guard let frame = makeFrame(force: false) else {
            unchangedPolls += 1
            // Doubling from the base interval, capped: a screen that has been still for a few
            // seconds is usually still for a while.
            let backed = min(maxPollInterval, pollInterval * pow(2, Double(min(unchangedPolls, 4))))
            reschedule(interval: backed)
            return
        }
        if unchangedPolls > 0 {
            unchangedPolls = 0
            reschedule(interval: pollInterval)
        }
        let (queue, callback) = locked { (_callbackQueue, _onFrame) }
        queue.async { callback?(frame) }
    }

    /// Re-arm the timer at a new cadence. Only when it actually changes, so a steady screen is not
    /// re-scheduling every tick.
    private func reschedule(interval: TimeInterval) {
        guard interval != currentInterval else { return }
        currentInterval = interval
        locked { _timer }?.schedule(deadline: .now() + interval, repeating: interval)
    }

    private func makeFrame(force: Bool) -> SimulatorFrame? {
        guard let png = try? SimulatorDeviceCatalog.screenshotPNG(udid: udid) else { return nil }
        let digest = Data(SHA256.hash(data: png))
        if !force, digest == lastDigest { return nil }

        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        guard let buffer = Self.pixelBuffer(fromPNG: png) else { return nil }
        let end = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

        lastDigest = digest
        frameIndex += 1
        let gap = lastProductionTime == 0 ? nil : start - lastProductionTime
        lastProductionTime = start

        let size = CGSize(
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let resized = locked { () -> (DispatchQueue, ((CGSize) -> Void)?)? in
            _statistics.record(gap: gap, cost: end - start, torn: false)
            guard size != _displaySize else { return nil }
            _displaySize = size
            return (_callbackQueue, _onDisplaySizeChange)
        }
        if let (queue, callback) = resized { queue.async { callback?(size) } }
        return SimulatorFrame(
            pixelBuffer: buffer, pixelSize: size, seed: digest.prefix(4).reduce(UInt32(0)) {
                $0 << 8 | UInt32($1)
            },
            isTorn: false, index: frameIndex, producedAt: start)
    }

    private static func pixelBuffer(fromPNG data: Data) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            // IOSurface-backed, so the same AVSampleBufferDisplayLayer path works unchanged.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

// MARK: - Degraded input

/// Input in degraded mode. There is no `simctl` touch-injection verb at any version, so every verb
/// here is a refusal that carries the reason — the honest answer, rather than a silent no-op that
/// makes the device look broken.
final class SimulatorUnavailableInput: SimulatorInputSink {
    let detail: String

    init(detail: String) {
        self.detail = detail
    }

    func prepare() throws { throw SimulatorHIDFailure.clientUnavailable(detail) }
    func invalidate() {}
    func tap(at point: CGPoint) throws { throw SimulatorHIDFailure.clientUnavailable(detail) }
    func touchDown(at point: CGPoint) throws { throw SimulatorHIDFailure.clientUnavailable(detail) }
    func touchMove(to point: CGPoint) throws { throw SimulatorHIDFailure.clientUnavailable(detail) }
    func touchUp(at point: CGPoint) throws { throw SimulatorHIDFailure.clientUnavailable(detail) }
    func press(_ button: SimulatorHardwareButton) throws {
        throw SimulatorHIDFailure.clientUnavailable(detail)
    }
    func type(text: String) throws { throw SimulatorHIDFailure.clientUnavailable(detail) }
}

extension SimulatorHID: SimulatorInputSink {
    func prepare() throws { _ = try openSession() }

    /// The throwing face of the sink: refuse if there is no session or if a send already reported a
    /// failure, then issue. `SimulatorHID`'s own verbs stay non-throwing because they are also the
    /// coalesced fast path a drag uses.
    func tap(at point: CGPoint) throws { try checkReady(); tapNow(at: point) }
    func touchDown(at point: CGPoint) throws { try checkReady(); touchDownNow(at: point) }
    func touchMove(to point: CGPoint) throws { try checkReady(); touchMoveNow(to: point) }
    func touchUp(at point: CGPoint) throws { try checkReady(); touchUpNow(at: point) }
    func press(_ button: SimulatorHardwareButton) throws { try checkReady(); pressNow(button) }
    // `type` had its own path and no readiness check, so it answered ok four times out of four
    // against a shut-down device — the one verb each earlier round's fix missed.
    func type(text: String) throws { try checkReady(); try typeNow(text: text) }
}
