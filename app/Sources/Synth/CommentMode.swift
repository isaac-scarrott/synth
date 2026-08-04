import AppKit
import Foundation
import Observation

/// ADR-0011 stage three, host side: comment mode on one browser session. Attaches a CDP
/// client to the session's page target, binds the page→host channel
/// (`window.__synthComment`), injects the selection overlay on the current page and every
/// future document, and turns the page's batch of comments into located context — one
/// viewport screenshot, a clipped shot per pin, and one composed message — delivered to the
/// branch's Claude Code session through its PTY.
///
/// The queue lives on the page: comments accumulate as numbered pins and arrive here in a
/// single `commentBatch`, so one interruption carries the whole round of feedback. The host
/// only mirrors the running count (`batchCount`) for the toolbar badge.
///
/// World choice: everything runs in the MAIN world (binding + overlay + injection), not an
/// isolated world. Deliberate for v1: the payload's `reactSource` comes off React's expando
/// props on DOM nodes, which isolated worlds cannot see (separate JS wrappers), and the
/// main-world pairing keeps Runtime.addBinding target-wide with zero executionContextId
/// bookkeeping. Revisit if page scripts start fighting the overlay.
@MainActor @Observable final class CommentModeController {
    let sessionID: UUID
    @ObservationIgnored private let cdpPort: UInt16
    @ObservationIgnored private weak var store: AppStore?

    /// Drives the bar button's on-state and the Esc handler's gate.
    private(set) var active = false
    /// The receiving Claude session's title — named by the page's island, and passed to the
    /// overlay at injection.
    private(set) var targetTitle: String?
    /// Comments queued on the page and not yet sent — the toolbar's count badge, and the
    /// gate on ⌘⌥⏎. Mirrored from the page's `batchCount`, never counted here.
    private(set) var pendingCount = 0
    /// Transient in-pane notice (delivery failures, attach errors). Auto-clears.
    private(set) var notice: String?

    @ObservationIgnored private var client: CDPClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var attachTask: Task<Void, Never>?
    @ObservationIgnored private var attachNonce = 0
    @ObservationIgnored private var injectedScriptID: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(sessionID: UUID, cdpPort: UInt16) {
        self.sessionID = sessionID
        self.cdpPort = cdpPort
    }

    // MARK: Enter / exit

    /// True from enter() until exit/teardown — including the in-flight CDP attach, so a
    /// toggle during the attach cancels it instead of stacking a second client + event
    /// task on top of the first (the bar reads `active` for its on-state, this to toggle).
    var engaged: Bool { active || attachTask != nil }

    func enter(store: AppStore, urlHint: URL?) {
        guard !engaged else { return }
        guard cdpPort != 0 else {
            showNotice("Comment mode needs the Chromium engine (no CDP endpoint)")
            return
        }
        self.store = store
        // Where the next comment lands. Unowned means Synth would start an agent to take it —
        // unless every agent is switched off, and then the chip says so before anything is
        // typed rather than refusing it on send (working.html `commentTarget`).
        targetTitle = prospectiveTarget()?.title
            ?? (store.availableAgents.isEmpty ? "No agent enabled" : "New agent session")
        attachNonce += 1
        let nonce = attachNonce
        attachTask = Task { [weak self] in
            await self?.attach(urlHint: urlHint)
            // Clear only our own slot — a cancel + re-enter has already replaced it.
            if let self, self.attachNonce == nonce { self.attachTask = nil }
        }
    }

    /// One CDP attach, cancellable end-to-end: controller state is mutated only after the
    /// final cancellation check, so an exit() mid-attach leaves nothing behind — the local
    /// client is closed here, never leaked into `self.client`.
    private func attach(urlHint: URL?) async {
        var opened: CDPClient?
        do {
            let client = try await CDPClient.attach(port: cdpPort, synthSessionID: sessionID,
                                                    urlHint: urlHint)
            opened = client
            try Task.checkCancellation()
            try await client.send("Runtime.enable")
            try await client.send("Page.enable")
            try await client.send("Runtime.addBinding", ["name": "__synthComment"])
            let source = Self.injectionSource(targetLabel: targetTitle ?? "Claude Code")
            // Future documents: the binding survives navigation on its own; the overlay
            // is re-injected per document. Current document: evaluate the same source now.
            let added = try await client.send("Page.addScriptToEvaluateOnNewDocument",
                                              ["source": source])
            _ = try? await client.send("Runtime.evaluate", ["expression": source])
            try Task.checkCancellation()
            self.client = client
            injectedScriptID = added["identifier"] as? String
            active = true
            listen(to: client)
            NSLog("Synth: comment mode ON for %@ (cdp %d, target → %@)",
                  sessionID.uuidString, Int(cdpPort), targetTitle ?? "none")
        } catch {
            opened?.close()
            if !(error is CancellationError), !Task.isCancelled {
                showNotice("Comment mode failed to attach: \(error)")
            }
        }
    }

    func exit() async {
        attachTask?.cancel()
        attachTask = nil
        guard active else {
            targetTitle = nil
            pendingCount = 0
            return
        }
        active = false
        targetTitle = nil
        pendingCount = 0
        if let client {
            _ = try? await client.send(
                "Runtime.evaluate",
                ["expression": "window.__synthOverlay && window.__synthOverlay.exit && window.__synthOverlay.exit()"],
                timeout: 3)
            if let id = injectedScriptID {
                _ = try? await client.send("Page.removeScriptToEvaluateOnNewDocument",
                                           ["identifier": id], timeout: 3)
            }
            _ = try? await client.send("Runtime.removeBinding",
                                       ["name": "__synthComment"], timeout: 3)
        }
        teardown()
        NSLog("Synth: comment mode OFF for %@", sessionID.uuidString)
    }

    /// Synchronous cleanup — session close / app quit (no CDP goodbyes).
    func teardown() {
        attachTask?.cancel()
        attachTask = nil
        eventTask?.cancel()
        eventTask = nil
        client?.close()
        client = nil
        injectedScriptID = nil
        active = false
        pendingCount = 0
    }

    /// ⌘⌥⏎: the queue is the page's, so the send is the overlay's own verb — the batch comes
    /// back over the binding exactly as it does when the island's Send is clicked.
    func sendBatch() {
        guard active, let client else { return }
        Task {
            _ = try? await client.send(
                "Runtime.evaluate",
                ["expression": "window.__synthOverlay && window.__synthOverlay.send && window.__synthOverlay.send()"],
                timeout: 5)
        }
    }

    // MARK: Page → host

    private func listen(to client: CDPClient) {
        eventTask = Task { [weak self] in
            for await event in client.events {
                guard event.method == "Runtime.bindingCalled",
                      event.params["name"] as? String == "__synthComment",
                      let payload = event.params["payload"] as? String else { continue }
                await self?.handleBinding(payload)
            }
            // Socket gone (page target closed) — drop out of the mode.
            self?.teardown()
        }
    }

    private func handleBinding(_ payload: String) async {
        guard let data = payload.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        switch obj["type"] as? String {
        case "exitMode":     await exit()
        case "batchCount":   pendingCount = (obj["n"] as? NSNumber)?.intValue ?? 0
        case "commentBatch": await handleBatch(obj)
        default: break
        }
    }

    private func handleBatch(_ payload: [String: Any]) async {
        guard let client else { return }
        let comments = payload["comments"] as? [[String: Any]] ?? []
        guard !comments.isEmpty else { return }

        let stamp = Self.timestamp()
        let dir = Self.commentsDir(sessionID: sessionID)
        var screenshots: [String] = []

        // One shot of the page as a whole — the batch's shared frame of reference.
        var viewportPath = "-"
        if let shot = try? await client.send("Page.captureScreenshot", ["format": "png"],
                                             timeout: 20), let png = Self.decodePNG(shot) {
            viewportPath = dir.appendingPathComponent("\(stamp)-viewport.png").path
            try? png.write(to: URL(fileURLWithPath: viewportPath))
            screenshots.append(viewportPath)
        }

        // Document bounds for clamping the padded clips: the clip below is in page
        // coordinates, so the viewport's own size is the wrong ceiling.
        var dw = Double.greatestFiniteMagnitude, dh = Double.greatestFiniteMagnitude
        if let metrics = try? await client.send("Page.getLayoutMetrics"),
           let content = (metrics["cssContentSize"] ?? metrics["contentSize"]) as? [String: Any] {
            dw = Self.num(content, "width")
            dh = Self.num(content, "height")
        }

        // Device emulation reframes the page at another viewport and pixel ratio, and a
        // `clip` in CSS pixels does not survive that — every strategy lands on a blank band
        // (verified: viewport-relative, document-relative, and scroll-into-view all fail under
        // setDeviceMetricsOverride). A blank PNG the message then points an agent at is worse
        // than no PNG, so under device mode the batch carries the viewport shot alone and the
        // comments lean on selector + position, which are unaffected. Cropping host-side from
        // one full-page capture would fix this properly; until then it degrades honestly.
        let emulating = BrowserManager.shared.existing(sessionID)?.deviceModeOn == true

        var elementPaths: [String?] = []
        for (i, comment) in comments.enumerated() {
            // A pin left on a page we have since navigated away from can't be re-shot; its
            // text, selector and React source still carry it.
            guard comment["onCurrentPage"] as? Bool == true, !emulating else {
                elementPaths.append(nil)
                continue
            }
            let rect = comment["rect"] as? [String: Any] ?? [:]
            // getBoundingClientRect is viewport-relative, `clip` is document-relative: add the
            // scroll offset (and capture beyond the viewport) or anything below the fold is
            // shot from the wrong band of the page.
            let x = Self.num(rect, "x") + Self.num(rect, "scrollX")
            let y = Self.num(rect, "y") + Self.num(rect, "scrollY")
            let w = max(Self.num(rect, "width"), 1), h = max(Self.num(rect, "height"), 1)
            let pad = 24.0
            let cx = max(0, x - pad), cy = max(0, y - pad)
            let cw = max(1, min(w + 2 * pad, dw - cx)), ch = max(1, min(h + 2 * pad, dh - cy))
            guard let shot = try? await client.send("Page.captureScreenshot", [
                "format": "png",
                "clip": ["x": cx, "y": cy, "width": cw, "height": ch, "scale": 1],
                "captureBeyondViewport": true,
            ], timeout: 20), let png = Self.decodePNG(shot) else {
                elementPaths.append(nil)
                continue
            }
            let no = (comment["n"] as? NSNumber)?.intValue ?? i + 1
            let path = dir.appendingPathComponent("\(stamp)-\(no)-element.png").path
            try? png.write(to: URL(fileURLWithPath: path))
            elementPaths.append(path)
            screenshots.append(path)
        }

        let message = Self.composeBatchMessage(payload, viewportPath: viewportPath,
                                               elementPaths: elementPaths)
        deliver(message, count: comments.count, screenshots: screenshots)
    }

    // MARK: Delivery — the ownership ladder (ADR-0011 stage four)

    /// The browser's owning agent row (stage four containment) — the deterministic
    /// comment target, replacing stage three's most-active-in-branch guess.
    private func ownerRow() -> Session? { delivery.ownerRow() }

    /// The bar chip's label source: the owner when owned; nil for an unowned browser,
    /// whose comment always spawns a fresh agent ("New agent session" in the chip).
    private func prospectiveTarget() -> Session? { ownerRow() }

    /// Delivery is `CommentDelivery` (shared with the simulator): the ladder and its security gate
    /// are one implementation, not one per pane.
    @ObservationIgnored private lazy var delivery: CommentDelivery = {
        let delivery = CommentDelivery(sessionID: sessionID, store: store, subjectKindLabel: "browser")
        delivery.onNotice = { [weak self] in self?.showNotice($0) }
        delivery.onTarget = { [weak self] in self?.targetTitle = $0 }
        return delivery
    }()

    /// `count` is the batch size, which only ever changes the wording the user sees.
    private func deliver(_ message: String, count: Int = 1, screenshots: [String]) {
        delivery.deliver(message, count: count, screenshots: screenshots)
    }

    // MARK: Helpers

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    /// The whole batch as one message: the page named once at the top with its viewport shot,
    /// then a numbered block per comment carrying that pin's own context. `elementPaths` runs
    /// parallel to `comments` — nil where the pin lives on a page we are no longer on.
    static func composeBatchMessage(_ payload: [String: Any],
                                    viewportPath: String,
                                    elementPaths: [String?]) -> String {
        let comments = payload["comments"] as? [[String: Any]] ?? []
        let urlString = payload["url"] as? String ?? ""
        let place = URL(string: urlString)?.browserHostPath ?? urlString
        let n = comments.count
        var lines = ["[Synth] \(n) browser comment\(n == 1 ? "" : "s") on \(place)"]
        lines.append("Viewport screenshot: \(viewportPath)")
        for (i, comment) in comments.enumerated() {
            lines.append("")
            let no = (comment["n"] as? NSNumber)?.intValue ?? i + 1
            lines.append("\(no). \(comment["comment"] as? String ?? "")")
            // A pin from another page is only locatable if the message says which page.
            if comment["onCurrentPage"] as? Bool != true {
                let url = comment["url"] as? String ?? ""
                lines.append("   Page: \(URL(string: url)?.browserHostPath ?? url)")
            }
            lines.append("   Element: \(comment["selector"] as? String ?? "?")")
            let rect = comment["rect"] as? [String: Any] ?? [:]
            let w = Int(num(rect, "width")), h = Int(num(rect, "height"))
            let x = Int(num(rect, "x")), y = Int(num(rect, "y"))
            lines.append("   Position: \(w)×\(h) at (\(x),\(y))")
            if let src = comment["reactSource"] as? [String: Any],
               let file = src["fileName"] as? String {
                let line = (src["lineNumber"] as? NSNumber).map { ":\($0)" } ?? ""
                lines.append("   React source: \(file)\(line)")
            }
            let html = (comment["elementHTML"] as? String ?? "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            lines.append("   Element HTML: \(html.count > 400 ? String(html.prefix(400)) + "…" : html)")
            if i < elementPaths.count, let path = elementPaths[i] {
                lines.append("   Screenshot: \(path)")
            }
        }
        lines.append("")
        lines.append("Please address this feedback in the code.")
        return lines.joined(separator: "\n")
    }

    private static func num(_ dict: [String: Any], _ key: String) -> Double {
        (dict[key] as? NSNumber)?.doubleValue ?? 0
    }

    private static func commentsDir(sessionID: UUID) -> URL {
        CommentDelivery.commentsDir(sessionID: sessionID)
    }

    private static func timestamp() -> String { CommentDelivery.timestamp() }

    private static func decodePNG(_ reply: [String: Any]) -> Data? {
        (reply["data"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    /// The overlay source plus its enter() call — evaluated on the current page and on
    /// every new document while the mode is on.
    static func injectionSource(targetLabel: String) -> String {
        let cfg = (try? JSONSerialization.data(withJSONObject: ["targetLabel": targetLabel]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return overlayJS + "\n;window.__synthOverlay && window.__synthOverlay.enter(\(cfg));"
    }

    /// CommentOverlay.js from the SwiftPM resource bundle. Looked up by hand (not
    /// `Bundle.module`, which fatalErrors when the dev bundle misses the copy) with an
    /// inline stub fallback so comment mode still binds without the resource.
    private static let overlayJS: String = {
        var bundles: [URL] = []
        if let r = Bundle.main.resourceURL { bundles.append(r.appendingPathComponent("Synth_Synth.bundle")) }
        if let e = Bundle.main.executableURL?.deletingLastPathComponent() {
            bundles.append(e.appendingPathComponent("Synth_Synth.bundle"))
        }
        for url in bundles {
            if let bundle = Bundle(url: url),
               let res = bundle.url(forResource: "CommentOverlay", withExtension: "js"),
               let js = try? String(contentsOf: res, encoding: .utf8) {
                return js
            }
        }
        NSLog("Synth: CommentOverlay.js resource missing — using the inline stub overlay")
        return """
        (() => { if (window.__synthOverlay) return;
          window.__synthOverlay = { enter(cfg) {}, exit() {} }; })();
        """
    }()
}
