import AppKit
import CoreGraphics
import Foundation
import Observation

/// ADR-0011 stage three for the simulator (ADR-0015): click something on the device, say what is
/// wrong with it, and have that reach the Claude session that owns the row as *located* context.
///
/// The browser gets its anchor by injecting JavaScript into the page and reading back a CSS selector.
/// There is nothing to inject into here — the app under test is not ours — so the anchor is the
/// **accessibility element under the tap**: role, label, identifier, frame. That is a better anchor
/// than a selector rather than a worse one, because an accessibility identifier like
/// `com.apple.settings.general` is a string the developer can search for in their own source, which
/// is the entire point of a located comment.
///
/// Delivery is `CommentDelivery`, shared with the browser: one ladder, one security gate. The text in
/// a comment is app-controlled, exactly as the browser's is page-controlled, so it never reaches
/// anything but a supervisor-confirmed live agent.
@MainActor @Observable final class SimulatorCommentModeController {

    let sessionID: UUID
    @ObservationIgnored private weak var store: AppStore?

    /// Drives the bar button's on-state and the Esc handler's gate.
    private(set) var active = false
    /// The receiving Claude session's title — the bar's target chip.
    private(set) var targetTitle: String?
    /// Transient in-pane notice. Auto-clears.
    private(set) var notice: String?
    /// The tap being commented on, in normalised display coordinates, while the composer is open.
    private(set) var pendingPoint: CGPoint?
    /// What the accessibility tree says is under `pendingPoint` — shown in the composer so the user
    /// can see what the comment will be attached to before they write it. Nil until the hit test
    /// answers (`anchorResolved` tells the two apart).
    private(set) var pendingAnchor: String?
    /// Whether the hit test for `pendingPoint` has come back. The composer says so, and `send`
    /// waits on it rather than shipping a comment whose anchor was still in flight.
    private(set) var anchorResolved = false

    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingScreenshots: [String] = []
    @ObservationIgnored private var pendingElementLine: String?
    @ObservationIgnored private var anchorTask: Task<ResolvedAnchor, Never>?
    /// Which click a resolution belongs to, so a second click's answer cannot land on the first's.
    @ObservationIgnored private var anchorGeneration = 0

    /// What the hit test found, as plain strings — the pair crosses a queue hop.
    private struct ResolvedAnchor: Sendable {
        var anchor: String?
        var line: String?
    }

    @ObservationIgnored private lazy var delivery: CommentDelivery = {
        let delivery = CommentDelivery(sessionID: sessionID, store: store,
                                       subjectKindLabel: "simulator")
        delivery.onNotice = { [weak self] in self?.showNotice($0) }
        delivery.onTarget = { [weak self] in self?.targetTitle = $0 }
        return delivery
    }()

    init(sessionID: UUID, store: AppStore?) {
        self.sessionID = sessionID
        self.store = store
    }

    // MARK: Enter / exit

    /// The bar button's call.
    func toggle() {
        if active { exit() } else { enter() }
    }

    func enter() {
        active = true
        targetTitle = delivery.ownerRow()?.title
        showNotice("Click something on the device to comment on it")
    }

    func exit() {
        active = false
        discardPending()
    }

    func teardown() {
        noticeTask?.cancel()
        delivery.cancel()
        discardPending()
        active = false
    }

    /// Drop a composer that was opened and never sent, and the screenshots taken for it — otherwise
    /// they accumulate in Application Support for comments that were never made.
    private func discardPending() {
        CommentDelivery.discard(pendingScreenshots)
        pendingScreenshots = []
        clearPendingTap()
    }

    /// Forget the tap the composer was about, keeping whatever the caller has already taken
    /// ownership of. `anchorGeneration` moves so an in-flight hit test's answer is ignored.
    private func clearPendingTap() {
        anchorGeneration += 1
        anchorTask = nil
        anchorResolved = false
        pendingPoint = nil
        pendingAnchor = nil
        pendingElementLine = nil
    }

    // MARK: Selecting

    /// A click in comment mode. Resolves what is under it and captures the evidence *now*, before the
    /// user starts typing and the screen has a chance to move on — the frame is a live view of the
    /// device's surface, so a screenshot taken later is a screenshot of something else.
    func select(at point: CGPoint, in source: SimulatorDeviceSource) {
        discardPending()
        pendingPoint = point
        resolveAnchor(at: point, in: source)

        // The evidence: the whole screen, plus a crop around the element so the comment shows what
        // was clicked rather than making the agent hunt for it.
        // A comment is evidence handed to an agent, so a stale frame is worse than no comment.
        guard let frame = (try? source.captureVerifiedFrame()) ?? nil,
              let png = frame.pngByCopyingPixels() else {
            // No evidence, so no composer. Leaving it open invites a comment carrying no screenshot
            // and no anchor — honest about having nothing, and useless to the agent that receives it.
            discardPending()
            showNotice("Couldn't capture the screen — the device may have gone away. Nothing sent.")
            return
        }
        let dir = CommentDelivery.commentsDir(sessionID: sessionID)
        let stamp = CommentDelivery.timestamp()
        let screenURL = dir.appendingPathComponent("screen-\(stamp).png")
        if (try? png.write(to: screenURL)) != nil {
            pendingScreenshots.append(screenURL.path)
        }
        if let cropped = Self.crop(png, around: point, pixelSize: frame.pixelSize) {
            let cropURL = dir.appendingPathComponent("element-\(stamp).png")
            if (try? cropped.write(to: cropURL)) != nil {
                pendingScreenshots.insert(cropURL.path, at: 0)
            }
        }
    }

    /// What is under the tap, resolved **off** the main actor. A hit test is a request to the
    /// device's accessibility service behind a process-wide gate, and its worst case is tens of
    /// seconds — on the main actor that is one click freezing the whole window, the user's terminals
    /// and agent panes with it. So the composer opens on the click and the anchor lands when it
    /// lands. It is a blocking synchronous request, so it goes to a Dispatch queue rather than the
    /// cooperative pool, which it would otherwise hold a thread of hostage.
    ///
    /// A hit test is a different request from the tree walk and reaches elements the walk cannot,
    /// which is what makes clicking an arbitrary pixel work at all.
    private func resolveAnchor(at point: CGPoint, in source: SimulatorDeviceSource) {
        let generation = anchorGeneration
        // The source is driven off the main thread by every `simulator.*` verb already; it is the
        // compiler that needs telling, not the source that needs changing.
        final class Box: @unchecked Sendable {
            let source: SimulatorDeviceSource
            init(_ source: SimulatorDeviceSource) { self.source = source }
        }
        let box = Box(source)
        let task = Task<ResolvedAnchor, Never> {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let element = (try? box.source.describeAccessibility(at: point))?
                        .elements.first else {
                        continuation.resume(returning: ResolvedAnchor())
                        return
                    }
                    continuation.resume(returning: ResolvedAnchor(
                        anchor: Self.describeAnchor(element), line: element.line))
                }
            }
        }
        anchorTask = task
        Task { @MainActor [weak self] in
            let resolved = await task.value
            guard let self, self.anchorGeneration == generation else { return }
            self.pendingAnchor = resolved.anchor
            self.pendingElementLine = resolved.line
            self.anchorResolved = true
        }
    }

    /// Send the comment the user typed. `text` empty cancels, because an empty comment is worse than
    /// none: the agent gets a screenshot and no instruction.
    func send(_ text: String) {
        let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let point = pendingPoint else { return }
        guard !comment.isEmpty else {
            discardPending()
            showNotice("Comment discarded — it was empty")
            return
        }
        let screenshots = pendingScreenshots
        pendingScreenshots = []   // ownership passes to delivery, which discards on failure
        let elementLine = pendingElementLine
        let resolved = anchorResolved
        let pendingHitTest = anchorTask
        clearPendingTap()         // the composer closes on send, whatever the anchor is doing

        if !resolved, let pendingHitTest {
            // The click's hit test is still out. Waiting for it is the difference between a located
            // comment and "somewhere on this screen", and the user has already said their piece.
            showNotice("Reading what you clicked, then sending…")
            Task { @MainActor [weak self] in
                let anchor = await pendingHitTest.value
                guard let self else {
                    CommentDelivery.discard(screenshots)   // the pane went; leave no orphans
                    return
                }
                self.deliver(comment: comment, point: point, elementLine: anchor.line,
                             screenshots: screenshots)
            }
            return
        }
        deliver(comment: comment, point: point, elementLine: elementLine, screenshots: screenshots)
    }

    private func deliver(comment: String, point: CGPoint, elementLine: String?,
                         screenshots: [String]) {
        delivery.deliver(Self.composeMessage(
            comment: comment, point: point, elementLine: elementLine,
            device: store?.session(sessionID)?.title ?? "the device", screenshots: screenshots),
                         screenshots: screenshots)
    }

    func cancelPending() {
        discardPending()
    }

    // MARK: Composing

    /// Human-facing summary of the anchor, for the composer. Deliberately not the raw line: the user
    /// wants "General" and not `button|General|0.500,0.422|#com.apple.settings.general`.
    nonisolated private static func describeAnchor(
        _ element: SimulatorAccessibilityElement) -> String {
        if let label = element.label, !label.isEmpty {
            return element.identifier.map { "\(label) (\($0))" } ?? label
        }
        if let identifier = element.identifier, !identifier.isEmpty { return identifier }
        return element.role
    }

    static func composeMessage(comment: String, point: CGPoint, elementLine: String?,
                               device: String, screenshots: [String]) -> String {
        var lines = ["[Synth] Simulator comment on \(SimulatorAccessibilityElement.escape(device))"]
        // The accessibility line carries the identifier — the part that is greppable in the app's own
        // source, and the reason this is a located comment rather than "somewhere on this screen".
        if let elementLine {
            lines.append("Element: \(elementLine)")
            lines.append("(role|label|cx,cy then #identifier value=… — the identifier is what to "
                + "search for in the app's source)")
        } else {
            lines.append("Element: nothing in the accessibility tree under this point — the "
                + "screenshots are the whole of the evidence")
        }
        lines.append(String(format: "Tapped at (%.3f, %.3f) of the screen, from the top-left",
                            point.x, point.y))
        if !screenshots.isEmpty {
            lines.append("Screenshots: " + screenshots.joined(separator: " | "))
        }
        lines.append("Comment: \(comment)")
        lines.append("Please address this feedback in the code.")
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// A square crop centred on the tap, for the "what did they click" screenshot. Coordinates in,
    /// pixels out — the frame is in device pixels and the point is normalised.
    private static func crop(_ png: Data, around point: CGPoint, pixelSize: CGSize) -> Data? {
        guard pixelSize.width > 1, pixelSize.height > 1,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = max(160, min(pixelSize.width, pixelSize.height) / 3)
        let centre = CGPoint(x: point.x * pixelSize.width, y: point.y * pixelSize.height)
        let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
            .intersection(CGRect(origin: .zero, size: pixelSize))
        guard !rect.isNull, rect.width > 8, rect.height > 8,
              let cropped = image.cropping(to: rect) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.notice = nil }
        }
    }
}
