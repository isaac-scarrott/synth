import AVFoundation
import AppKit
import SwiftUI

// The simulator session's pane (ADR-0015). The live framebuffer goes on the glass of the same
// drawn hardware frame the browser's device mode uses, and the pointer that lands on it becomes an
// Indigo touch on the device — the same message Claude's tool calls send, which is what makes the
// agent and the user share one surface rather than two.
//
// Engine ownership lives outside SwiftUI in `SimulatorManager`, exactly as the browser's lives in
// `BrowserManager`: a pane view is recreated on every layout change and must not own a device.

// MARK: - Manager

/// Owns one live source per simulator session. The `BrowserManager` twin.
@MainActor
final class SimulatorManager {
    static let shared = SimulatorManager()

    private var controllers: [UUID: SimulatorSessionController] = [:]
    /// Sessions whose source failed to start, so a re-render doesn't retry in a tight loop.
    private var dead: Set<UUID> = []

    func controller(for session: Session) -> SimulatorSessionController? {
        if let existing = controllers[session.id] { return existing }
        guard let udid = session.simulatorUDID, !dead.contains(session.id) else { return nil }
        let controller = SimulatorSessionController(sessionID: session.id, udid: udid)
        controllers[session.id] = controller
        controller.start()
        // A controller still waiting for its device to boot is not dead — tombstoning it here is
        // what turned a boot race into a permanently unattached pane.
        if controller.startFailure != nil, !controller.isAwaitingBoot { dead.insert(session.id) }
        return controller
    }

    func existing(_ sessionID: UUID) -> SimulatorSessionController? { controllers[sessionID] }

    /// Called when a session's device changes, so the next render builds a fresh source.
    func reset(_ sessionID: UUID) {
        controllers.removeValue(forKey: sessionID)?.stop()
        dead.remove(sessionID)
    }

    func terminate(_ sessionID: UUID) {
        controllers.removeValue(forKey: sessionID)?.stop()
        dead.remove(sessionID)
    }

    /// Quit. Every controller stops, and every device Synth booted is shut down **synchronously**,
    /// because quitting does not route through `closeSession` and a detached task does not outlive
    /// the process. Without this, quitting Synth with a simulator row open left a booted device
    /// behind — well over a gigabyte and dozens of processes each — with nothing in any UI to say so.
    ///
    /// Only devices Synth booted. A controller is *not* the test for that — a row attached to a
    /// device the user already had running has one too — so the decision goes through
    /// `SimulatorClaims`, which only knows about devices a Synth boot turned on.
    func shutdownAll() {
        let held = Set(controllers.values.map(\.udid))
        let ours = held.filter(SimulatorClaims.synthBooted)
        NSLog("Synth: simulator shutdownAll — %d controller(s), %d device(s) to release, "
              + "%d left booted (Synth did not start them)",
              controllers.count, ours.count, held.count - ours.count)
        for (_, controller) in controllers { controller.stop() }
        controllers.removeAll()
        dead.removeAll()
        for udid in held { SimulatorCatalogFleet.releaseSynchronously(udid) }
    }
}

// MARK: - Controller

/// What the bar's last action did, shown in the pane's notice strip until it is superseded.
struct SimulatorActionNotice: Equatable {
    var text: String
    var isError: Bool
}

/// Pane-local, high-frequency state for one simulator session. Frames never travel through the
/// store: they go straight to the layer, and only facts the rest of the app needs live here.
@MainActor
@Observable
final class SimulatorSessionController {
    let sessionID: UUID
    let udid: String

    private(set) var device: HardwareDevice = .forSimulator()
    /// The device as the *cached* fleet knows it. Never re-read from `simctl` on the main actor:
    /// enumerating the fleet costs three subprocess spawns plus a plist read per installed device,
    /// and this is read on every attach and every retry tick while a device boots. That cost landing
    /// on the main actor is what stalled the user's terminals for the length of a boot.
    private(set) var deviceInfo: SimulatorDevice?
    private(set) var degradation: SimulatorSourceDegradation?
    private(set) var startFailure: String?
    private(set) var hasFrame = false
    /// The device is still booting, so "not attached" is a stage rather than a fault.
    private(set) var isAwaitingBoot = false
    /// The orientation Synth last set on this device. Mirrored out of the source so SwiftUI observes
    /// it, and driven by the agent's `simulator.rotate` as well as by the pane's own button.
    private(set) var orientation: SimulatorOrientation = .portrait
    /// The last refused input, shown until it is superseded or cleared.
    private(set) var inputFailure: String?

    private static let maxAttempts = 90
    private var attempts = 0
    private var retryTask: Task<Void, Never>?

    /// The AppKit view that presents frames and turns the pointer into touches.
    let screenView: SimulatorScreenView

    /// Not private: the agent's `simulator.*` control verbs drive this exact source, off the main
    /// thread (SimulatorControl). One source per session row is the shared-surface guarantee —
    /// a tap from a tool call and a tap from the pointer are the same Indigo message.
    let source: SimulatorDeviceSource

    /// ADR-0011 stage three for this pane. Held here rather than in the view because a pane is
    /// rebuilt on every layout change and a half-written comment must survive that.
    let commentMode: SimulatorCommentModeController

    init(sessionID: UUID, udid: String) {
        self.sessionID = sessionID
        self.udid = udid
        self.source = SimulatorDeviceSource(udid: udid)
        self.screenView = SimulatorScreenView()
        self.commentMode = SimulatorCommentModeController(
            sessionID: sessionID, store: AppStore.shared)
        self.screenView.source = source

        // Resolve the drawn hardware from what the device says it is, not from the session's name.
        refreshDeviceInfo()
    }

    /// A hardware button from the pane's own chrome, reported the same way the screen's inputs are.
    func press(_ button: SimulatorHardwareButton) {
        do {
            try source.press(button)
            inputFailure = nil
        } catch {
            noteInputFailure("\(error)")
        }
    }

    /// Turns the device between portrait and landscape. The send happens off the main actor (the
    /// source owns that hop) and a refusal comes back through the same notice a refused tap uses.
    func rotate() {
        source.setOrientation(orientation.toggled) { [weak self] detail in
            Task { @MainActor in self?.noteInputFailure(detail) }
        }
    }

    // MARK: The app the device is running

    /// What the identity field names: the last thing Synth opened here, bundle id or URL. Nil is
    /// the field's placeholder — Synth cannot ask a device what is frontmost, so this is a record
    /// of what we did rather than a claim about what is on screen.
    private(set) var runningAppLabel: String?
    /// Only a bundle id can be relaunched; a URL names a destination, not a process to terminate.
    private(set) var runningBundleIdentifier: String?
    /// Whether the launcher drop is up. On the controller, like comment mode, because a pane is
    /// rebuilt on every layout change and a half-typed bundle id must survive that.
    var launcherOpen = false
    /// What `simctl listapps` last said is on the device. Loaded when the launcher opens and kept,
    /// so reopening it is instant and a device that answers slowly does not blank the list.
    private(set) var installedApps: [SimulatorInstalledApp] = []
    /// The result of the last thing the bar did — a launch, a shake, a copied screenshot — or the
    /// error it failed with. Auto-clears, like a refused input.
    private(set) var actionNotice: SimulatorActionNotice?

    /// What ⌘L presses. The drop is the pane's, but the state it reads is here.
    func openAppLauncher() {
        launcherOpen = true
        loadInstalledApps()
    }

    /// Off the main actor: `simctl listapps` spawns a process and prints a plist of every app on
    /// the device, and paying that on main freezes the window — the user's terminals included.
    private func loadInstalledApps() {
        let udid = self.udid
        Task.detached(priority: .userInitiated) {
            guard let apps = try? SimulatorDeviceCatalog.installedApps(udid: udid) else { return }
            await MainActor.run { self.installedApps = apps }
        }
    }

    /// The launcher's submit and its rows: a URL is opened, anything else is launched by bundle id.
    func open(_ text: String) {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        let isURL = target.contains("://")
        let source = self.source
        Task.detached(priority: .userInitiated) {
            do {
                if isURL { try source.open(url: target) }
                else { try source.launch(bundleIdentifier: target) }
                await MainActor.run { self.recordLaunch(of: target, isBundleIdentifier: !isURL) }
            } catch {
                await MainActor.run { self.note("\(error)", isError: true) }
            }
        }
    }

    /// Terminate and launch again — the "I just rebuilt it" verb, which a plain launch does not do:
    /// `simctl launch` on an app that is already frontmost is a no-op with a pid.
    func relaunch() {
        guard let bundleIdentifier = runningBundleIdentifier else {
            note("Nothing has been launched from here yet.", isError: false)
            return
        }
        let udid = self.udid
        Task.detached(priority: .userInitiated) {
            // A terminate of an app that is not running is not a failure of the relaunch, which is
            // the whole verb — so only the launch decides what the user is told.
            try? SimulatorDeviceCatalog.terminate(udid: udid, bundleIdentifier: bundleIdentifier)
            do {
                try SimulatorDeviceCatalog.launch(udid: udid, bundleIdentifier: bundleIdentifier)
                await MainActor.run {
                    self.note("Relaunched \(self.displayName(of: bundleIdentifier))", isError: false)
                }
            } catch {
                await MainActor.run { self.note("\(error)", isError: true) }
            }
        }
    }

    /// The gesture there is no pointer equivalent of. Off the main actor for the same reason rotate
    /// is: the send is a bootstrap lookup plus a bounded `mach_msg`.
    func shake() {
        let source = self.source
        Task.detached(priority: .userInitiated) {
            do {
                try source.shake()
                await MainActor.run { self.note("Shook the device", isError: false) }
            } catch {
                await MainActor.run { self.note("\(error)", isError: true) }
            }
        }
    }

    /// The screen on the pasteboard. The same capture the agent's `simulator.screenshot` verb uses,
    /// including its fallback: a pixel format we cannot read is a reason to spawn `simctl io
    /// screenshot`, not a reason to hand back nothing.
    func copyScreenshot() {
        let source = self.source
        let udid = self.udid
        Task.detached(priority: .userInitiated) {
            let png = (try? source.captureVerifiedFrame())??.pngByCopyingPixels()
                ?? (try? SimulatorDeviceCatalog.screenshotPNG(udid: udid))
            await MainActor.run {
                guard let png else {
                    self.note("The device produced no frame to copy.", isError: true)
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
                self.note("Screenshot copied", isError: false)
            }
        }
    }

    private func recordLaunch(of target: String, isBundleIdentifier: Bool) {
        runningAppLabel = target
        runningBundleIdentifier = isBundleIdentifier ? target : nil
        note("Launched \(displayName(of: target))", isError: false)
    }

    /// What the home screen calls it, when the device has told us — a bundle id is what the field
    /// says, but "Launched com.apple.Preferences" is a worse sentence than "Launched Settings".
    private func displayName(of bundleIdentifier: String) -> String {
        installedApps.first { $0.bundleIdentifier == bundleIdentifier }?.name ?? bundleIdentifier
    }

    private func note(_ text: String, isError: Bool) {
        actionNotice = SimulatorActionNotice(text: text, isError: isError)
        let generation = UUID()
        noticeGeneration = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.noticeGeneration == generation else { return }
            self.actionNotice = nil
        }
    }

    private var noticeGeneration = UUID()

    private func noteInputFailure(_ detail: String) {
        inputFailure = detail
        let generation = UUID()
        failureGeneration = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.failureGeneration == generation else { return }
            self.inputFailure = nil
        }
    }

    private var failureGeneration = UUID()

    func start() {
        screenView.onInputFailure = { [weak self] detail in self?.noteInputFailure(detail) }
        screenView.onCommentClick = { [weak self] point in
            guard let self else { return }
            self.commentMode.select(at: point, in: self.source)
        }
        source.callbackQueue = .main
        source.onFrame = { [weak self] frame in
            guard let self else { return }
            self.screenView.present(frame)
            if !self.hasFrame { self.hasFrame = true }
        }
        source.onDisplaySizeChange = { [weak self] size in
            guard let self, let info = self.deviceInfo else { return }
            self.device = .forSimulator(modelIdentifier: info.modelIdentifier, name: info.name,
                                        pixelSize: size, scale: info.screenScale.map(Double.init))
            self.lastKnownPixelSize = size
        }
        source.onDegradationChange = { [weak self] degradation in
            self?.degradation = degradation
        }
        // The agent's rotate verb and the pane's button come through here alike, which is what keeps
        // one drawn frame honest about one device.
        source.onOrientationChange = { [weak self] orientation in
            guard let self else { return }
            self.orientation = orientation
            self.screenView.orientation = orientation
        }
        // A restored session holds a UDID but no claim — nothing has booted its device, and
        // `newSimulator`'s claim is long gone with the process that made it. Opening the pane is
        // what puts a session back on a device, so claim unconditionally: claiming is
        // boot-if-shutdown and idempotent, so a device already up costs nothing.
        //
        // Deliberately NOT gated on `isBooted`. That reads the fleet cache, and a cache that is
        // briefly stale in the "booted" direction would skip the claim entirely — so nothing would
        // ever boot the device, the pane would retry for ninety seconds and then report a device
        // that was never asked to start. A stale cache is fine for deciding what to *tell* the user;
        // it is not fine for deciding whether to act.
        Simulators.fleet.claim(udid)
        attach()
        awaitDeviceInfo()
    }

    /// Claiming a device boots it, and a boot takes seconds — so the first attach routinely races
    /// it. An unbooted device publishes no display, which reads as "the live path is unavailable"
    /// and degrades a session that would have worked a moment later, permanently. So attaching
    /// retries while the device is still on its way up, and only what is still wrong once it is
    /// booted counts as degradation the user needs to see.
    private func attach() {
        retryTask?.cancel()
        startFailure = nil
        do {
            try source.start()
            degradation = source.degradation
            if let frame = source.captureCurrentFrame() {
                screenView.present(frame)
                hasFrame = true
            }
        } catch {
            startFailure = "\(error)"
        }

        let settled = startFailure == nil && degradation?.affectsScreen != true
        // "Booted" is a device state, not a promise that the display is publishing yet: the
        // framebuffer arrives a moment later. So boot state decides what the user is *told* — a
        // device on its way up, or a real failure — and never whether to stop trying. Treating it
        // as a stop condition let one unlucky attempt at the boot boundary degrade the pane for good.
        isAwaitingBoot = !settled && !isBooted
        guard !settled, attempts < Self.maxAttempts else { return }
        attempts += 1
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.source.stop()
            self.refreshDeviceInfo()
            self.attach()
        }
    }

    /// From the cache, so a retry tick costs nothing. A tick that is a fraction of a second stale
    /// only ever means one more retry, which is the cheap direction to be wrong in.
    private var isBooted: Bool { Simulators.fleet.device(udid: udid)?.isBooted ?? false }

    private var lastKnownPixelSize: CGSize?

    /// The fleet's listing is refreshed in the background, so a session opened in the first moment
    /// after launch resolves to nothing at all. An attach that settles first time never comes back
    /// through the retry loop, so without this the pane keeps that empty answer for its whole life —
    /// and with the device's name gone from the bar, the badge's runtime is the only thing left
    /// saying which iOS this is.
    private func awaitDeviceInfo() {
        guard deviceInfo == nil else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.deviceInfo == nil else { return }
                self.refreshDeviceInfo()
            }
        }
    }

    /// A device's reported screen only firms up once it is booted, so re-resolve the drawn
    /// hardware on the way through a retry.
    private func refreshDeviceInfo() {
        guard let info = Simulators.fleet.device(udid: udid) else { return }
        deviceInfo = info
        device = .forSimulator(modelIdentifier: info.modelIdentifier, name: info.name,
                               pixelSize: lastKnownPixelSize ?? info.screenPixelSize,
                               scale: info.screenScale.map(Double.init))
    }

    func stop() {
        // Comment mode holds a composer's screenshots until they are sent or cancelled. Without this
        // its `teardown()` had no caller at all, so closing a session with a composer open left the
        // PNGs in Application Support for good — unbounded over a working day.
        commentMode.teardown()
        retryTask?.cancel()
        retryTask = nil
        source.onFrame = nil
        source.onDisplaySizeChange = nil
        source.onDegradationChange = nil
        source.onOrientationChange = nil
        source.stop()
    }
}

// MARK: - The screen

/// Presents frames and forwards input. An `AVSampleBufferDisplayLayer` rather than
/// `layer.contents = ioSurface`, which does not re-composite when the surface mutates (ADR-0015).
final class SimulatorScreenView: NSView {
    weak var source: SimulatorDeviceSource?
    /// Where a refused input goes. Input can fail for reasons the user needs to hear — the device
    /// was shut down underneath the pane, the HID session never opened on this Xcode — and a pane
    /// that swallows them looks broken instead of saying what happened.
    var onInputFailure: ((String) -> Void)?
    /// How the device is turned. The framebuffer never rotates (ADR-0015) — the guest draws its
    /// landscape interface sideways into the same portrait surface — so turning the picture upright
    /// is this view's job, and so is turning the pointer back the other way before it reaches Indigo.
    var orientation: SimulatorOrientation = .portrait {
        didSet {
            guard orientation != oldValue else { return }
            needsLayout = true
        }
    }
    private let display = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Black, not the frame's white glass: a device that has not produced its first frame
        // should read as a screen that is off, not as a blank page.
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(display)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Lays the display layer out and turns it.
    ///
    /// The layer keeps the *framebuffer's* aspect — portrait bounds, so `videoGravity` still fits the
    /// picture without letterboxing it — and a rotation carries it into the view's landscape bounds.
    /// Rotating the layer rather than the sample buffers is what keeps this free: no re-encode, no
    /// second copy, and `AVSampleBufferDisplayLayer` composites the transform on the GPU.
    ///
    /// A layer of an unflipped `NSView` has y pointing up, where a positive rotation is
    /// anticlockwise — so the clockwise turns the picture needs are negative here.
    override func layout() {
        super.layout()
        let turns = orientation.clockwiseQuarterTurns
        let unrotated = turns % 2 == 0
            ? bounds.size
            : CGSize(width: bounds.height, height: bounds.width)
        display.bounds = CGRect(origin: .zero, size: unrotated)
        display.position = CGPoint(x: bounds.midX, y: bounds.midY)
        display.transform = CATransform3DMakeRotation(
            -CGFloat(turns) * .pi / 2, 0, 0, 1)
    }

    func present(_ frame: SimulatorFrame) {
        guard let sample = frame.makeSampleBuffer() else { return }
        if #available(macOS 11.0, *), display.requiresFlushToResumeDecoding { display.flush() }
        display.enqueue(sample)
    }

    /// Whether the layer is accepting what we hand it. A malformed `CMSampleBuffer` is rejected
    /// silently and shows as a black screen indistinguishable from a device that has not drawn yet,
    /// so the self-check asserts on this rather than on pixels it cannot capture.
    var presentationFailure: String? {
        if display.status == .failed {
            return display.error.map { "\($0)" } ?? "AVSampleBufferDisplayLayer failed"
        }
        return nil
    }
    var presentationStatus: String {
        switch display.status {
        case .unknown: return "unknown"
        case .rendering: return "rendering"
        case .failed: return "failed"
        @unknown default: return "unrecognised"
        }
    }

    // MARK: input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where in the picture the pointer is: 0..1 from the top-left of what the user can see, which is
    /// upright whichever way the device is turned. Everything below works in this space and converts
    /// to the display's own only at the point of sending, so a drag reads the same in both
    /// orientations.
    private func upright(_ event: NSEvent) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x / bounds.width, 0), 1),
                       // AppKit measures y from the bottom; the device measures from the top.
                       y: min(max(1 - (p.y / bounds.height), 0), 1))
    }

    /// The point Indigo takes. The digitizer is bolted to the physical screen and does not rotate
    /// with the interface, so a tap in a landscape pane has to be turned back a quarter before it is
    /// sent — without this it lands a plausible 90° away, which reads as a device ignoring taps.
    private func device(_ point: CGPoint) -> CGPoint {
        orientation.displayPoint(fromUpright: point)
    }

    /// Issue an input, and report it if the device refuses. Coalesced to one notice per failure
    /// rather than one per event, because a dragging finger would otherwise raise sixty a second.
    private func send(_ action: () throws -> Void) {
        do { try action() } catch { onInputFailure?("\(error)") }
    }

    /// While comment mode is on, the pointer picks a target instead of touching the device — the
    /// device sees nothing at all, which is the point: a comment about a screen that changed because
    /// you clicked it to comment on it is worth nothing.
    var commentModeActive = false
    var onCommentClick: ((CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let p = upright(event), let source else { return }
        if commentModeActive {
            onCommentClick?(device(p))
            return
        }
        send { try source.touchDown(at: device(p)) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = upright(event), let source, !commentModeActive else { return }
        send { try source.touchMove(to: device(p)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = upright(event), let source, !commentModeActive else { return }
        send { try source.touchUp(at: device(p)) }
    }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.characters, !characters.isEmpty, let source,
              !commentModeActive else {
            super.keyDown(with: event)
            return
        }
        send { try source.type(text: characters) }
    }

    /// Trackpad and wheel scrolling, as a touch drag rather than a scroll event. The guest
    /// interprets a drag as a swipe natively, which is both simpler and more responsive than
    /// synthesising a gesture — and a trackpad's phases map onto down/move/up exactly.
    /// Deltas accumulate into a running finger position so a long scroll is one continuous touch,
    /// not a burst of taps, and each frame's moves are coalesced into a single message.
    private var scrollAnchor: CGPoint?

    override func scrollWheel(with event: NSEvent) {
        guard let source, bounds.width > 0, bounds.height > 0, !commentModeActive else { return }
        let dx = event.scrollingDeltaX / bounds.width
        let dy = event.scrollingDeltaY / bounds.height

        switch event.phase {
        case .began:
            guard let start = upright(event) else { return }
            scrollAnchor = start
            send { try source.touchDown(at: device(start)) }
        case .changed:
            guard var point = scrollAnchor else { return }
            // The finger moves WITH the delta, in both axes. AppKit reports `scrollingDeltaY > 0`
            // when the content should move down — which on a touchscreen is a finger moving down —
            // so this adds rather than subtracts. It subtracted at first, which inverts scrolling:
            // invisible reading the code, immediately wrong in the hand, and exactly what the
            // self-check's scroll assertion exists to catch.
            point.x = min(max(point.x + dx, 0), 1)
            point.y = min(max(point.y + dy, 0), 1)
            scrollAnchor = point
            send { try source.touchMove(to: device(point)) }
        case .ended, .cancelled:
            if let point = scrollAnchor { send { try source.touchUp(at: device(point)) } }
            scrollAnchor = nil
        default:
            // A legacy wheel (or momentum) reports no phase: flick it as a short discrete drag.
            guard scrollAnchor == nil, event.momentumPhase == [],
                  let start = upright(event), dx != 0 || dy != 0 else { return }
            let end = CGPoint(x: min(max(start.x + dx * 4, 0), 1),
                              y: min(max(start.y + dy * 4, 0), 1))
            send {
                try source.touchDown(at: device(start))
                try source.touchMove(to: device(end))
                try source.touchUp(at: device(end))
            }
        }
    }
}

// MARK: - Pane

struct SimulatorPane: View {
    let session: Session
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if session.simulatorUDID == nil {
                SimulatorDevicePicker(session: session)
                    .padding(14)
            } else if let controller = SimulatorManager.shared.controller(for: session) {
                stage(controller)
            } else {
                SimulatorNotice(text: "This simulator's device is no longer available.",
                                isError: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
            }
        }
        // `.pane-surface`, the browser's card exactly: the bar is flush against its top edge, so
        // the two surfaces read as siblings rather than as one framed strip and one floating one.
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.borderStrong, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 14))
    }

    @ViewBuilder
    private func stage(_ controller: SimulatorSessionController) -> some View {
        VStack(spacing: 0) {
            SimulatorBar(controller: controller)
            if let notice = controller.commentMode.notice {
                SimulatorNotice(label: "Comment", text: notice, isError: false)
            } else if let action = controller.actionNotice {
                SimulatorNotice(label: action.isError ? "Refused" : "Device",
                                text: action.text, isError: action.isError)
            } else if let failure = controller.inputFailure {
                SimulatorNotice(text: "Input was refused. \(failure)", isError: true)
            } else if controller.isAwaitingBoot {
                SimulatorNotice(text: "Starting \(controller.deviceInfo?.name ?? "the device")…",
                                isError: false)
            } else if let failure = controller.startFailure {
                SimulatorNotice(text: "Could not attach to the device. \(failure)", isError: true)
            } else if let degradation = controller.degradation {
                SimulatorNotice(text: degradation.summary, isError: false)
            }
            ZStack(alignment: .top) {
                GeometryReader { geo in
                    // Comment mode lives in the controller; the AppKit view needs telling.
                    let _ = { controller.screenView.commentModeActive = controller.commentMode.active }()
                    // Turning the device turns the drawn hardware too — the bezel's one wide edge
                    // and the side buttons come round with it — so the glass is landscape and the
                    // whole frame is re-fitted, which is why this reads the controller's
                    // orientation rather than assuming portrait.
                    let landscape = controller.orientation.isLandscape
                    let bez = controller.device.bezels(landscape: landscape)
                    let glass = controller.device.screenSize(landscape: landscape)
                    let frameW = glass.width + bez.leading + bez.trailing
                    let frameH = glass.height + bez.top + bez.bottom
                    let s = max(0.05, min(1, (geo.size.width - 48) / frameW,
                                             (geo.size.height - 48) / frameH))
                    DeviceFrame(device: controller.device, landscape: landscape, s: s) {
                        DeviceScreenHost(view: controller.screenView)
                            .frame(width: glass.width * s, height: glass.height * s)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .background(Theme.chrome)
                .overlay(alignment: .bottom) {
                    if controller.commentMode.pendingPoint != nil {
                        SimulatorCommentComposer(commentMode: controller.commentMode)
                            .padding(14)
                    }
                }
                if controller.launcherOpen {
                    // Outside-click catcher under the drop (the browser pane's, and the mock's
                    // document mousedown).
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.launcherOpen = false }
                    SimulatorLauncherDrop(controller: controller)
                }
            }
        }
    }
}

/// What you type after clicking something in comment mode. Anchored at the bottom of the stage rather
/// than floating at the tap: the tap is often near an edge, and a box that moves around is harder to
/// aim at than one that is always in the same place. What was clicked is named in the box instead.
private struct SimulatorCommentComposer: View {
    let commentMode: SimulatorCommentModeController
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Comment on")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                // The accessibility label of what was clicked, so it is obvious what the comment will
                // be attached to before it is written — and honest that the hit test is still out
                // rather than claiming there is nothing there.
                Text(commentMode.pendingAnchor
                     ?? (commentMode.anchorResolved ? "this point on the screen" : "reading the screen…"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer()
                if let target = commentMode.targetTitle {
                    Text("→ \(target)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
            }
            TextField("What's wrong with it?", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { send() }
            HStack(spacing: 8) {
                Spacer()
                Text("esc to cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkMuted)
                Button("Send") { send() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(text.isEmpty ? Theme.inkMuted : Theme.accent)
                    .disabled(text.isEmpty)
            }
        }
        .padding(10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .frame(maxWidth: 460)
        .onAppear { focused = true }
    }

    private func send() {
        commentMode.send(text)
        text = ""
    }
}

/// `.pane-bar` said in hardware: press, then what is running, then the size it is running at, then
/// the tools. Home and Lock are the two buttons a developer actually reaches for — background the
/// app, lock the screen — and neither is reachable any other way, since the side buttons on the
/// drawn frame are hardware rather than controls. Rotate joins them because turning a real device
/// is a gesture there is no pointer equivalent of at all. The device's *name* is not here: the
/// session row already says it, so the bar spends the room on what changes.
private struct SimulatorBar: View {
    let controller: SimulatorSessionController

    /// Names the receiving session while the mode is on. With no owner yet the first comment spawns
    /// one, so the off-state says that rather than pretending there is nowhere for a comment to go.
    private var commentHelp: String {
        guard controller.commentMode.active else {
            return "Comment on something on the device (Esc to leave)"
        }
        if let target = controller.commentMode.targetTitle { return "Comment mode → \(target)" }
        return "Comment mode — the first comment starts a Claude Code session for this device"
    }

    /// The runtime, and the viewport the interface is laid out in — which is the number that moves
    /// while you drive this surface, so it turns with the device.
    private var badge: String {
        let glass = controller.device.screenSize(landscape: controller.orientation.isLandscape)
        // verbatim: a point count, not a quantity — no locale grouping.
        let size = "\(Int(glass.width)) × \(Int(glass.height))"
        guard let runtime = controller.deviceInfo?.runtime, !runtime.isEmpty else { return size }
        return "\(runtime) · \(size)"
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                PaneBarButton(icon: Phosphor.house, help: "Press the Home button") {
                    controller.press(.home)
                }
                PaneBarButton(icon: Phosphor.lock, help: "Press the Lock button") {
                    controller.press(.lock)
                }
                // The device glyph turned to the orientation a press would give — the browser's
                // device bar's rotate, for the same reason: a circular arrow reads as reload.
                PaneBarButton(
                    icon: Phosphor.deviceMobile,
                    help: controller.orientation.isLandscape
                        ? "Turn the device back to portrait"
                        : "Turn the device to landscape. Apps that declare portrait-only stay portrait.",
                    rotation: controller.orientation.isLandscape ? 0 : 90) {
                    controller.rotate()
                }
            }
            SimulatorIdentityField(controller: controller)
            PaneBadge(text: badge, help: "The runtime and the device's viewport in points")
            // Who the comment will reach, while the mode is on — this is the only place the
            // delivery target is named.
            if controller.commentMode.active, let target = controller.commentMode.targetTitle {
                Text("→ \(target)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .background(Capsule().fill(Theme.rowSelected))
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                    .frame(maxWidth: 180, alignment: .trailing)
                    .help("Comments go to \(target)")
            }
            PaneBarButton(icon: Phosphor.commentMode, help: commentHelp,
                          on: controller.commentMode.active) {
                controller.commentMode.toggle()
            }
        }
        .paneBar()
    }
}

/// `.pane-omni`, in the device's language: the browser's omnibox names the page, this names the app.
/// It says what Synth last launched here, and clicking it opens the launcher.
private struct SimulatorIdentityField: View {
    let controller: SimulatorSessionController
    @State private var hovering = false

    var body: some View {
        let editing = controller.launcherOpen
        Button { controller.openAppLauncher() } label: {
            HStack(spacing: 7) {
                Phos(path: Phosphor.squares, size: 12).foregroundStyle(Theme.inkFaint)
                if let label = controller.runningAppLabel {
                    Text(label)
                        .font(.mono(12))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text("Open an app or URL")
                        .font(.mono(12))
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(editing ? Theme.accent
                                          : (hovering ? Theme.borderStrong : Theme.border),
                                  lineWidth: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .inset(by: -2)
                    .stroke(Theme.accent.opacity(0.16), lineWidth: 3)
                    .opacity(editing ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `.pane-drop`, floated over the device exactly as the browser's "go to" floats over a page: type
/// a bundle id or a URL, or pick something the device already has. Esc or an outside click closes.
private struct SimulatorLauncherDrop: View {
    let controller: SimulatorSessionController

    /// Enough to find the app being worked on without turning the drop into the home screen —
    /// user apps sort first, so a long tail of system apps never pushes them off.
    private var apps: [SimulatorInstalledApp] { Array(controller.installedApps.prefix(8)) }

    var body: some View {
        PaneDrop {
            GoToField(placeholder: "Bundle id or URL",
                      seed: controller.runningAppLabel,
                      onSubmit: { text in
                          controller.launcherOpen = false
                          controller.open(text)
                      },
                      onCancel: { controller.launcherOpen = false })
            if !apps.isEmpty {
                PaneRecLabel(text: "Installed", topPadding: 12)
                VStack(spacing: 1) {
                    ForEach(apps) { app in
                        PaneRecRow(icon: Phosphor.squares, key: app.bundleIdentifier,
                                   name: app.name) {
                            controller.launcherOpen = false
                            controller.open(app.bundleIdentifier)
                        }
                    }
                }
            }
        }
    }
}

/// A simulator session can exist without a device: the worktree session template creates rows by
/// kind, and a restored row holds a UDID but no claim (ADR-0015). Picking is therefore a real
/// first-class state of the pane, not an error.
private struct SimulatorDevicePicker: View {
    let session: Session
    @Environment(AppStore.self) private var store

    var body: some View {
        let devices = Simulators.fleet.devices()
        VStack(spacing: 10) {
            Text("Choose a device")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if devices.isEmpty {
                Text(SimulatorDeviceCatalog.isXcodeAvailable
                     ? "No simulator devices are installed."
                     : "Xcode is not installed, so there are no simulators to run.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkMuted)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(devices) { device in
                            Button {
                                store.attachSimulatorDevice(device, to: session)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(device.name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.ink)
                                    Text(device.runtime)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.inkMuted)
                                    Spacer()
                                    if device.isBooted {
                                        Text("Booted")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.inkMuted)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 380, maxHeight: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Why a pane is not showing what it should. Carried in the pane rather than logged, because a
/// degraded simulator has to say what it lost — a stale screenshot at 2fps passed off as a live
/// device is worse than one that admits it.
private struct SimulatorNotice: View {
    /// What kind of thing is speaking. Defaulted, because most of this strip's lines are about the
    /// device — but a comment-mode line is not, and "Degraded  Click something on the device" reads
    /// as a broken pane rather than an instruction.
    var label: String?
    let text: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label ?? (isError ? "Not attached" : "Degraded"))
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(isError ? Theme.danger : Theme.inkMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
