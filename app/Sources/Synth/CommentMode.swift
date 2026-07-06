import AppKit
import Foundation
import Observation

/// ADR-0011 stage three, host side: comment mode on one browser session. Attaches a CDP
/// client to the session's page target, binds the page→host channel
/// (`window.__synthComment`), injects the selection overlay on the current page and every
/// future document, and turns each comment payload into located context — clipped +
/// full-viewport screenshots plus a composed message — delivered to the branch's Claude
/// Code session through its PTY.
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
    /// The receiving Claude session's title — the bar's target chip.
    private(set) var targetTitle: String?
    /// Transient in-pane notice (delivery failures, attach errors). Auto-clears.
    private(set) var notice: String?

    @ObservationIgnored private var client: CDPClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var attachTask: Task<Void, Never>?
    @ObservationIgnored private var attachNonce = 0
    @ObservationIgnored private var injectedScriptID: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?

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
        targetTitle = prospectiveTarget()?.title ?? "New Claude session"
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
            return
        }
        active = false
        targetTitle = nil
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
        case "exitMode": await exit()
        case "comment":  await handleComment(obj)
        default: break
        }
    }

    private func handleComment(_ payload: [String: Any]) async {
        guard let client else { return }
        func num(_ dict: [String: Any], _ key: String) -> Double {
            (dict[key] as? NSNumber)?.doubleValue ?? 0
        }
        let rect = payload["rect"] as? [String: Any] ?? [:]
        let x = num(rect, "x"), y = num(rect, "y")
        let w = max(num(rect, "width"), 1), h = max(num(rect, "height"), 1)

        // Viewport bounds for clamping the padded clip.
        var vw = Double.greatestFiniteMagnitude, vh = Double.greatestFiniteMagnitude
        if let metrics = try? await client.send("Page.getLayoutMetrics"),
           let viewport = (metrics["cssLayoutViewport"] ?? metrics["layoutViewport"]) as? [String: Any] {
            vw = num(viewport, "clientWidth")
            vh = num(viewport, "clientHeight")
        }
        let pad = 24.0
        let cx = max(0, x - pad), cy = max(0, y - pad)
        let cw = max(1, min(w + 2 * pad, vw - cx)), ch = max(1, min(h + 2 * pad, vh - cy))

        let stamp = Self.timestamp()
        let dir = Self.commentsDir(sessionID: sessionID)
        var elementPath = "-", viewportPath = "-"
        var screenshots: [String] = []
        if let shot = try? await client.send("Page.captureScreenshot", [
            "format": "png",
            "clip": ["x": cx, "y": cy, "width": cw, "height": ch, "scale": 1],
        ], timeout: 20), let png = Self.decodePNG(shot) {
            elementPath = dir.appendingPathComponent("\(stamp)-element.png").path
            try? png.write(to: URL(fileURLWithPath: elementPath))
            screenshots.append(elementPath)
        }
        if let shot = try? await client.send("Page.captureScreenshot", ["format": "png"],
                                             timeout: 20), let png = Self.decodePNG(shot) {
            viewportPath = dir.appendingPathComponent("\(stamp)-viewport.png").path
            try? png.write(to: URL(fileURLWithPath: viewportPath))
            screenshots.append(viewportPath)
        }

        let message = Self.composeMessage(payload: payload,
                                          size: (Int(w), Int(h)), origin: (Int(x), Int(y)),
                                          elementPath: elementPath, viewportPath: viewportPath)
        deliver(message, screenshots: screenshots)
    }

    // MARK: Delivery — the ownership ladder (ADR-0011 stage four)

    /// The browser's owning claude row (stage four containment) — the deterministic
    /// comment target, replacing stage three's most-active-in-branch guess.
    private func ownerRow() -> Session? {
        guard let store, let session = store.session(sessionID) else { return nil }
        return store.owner(of: session)
    }

    /// The bar chip's label source: the owner when owned; nil for an unowned browser,
    /// whose comment always spawns a fresh claude ("New Claude session" in the chip).
    private func prospectiveTarget() -> Session? { ownerRow() }

    /// SECURITY: a comment embeds page-controlled text (title / selector / element HTML)
    /// and submit() follows the paste with Enter. Pasting that into anything except a live
    /// Claude TUI — e.g. the bare shell left behind when a restored row's `claude --resume`
    /// fails — would hand a hostile page arbitrary shell execution. So submit() is called
    /// ONLY for a session the hook seam has confirmed live (claude-start /
    /// claudeSessionCaptured, not since ended or exited): immediately when one exists,
    /// else after booting the target row — including a freshly spawned one — and WAITING
    /// for its liveness signal, never merely for its terminal view existing.
    ///
    /// The ladder: owner live → deliver; owner dormant → boot it and wait; no owner →
    /// spawn a fresh claude in the branch, adopt the browser under it (so the next
    /// comment hits the first rung), and boot-and-wait. The spawn is silent — no
    /// confirmation, focus returns to the browser pane.
    private func deliver(_ message: String, screenshots: [String]) {
        guard let store, let browser = store.session(sessionID) else {
            Self.discard(screenshots)
            return
        }
        if let owner = ownerRow() {
            targetTitle = owner.title
            // Rung 1: live owner — submit now.
            if store.isLiveClaude(owner.id), TerminalManager.shared.submit(message, to: owner.id) {
                NSLog("Synth: browser comment delivered to owning Claude session %@ (%@)",
                      owner.id.uuidString, owner.title)
                showNotice("Comment sent to \(owner.title)")
                return
            }
            // Rung 2: dormant owner — open it (mounts the pane, launches claude /
            // --resume), then wait for the hook seam before submitting.
            showNotice("Opening \(owner.title) to deliver the comment…")
            store.open(owner)
            bootAndSubmit(owner, message: message, screenshots: screenshots)
            return
        }
        // Rung 3: unowned — spawn this browser's own claude. The PTY only boots when its
        // pane mounts (GhosttySurfaceView creates the surface on window attach), so open
        // the row for one beat and come straight back to the browser; both views live
        // outside the SwiftUI tree (TerminalManager / BrowserManager) and survive the swap.
        guard let branch = store.branch(of: browser),
              let spawned = store.spawnClaude(in: branch) else {
            showNotice("Couldn't start a Claude session for the comment")
            Self.discard(screenshots)
            return
        }
        store.adopt(browser, by: spawned)
        targetTitle = spawned.title
        store.open(spawned)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak store, sessionID] in
            guard let store, store.openSessionID == spawned.id,
                  let back = store.session(sessionID) else { return }
            store.open(back)
        }
        showNotice("Starting \(spawned.title) to deliver the comment…")
        bootAndSubmit(spawned, message: message, screenshots: screenshots)
    }

    /// Boot-and-wait delivery to `row`: poll the hook seam for its liveness signal
    /// (~20s), then submit — the security boundary above, shared by rungs 2 and 3.
    private func bootAndSubmit(_ row: Session, message: String, screenshots: [String]) {
        deliveryTask?.cancel()
        deliveryTask = Task { [weak self] in
            for _ in 0..<40 {   // ~20s: claude boots and fires SessionStart, or never will
                try? await Task.sleep(for: .seconds(0.5))
                guard let self, !Task.isCancelled else { return }
                guard let store = self.store, store.isLiveClaude(row.id) else { continue }
                // Live confirmed — one more beat so the TUI is past its first paint and
                // won't eat the early paste; re-check liveness after the beat.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, store.isLiveClaude(row.id) else { continue }
                if TerminalManager.shared.submit(message, to: row.id) {
                    NSLog("Synth: browser comment delivered to Claude session %@ (%@) after booting it",
                          row.id.uuidString, row.title)
                    self.showNotice("Comment sent to \(row.title)")
                    return
                }
            }
            // Claude never reported in (e.g. the resume failed and left a bare shell):
            // drop the comment — and its now-orphaned screenshots — rather than paste.
            self?.showNotice("Couldn't reach “\(row.title)” — comment not delivered")
            Self.discard(screenshots)
        }
    }

    /// Screenshots captured for a comment that was never delivered are orphans — remove.
    private static func discard(_ screenshots: [String]) {
        for path in screenshots {
            try? FileManager.default.removeItem(atPath: path)
        }
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

    static func composeMessage(payload: [String: Any],
                               size: (Int, Int), origin: (Int, Int),
                               elementPath: String, viewportPath: String) -> String {
        let urlString = payload["url"] as? String ?? ""
        let place = URL(string: urlString)?.browserHostPath ?? urlString
        var lines = ["[Synth] Browser comment on \(place)"]
        lines.append("Element: \(payload["selector"] as? String ?? "?")")
        lines.append("Position: \(size.0)×\(size.1) at (\(origin.0),\(origin.1))")
        if let src = payload["reactSource"] as? [String: Any],
           let file = src["fileName"] as? String {
            let line = (src["lineNumber"] as? NSNumber).map { ":\($0)" } ?? ""
            lines.append("React source: \(file)\(line)")
        }
        let html = (payload["elementHTML"] as? String ?? "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        lines.append("Element HTML: \(html.count > 400 ? String(html.prefix(400)) + "…" : html)")
        lines.append("Screenshots: element \(elementPath) | viewport \(viewportPath)")
        lines.append("Comment: \(payload["comment"] as? String ?? "")")
        lines.append("Please address this feedback in the code.")
        return lines.joined(separator: "\n")
    }

    private static func commentsDir(sessionID: UUID) -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synth/comments/\(sessionID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }

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
