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
/// Leaving the mode does not end the batch (working.html `.cm-island.is-parked`): with comments
/// standing the page *parks* them — pins and island stay, the picker comes off — and this
/// attachment stays up for them, because the parked island's own Send still has to reach us. So
/// `exit()` asks the page what leaving meant and believes the answer: 'parked' keeps the client,
/// the binding, the injected script and the count; 'off' is the only path that tears down.
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
    /// The mode is off and the page is still holding a batch. The CDP attachment stays up for it;
    /// the toolbar keeps its count badge, and entering again resumes rather than re-attaches.
    private(set) var parked = false
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
    @ObservationIgnored private var scriptNonce = 0
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

    /// Unsent comments the user would lose if this browser went away — a parked batch included.
    /// Not `engaged`: parking is not being in the mode, and entering from here resumes.
    var holdingComments: Bool { pendingCount > 0 }

    func enter(store: AppStore, urlHint: URL?) {
        guard !engaged else { return }
        self.store = store
        // Where the next comment lands. Unowned means Synth would start an agent to take it —
        // unless every agent is switched off, and then the chip says so before anything is
        // typed rather than refusing it on send (working.html `commentTarget`).
        targetTitle = prospectiveTarget()?.title
            ?? (store.availableAgents.isEmpty ? "No agent enabled" : "New agent session")
        // Parked: this attachment never went away, so entering is a resume — a second attach here
        // would stack a client and an event task on top of the ones holding the batch.
        if parked, let client {
            parked = false
            active = true
            let label = targetTitle ?? "Claude Code"
            Guarded.mainTask { [weak self] in
                // Future documents first: the two are independent, and this way a current-page
                // injection that refuses still leaves the mode armed across the next navigation.
                await self?.installNewDocumentScript(verb: "enter")
                _ = try await client.send("Runtime.evaluate",
                                          ["expression": Self.injectionSource(targetLabel: label)],
                                          timeout: 5)
            }
            NSLog("Synth: comment mode resumed for %@ (%d unsent)", sessionID.uuidString, pendingCount)
            return
        }
        attachNonce += 1
        let nonce = attachNonce
        attachTask = Guarded.mainTask { [weak self] in
            await self?.attach(urlHint: urlHint)
            // Clear only our own slot — a cancel + re-enter has already replaced it.
            if let self, self.attachNonce == nonce { self.attachTask = nil }
        }
    }

    /// One CDP attach, cancellable end-to-end: controller state is mutated only after the
    /// final cancellation check, so an exit() mid-attach leaves nothing behind — the local
    /// client is closed here, never leaked into `self.client`.
    ///
    /// `healing` is a re-attach after the socket died under a mode that is still on: the flags
    /// already say what the mode is, so it leaves them alone and injects the verb that matches —
    /// `restore` brings a parked batch's pins back without turning the picker on.
    private func attach(urlHint: URL?, healing: Bool = false) async {
        var opened: CDPClient?
        do {
            guard Self.overlayJS != nil else {
                throw CDPClient.CDPError(description:
                    "the comment overlay is missing from this build — launch a bundle assembled "
                    + "by app/dev.sh or app/dist.sh")
            }
            let client = try await CDPClient.attach(port: cdpPort, synthSessionID: sessionID,
                                                    urlHint: urlHint)
            opened = client
            try Task.checkCancellation()
            try await client.send("Runtime.enable")
            try await client.send("Page.enable")
            try await client.send("Runtime.addBinding", ["name": "__synthComment"])
            let source = Self.injectionSource(targetLabel: targetTitle ?? "Claude Code",
                                              verb: healing && parked ? "restore" : "enter")
            // Future documents: the binding survives navigation on its own; the overlay
            // is re-injected per document. Current document: evaluate the same source now.
            let added = try await client.send("Page.addScriptToEvaluateOnNewDocument",
                                              ["source": source])
            _ = try await client.send("Runtime.evaluate", ["expression": source])
            try Task.checkCancellation()
            self.client = client
            injectedScriptID = added["identifier"] as? String
            if !healing { active = true }
            listen(to: client)
            NSLog("Synth: comment mode ON for %@ (cdp %d, target → %@)",
                  sessionID.uuidString, Int(cdpPort), targetTitle ?? "none")
        } catch {
            opened?.close()
            guard !(error is CancellationError), !Task.isCancelled else { return }
            // A heal's own attempts are the ladder's business — it says one thing at the end
            // rather than three on the way.
            if !healing { showNotice("Comment mode failed to attach: \(error)") }
            Fault.report(.browser, .uncaught, severity: .degraded, session: sessionID,
                         details: [.stage(.handshake), .flag("healing", healing)],
                         evidence: "\(error)")
        }
    }

    func exit() async {
        attachTask?.cancel()
        attachTask = nil
        guard active else {
            if !parked { targetTitle = nil; pendingCount = 0 }
            return
        }
        guard let client else { teardown(); return }
        // What leaving means is the page's to answer — it holds the queue. 'parked' means the
        // comments stayed on it, so everything here stays up for them.
        var answer = "off"
        do {
            let reply = try await client.send(
                "Runtime.evaluate",
                ["expression": "window.__synthOverlay && window.__synthOverlay.exit ? window.__synthOverlay.exit() : 'off'",
                 "returnByValue": true],
                timeout: 3)
            answer = ((reply["result"] as? [String: Any])?["value"] as? String) ?? "off"
        } catch {
            // No answer means tearing down, because that is the only reading that cannot strand
            // an attachment — but it is a guess, and a batch the page was in fact keeping is
            // lost with it, so what the page never said is counted rather than assumed away.
            Fault.report(.browser, .uncaught,
                         severity: pendingCount > 0 ? .failed : .degraded, session: sessionID,
                         details: [.stage(.teardown), .count("pending", pendingCount)],
                         evidence: "\(error)")
        }
        if answer == "parked" {
            park()
            return
        }
        await shutDown()
    }

    /// The page's overlay is gone of its own accord — a confirmed send, or the last comment
    /// discarded from a parked island. There is nothing left to ask it, and this is the one path
    /// that ends a *parked* attachment as well as a live one.
    private func pageLeft() async {
        guard active || parked else { return }
        await shutDown()
    }

    private func shutDown() async {
        active = false
        parked = false
        targetTitle = nil
        pendingCount = 0
        if let client {
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

    /// The page kept a batch the mode was leaving. Idempotent: the overlay says so over the
    /// binding as well, and either arrival order lands here once.
    private func park() {
        guard !parked else { return }
        active = false
        parked = true
        Guarded.mainTask { [weak self] in await self?.installNewDocumentScript(verb: "restore") }
        NSLog("Synth: comment mode parked for %@ (%d unsent)", sessionID.uuidString, pendingCount)
    }

    private func resumed() {
        guard parked else { return }
        parked = false
        active = true
        Guarded.mainTask { [weak self] in await self?.installNewDocumentScript(verb: "enter") }
    }

    /// The script every future document of this target gets. `enter` while the mode is on (it
    /// survives navigation); `restore` while a batch is parked, which brings the pins and the
    /// island back on the other side of a reload without turning the picker back on.
    /// Nonced like the attach: park/resume can be toggled faster than two CDP round-trips, and a
    /// swap that lost the race must drop its own script rather than leave one behind injecting the
    /// wrong verb into every future document.
    private func installNewDocumentScript(verb: String) async {
        guard let client else { return }
        scriptNonce += 1
        let nonce = scriptNonce
        if let id = injectedScriptID {
            injectedScriptID = nil
            _ = try? await client.send("Page.removeScriptToEvaluateOnNewDocument",
                                       ["identifier": id], timeout: 3)
        }
        guard nonce == scriptNonce else { return }
        let source = Self.injectionSource(targetLabel: targetTitle ?? "Claude Code", verb: verb)
        let added = try? await client.send("Page.addScriptToEvaluateOnNewDocument",
                                          ["source": source])
        let id = added?["identifier"] as? String
        guard nonce == scriptNonce else {
            if let id {
                _ = try? await client.send("Page.removeScriptToEvaluateOnNewDocument",
                                           ["identifier": id], timeout: 3)
            }
            return
        }
        injectedScriptID = id
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
        parked = false
        pendingCount = 0
    }

    /// ⌘⌥⏎: the queue is the page's, so the send is the overlay's own verb — the batch comes
    /// back over the binding exactly as it does when the island's Send is clicked. Not gated on
    /// `active`: a parked batch is still sendable, which is the point of parking it.
    func sendBatch() {
        guard let client, active || parked else { return }
        Guarded.mainTask {
            _ = try await client.send(
                "Runtime.evaluate",
                ["expression": "window.__synthOverlay && window.__synthOverlay.send && window.__synthOverlay.send()"],
                timeout: 5)
        }
    }

    // MARK: Page → host

    private func listen(to client: CDPClient) {
        eventTask = Guarded.mainTask { [weak self] in
            for await event in client.events {
                guard event.method == "Runtime.bindingCalled",
                      event.params["name"] as? String == "__synthComment",
                      let payload = event.params["payload"] as? String else { continue }
                await self?.handleBinding(payload)
            }
            try await self?.socketEnded(client)
        }
    }

    /// The CDP stream finished under a mode that is still on — the page target went away
    /// (a renderer swap, a navigation Chromium served from a new target). Nothing on the page
    /// changed: the pins, the island and its Send are all still drawn, so the only visible
    /// symptom is that everything stops working. A fresh attach against the *new* target is
    /// the whole repair, and it is bounded — three tries over about six seconds, after which
    /// the mode is honestly over and the user is told if they were holding anything.
    private func socketEnded(_ ended: CDPClient) async throws {
        guard client === ended else { return }
        client = nil
        injectedScriptID = nil
        guard active || parked else { teardown(); return }
        Fault.note(.browser, .healing)
        let hint = BrowserManager.shared.existing(sessionID)?.address
        for attempt in 0..<3 {
            try await Task.sleep(for: .seconds([0.25, 2, 4][attempt]))
            guard client == nil, active || parked else { return }
            await attach(urlHint: hint, healing: true)
            if client != nil {
                Fault.note(.browser, .healed)
                return
            }
            Fault.note(.browser, .healFailed)
        }
        let details: [Fault.Detail] = [.attempt(3), .count("pending", pendingCount)]
        if pendingCount > 0 {
            Fault.surface(.browser, .capabilityDown, severity: .failed, session: sessionID,
                          say: Fault.Copy(title: pendingCount == 1
                              ? "A browser comment couldn't be sent"
                              : "\(pendingCount) browser comments couldn't be sent"),
                          details: details,
                          evidence: "The page Synth was commenting on went away, and three "
                              + "attempts to find it again came back with nothing.")
        } else {
            Fault.report(.browser, .capabilityDown, severity: .degraded, session: sessionID,
                         details: details)
        }
        teardown()
    }

    private func handleBinding(_ payload: String) async {
        guard let data = payload.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        switch obj["type"] as? String {
        case "exitMode":     await pageLeft()
        case "parkMode":     park()
        case "resumeMode":   resumed()
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
            // The message names every path it lists, so a write that didn't happen must not be
            // named — an agent sent to a file that isn't there is worse off than one told there
            // is no shot. "-" is what the composer already says for a capture that never came.
            let url = dir.appendingPathComponent("\(stamp)-viewport.png")
            if Guarded.run({ try png.write(to: url) }) != nil {
                viewportPath = url.path
                screenshots.append(viewportPath)
            }
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
        let emulating = BrowserManager.shared.existing(sessionID)?.isEmulatingScreen == true

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
            let url = dir.appendingPathComponent("\(stamp)-\(no)-element.png")
            guard Guarded.run({ try png.write(to: url) }) != nil else {
                elementPaths.append(nil)
                continue
            }
            elementPaths.append(url.path)
            screenshots.append(url.path)
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
        // The page keeps the batch standing — pins, text and all — until it hears which of these
        // happened. Send is a request; this is the answer.
        delivery.onLanded = { [weak self] in self?.answer("confirm", $0) }
        delivery.onLost = { [weak self] in self?.answer("reject", $0) }
        return delivery
    }()

    /// The overlay's own two verbs for how a delivery ended. `text` is the receiving row's title or
    /// the reason it never got there; it travels as JSON rather than spliced into the expression,
    /// the same way the target label does at injection.
    private func answer(_ verb: String, _ text: String) {
        guard let client else { return }
        let json = (try? JSONSerialization.data(withJSONObject: [text]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        Guarded.mainTask {
            _ = try await client.send("Runtime.evaluate", [
                "expression": "window.__synthOverlay && window.__synthOverlay.\(verb) && "
                    + "window.__synthOverlay.\(verb)(\(json)[0])",
            ], timeout: 5)
        }
    }

    /// `count` is the batch size, which only ever changes the wording the user sees.
    private func deliver(_ message: String, count: Int = 1, screenshots: [String]) {
        delivery.deliver(message, count: count, screenshots: screenshots)
    }

    // MARK: Helpers

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Guarded.mainTask { [weak self] in
            try await Task.sleep(for: .seconds(4))
            self?.notice = nil
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

    /// The overlay source plus the call that brings it up — evaluated on the current page and on
    /// every new document. `enter` turns the picker on (the mode survives navigation); `restore`
    /// only brings a parked batch back, and does nothing on a page that inherited none.
    static func injectionSource(targetLabel: String, verb: String = "enter") -> String {
        let cfg = (try? JSONSerialization.data(withJSONObject: ["targetLabel": targetLabel]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return (overlayJS ?? "") +
            "\n;window.__synthOverlay && window.__synthOverlay.\(verb) && window.__synthOverlay.\(verb)(\(cfg));"
    }

    /// CommentOverlay.js from the SwiftPM resource bundle. Looked up by hand rather than through
    /// `Bundle.module`, which fatalErrors when the dev bundle misses the copy.
    ///
    /// Nil is a build without the overlay, and `attach` refuses on it. The stub that used to
    /// stand here bound cleanly, answered `exit()` with 'off' and did nothing else — so the bar
    /// lit up, the picker never appeared, and no comment could ever be made or parked. A mode
    /// that cannot work should say so once, not look like it is on.
    private static let overlayJS: String? = {
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
        Fault.report(.browser, .uncaught, severity: .degraded, details: [.stage(.resolve)],
                     evidence: "CommentOverlay.js is not in the resource bundle")
        return nil
    }()
}
