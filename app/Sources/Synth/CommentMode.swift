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
    @ObservationIgnored private var injectedScriptID: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(sessionID: UUID, cdpPort: UInt16) {
        self.sessionID = sessionID
        self.cdpPort = cdpPort
    }

    // MARK: Enter / exit

    func enter(store: AppStore, urlHint: URL?) async {
        guard !active else { return }
        guard cdpPort != 0 else {
            showNotice("Comment mode needs the Chromium engine (no CDP endpoint)")
            return
        }
        self.store = store
        targetTitle = targetClaudeSession()?.title
        do {
            let client = try await CDPClient.attach(port: cdpPort, synthSessionID: sessionID,
                                                    urlHint: urlHint)
            self.client = client
            try await client.send("Runtime.enable")
            try await client.send("Page.enable")
            try await client.send("Runtime.addBinding", ["name": "__synthComment"])
            let source = Self.injectionSource(targetLabel: targetTitle ?? "Claude Code")
            // Future documents: the binding survives navigation on its own; the overlay
            // is re-injected per document. Current document: evaluate the same source now.
            let added = try await client.send("Page.addScriptToEvaluateOnNewDocument",
                                              ["source": source])
            injectedScriptID = added["identifier"] as? String
            _ = try? await client.send("Runtime.evaluate", ["expression": source])
            active = true
            listen(to: client)
            NSLog("Synth: comment mode ON for %@ (cdp %d, target → %@)",
                  sessionID.uuidString, Int(cdpPort), targetTitle ?? "none")
        } catch {
            client?.close()
            client = nil
            showNotice("Comment mode failed to attach: \(error)")
        }
    }

    func exit() async {
        guard active else { return }
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
        if let shot = try? await client.send("Page.captureScreenshot", [
            "format": "png",
            "clip": ["x": cx, "y": cy, "width": cw, "height": ch, "scale": 1],
        ], timeout: 20), let png = Self.decodePNG(shot) {
            elementPath = dir.appendingPathComponent("\(stamp)-element.png").path
            try? png.write(to: URL(fileURLWithPath: elementPath))
        }
        if let shot = try? await client.send("Page.captureScreenshot", ["format": "png"],
                                             timeout: 20), let png = Self.decodePNG(shot) {
            viewportPath = dir.appendingPathComponent("\(stamp)-viewport.png").path
            try? png.write(to: URL(fileURLWithPath: viewportPath))
        }

        let message = Self.composeMessage(payload: payload,
                                          size: (Int(w), Int(h)), origin: (Int(x), Int(y)),
                                          elementPath: elementPath, viewportPath: viewportPath)
        deliver(message)
    }

    // MARK: Delivery

    /// The branch's receiving Claude Code session: an actively working one first
    /// (working / needsInput / running), else any Claude row.
    private func targetClaudeSession() -> Session? {
        guard let store, let session = store.session(sessionID),
              let branch = store.branch(of: session) else { return nil }
        let claudes = branch.sessions.filter { $0.kind == .claudeCode }
        let busy: [SessionStatus] = [.working, .needsInput, .running]
        return claudes.first { busy.contains($0.status) } ?? claudes.first
    }

    private func deliver(_ message: String) {
        guard let target = targetClaudeSession() else {
            showNotice("No Claude Code session in this branch — create one to receive comments")
            return
        }
        targetTitle = target.title
        guard TerminalManager.shared.submit(message, to: target.id) else {
            showNotice("Claude session “\(target.title)” has no live terminal — open it first")
            return
        }
        NSLog("Synth: browser comment delivered to Claude session %@ (%@)",
              target.id.uuidString, target.title)
        showNotice("Comment sent to \(target.title)")
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
