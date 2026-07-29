import AppKit
import Foundation

/// The request/response twin of HookServer (ADR-0008 socket infra, ADR-0011 stage two).
/// The hook socket is strictly one-way — fire a signal, close — so control verbs get
/// their own tiny socket (/tmp/synth-ctl-<pid>.sock, advertised in the instance file)
/// rather than distorting that protocol. Wire format: one JSON-line request per
/// connection, one JSON-line response back.
///
/// Verbs (the MCP server's session tools; everything page-level goes over CDP):
///   {"verb":"browser.list","worktreePath":"…"}
///     → {"ok":true,"sessions":[{"sessionId","title","url","branch","owner"?}]}
///        (owner = the owning claude row's id, stage-four containment)
///   {"verb":"browser.create","worktreePath":"…","url":"…"?,"ownerSessionId":"…"?}
///     → {"ok":true,"sessionId":"…"}   (created exactly like ⌘K New browser:
///        in the matching branch, pre-navigated if url given, selected;
///        ownerSessionId naming a claude row in the branch makes it owned)
///   {"verb":"browser.close","worktreePath":"…","sessionId":"…","ownerSessionId":"…"?}
///     → {"ok":true}   (agent cleanup: closes a browser the calling claude OWNS,
///        exactly as deleting its row would; anything it doesn't own is refused)
///   {"verb":"app.worktreeCreate", …} — the synth-app server's approval-gated create;
///     documented on `worktreePrompt` below (it blocks on the user, unlike everything here).
final class ControlServer: @unchecked Sendable {
    let socketPath = InstanceRegistry.controlSocketPath
    private weak var store: AppStore?
    private var listenFD: Int32 = -1

    @MainActor init(store: AppStore) {
        self.store = store
    }

    func start() {
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: cap) {
                    strncpy($0, src, cap - 1)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0, listen(listenFD, 16) == 0 else { close(listenFD); listenFD = -1; return }
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { if errno == EINTR { continue }; break }
            // A client that connects and hangs up before reading the reply would otherwise
            // raise SIGPIPE on the write below — whose default action kills Synth. Any local
            // process could take the app down by probing the socket. Fail the write instead.
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // A silent peer that connects but never sends a newline would otherwise park its
            // handler thread + fd in read() for the app's lifetime. Time the read out so the
            // n <= 0 break fires and the defer close(conn) releases both.
            var rcvto = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &rcvto, socklen_t(MemoryLayout<timeval>.size))
            Thread.detachNewThread { [weak self] in self?.handle(conn) }
        }
    }

    /// Read one line (request), answer one line (response), close. The request line is
    /// capped at 256 KB — app.worktreeCreate carries a whole handoff brief, and a giant
    /// paste shouldn't silently truncate to unparseable JSON.
    private func handle(_ conn: Int32) {
        defer { close(conn) }
        var acc = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !acc.contains(0x0A), acc.count < 256 * 1024 {
            let n = read(conn, &buf, buf.count)
            if n <= 0 { break }
            acc.append(contentsOf: buf[0..<n])
        }
        let line = acc.firstIndex(of: 0x0A).map { acc.prefix(upTo: $0) } ?? acc
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]

        // The store is main-actor state; hop over synchronously — this runs on a
        // per-connection thread, so blocking it is free.
        var response: [String: Any] = ["ok": false, "error": "Synth is shutting down"]
        let store = self.store
        if request["verb"] as? String == "app.worktreeCreate" {
            // The one verb that waits on the user — it parks THIS thread, never main.
            response = Self.worktreePrompt(request, store: store)
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    response = Self.process(request, store: store)
                }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            var out = data
            out.append(0x0A)
            out.withUnsafeBytes { _ = write(conn, $0.baseAddress, $0.count) }
        }
    }

    /// synth-app's worktree_create (ADR-0011's control-socket infra, new server):
    ///   {"verb":"app.worktreeCreate","worktreePath":"…","branch":"…",
    ///    "base":"…"?,"handoff":"…"?,"ownerSessionId":"…"?}
    ///     → {"ok":true,"decision":"created","branch":"…","worktreePath":"…"}
    ///     | {"ok":true,"decision":"declined"}
    ///     | {"ok":true,"decision":"exists","worktreePath":"…"}   (already a row — no prompt)
    ///     | {"ok":false,"error":"…"}
    /// The store queues the user prompt and this connection's thread parks on the
    /// semaphore until the sheet answers (or 4 minutes pass — just under the MCP
    /// server's own socket timeout, so the agent reads a real answer, not a dead pipe).
    private static func worktreePrompt(_ request: [String: Any], store: AppStore?) -> [String: Any] {
        final class Box: @unchecked Sendable {
            let sem = DispatchSemaphore(value: 0)
            var response: [String: Any]?   // written on main before signal; read after wait
        }
        let box = Box()
        var immediate: [String: Any]?
        var promptID: UUID?
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                guard let store else { immediate = ["ok": false, "error": "store gone"]; return }
                switch store.beginAgentWorktreePrompt(request, respond: { resp in
                    box.response = resp
                    box.sem.signal()
                }) {
                case .immediate(let resp): immediate = resp
                case .pending(let id):     promptID = id
                }
            }
        }
        if let immediate { return immediate }
        if box.sem.wait(timeout: .now() + 240) == .timedOut {
            var response: [String: Any] = ["ok": false, "error":
                "the user didn't answer the worktree prompt within 4 minutes — " +
                "ask them directly, then retry if they want it"]
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    // If the user answered in the race window the prompt is already gone —
                    // return their real answer instead of the timeout.
                    if let id = promptID, store?.cancelAgentPrompt(id) == false,
                       let answered = box.response {
                        response = answered
                    }
                }
            }
            return response
        }
        return box.response ?? ["ok": false, "error": "internal: prompt resolved without a response"]
    }

    @MainActor private static func process(_ request: [String: Any], store: AppStore?) -> [String: Any] {
        guard let store else { return ["ok": false, "error": "store gone"] }
        guard let verb = request["verb"] as? String else {
            return ["ok": false, "error": "missing verb"]
        }
        guard let worktreePath = request["worktreePath"] as? String,
              let branch = store.branch(forWorktreePath: worktreePath) else {
            return ["ok": false,
                    "error": "no Synth branch manages worktree \(request["worktreePath"] ?? "<missing>")"]
        }

        switch verb {
        case "browser.list":
            let sessions = branch.sessions.filter { $0.kind == .browser }.map { s in
                var entry: [String: Any] = ["sessionId": s.id.uuidString,
                                            "title": s.title,
                                            "url": s.browserURL?.absoluteString ?? "",
                                            "branch": branch.name]
                // Stage four: owned rows are annotated, never hidden — the shared surface.
                if let owner = s.ownerSessionID { entry["owner"] = owner.uuidString }
                return entry
            }
            return ["ok": true, "sessions": sessions]

        case "browser.create":
            let url = (request["url"] as? String).flatMap(URL.fromBrowserInput)
            // Stage four creation stamping: the calling agent names its own Synth row and
            // becomes the owner. Valid only for an agent-kind row in this branch; anything
            // else (absent, malformed, external agent) just creates an unowned sibling —
            // ownership is best-effort, never an error.
            let ownerID = (request["ownerSessionId"] as? String).flatMap(UUID.init(uuidString:))
            let owner = ownerID.flatMap { id in
                branch.sessions.first { $0.id == id && $0.kind.isAgent }
            }
            // focus: false — an agent-created browser never steals the pane; the row
            // announces itself with the unread bullet and the engine boots detached
            // (next runloop turn), so callers still poll CDP for the target as before.
            guard let session = store.newBrowser(in: branch, at: url, ownedBy: owner, focus: false) else {
                return ["ok": false, "error": "session creation failed"]
            }
            return ["ok": true, "sessionId": session.id.uuidString]

        case "browser.close":
            guard let session = requestedSession(request, in: branch), session.kind == .browser else {
                return ["ok": false, "error": "no browser session for sessionId"]
            }
            // An agent may clean up only what it made. Ownership is the record of that, and
            // it changes only by the user (stage four) — so a ⌘K browser, one the user
            // detached, and one re-parented to another claude are all beyond reach here.
            guard let caller = (request["ownerSessionId"] as? String).flatMap(UUID.init(uuidString:)) else {
                return ["ok": false,
                        "error": "this Claude session has no Synth row, so it owns no browsers — " +
                                 "only the session that created a browser may close it"]
            }
            guard session.ownerSessionID == caller else {
                let whose = session.ownerSessionID == nil ? "unowned — the user's"
                                                          : "owned by another Claude session"
                return ["ok": false,
                        "error": "browser \(session.id.uuidString) is \(whose); only its owner may " +
                                 "close it. Ask the user to close it if it's in the way."]
            }
            // Comment mode engaged means the user is picking an element or composing right now;
            // closing would delete what they were about to send back to this very session.
            if BrowserManager.shared.existing(session.id)?.commentMode?.engaged == true {
                return ["ok": false,
                        "error": "the user is commenting in this browser — leave it open"]
            }
            store.closeSession(session)
            return ["ok": true]

        // Device mode (working.html devframe): read or set a browser session's device
        // frame, so an agent can check the page it is working on at a phone or tablet
        // viewport. Any agent may drive any browser (stage four: driving isn't
        // destroying), so unlike browser.close there is no ownership gate.
        case "browser.deviceMode":
            guard let session = requestedSession(request, in: branch), session.kind == .browser,
                  let ctrl = BrowserManager.shared.controller(for: session) else {
                return ["ok": false, "error": "no browser session for sessionId"]
            }
            let wantsChange = request["on"] != nil || request["device"] != nil
                           || request["landscape"] != nil
            if wantsChange {
                var picked: BrowserDevice?
                if let id = request["device"] as? String {
                    guard let d = BrowserDevice.fleet.first(where: { $0.id == id }) else {
                        return ["ok": false,
                                "error": "unknown device '\(id)' — one of: " +
                                         BrowserDevice.fleet.map(\.id).joined(separator: ", ")]
                    }
                    picked = d
                }
                guard !ctrl.isHome else {
                    return ["ok": false,
                            "error": "the session shows the \"go to\" home — device mode needs a page; navigate first"]
                }
                if let d = picked { ctrl.setDevice(d) }
                if let land = request["landscape"] as? Bool { ctrl.setDeviceLandscape(land) }
                // Naming a device or orientation is asking for the mode; only an
                // explicit on:false turns it off.
                ctrl.setDeviceMode(on: request["on"] as? Bool ?? true)
            }
            // `viewport` is what the page gets — the screen minus the device browser's
            // own bars, which is the number a media query sees; `screen` is the hardware.
            let page = ctrl.device.pageViewport(landscape: ctrl.deviceLandscape)
            let screen = ctrl.device.screenSize(landscape: ctrl.deviceLandscape)
            return ["ok": true,
                    "on": ctrl.deviceModeOn,
                    "device": ctrl.device.id,
                    "landscape": ctrl.deviceLandscape,
                    "viewport": ["width": Int(page.width), "height": Int(page.height)],
                    "screen": ["width": Int(screen.width), "height": Int(screen.height)],
                    "devices": BrowserDevice.fleet.map {
                        ["id": $0.id, "name": $0.name,
                         "width": Int($0.width), "height": Int($0.height)]
                    }]

        // Automation verbs (SYNTH_AUTOMATION=1 only): the self-verify harness's
        // stand-in for driving the real UI on machines whose TCC denies synthetic
        // input. Each maps 1:1 onto the exact call the UI performs — no separate
        // logic — so exercising a verb exercises the product path.
        // `agent` names which one (an AgentID rawValue); absent means Claude Code, the verb's
        // original and only meaning.
        case "automation.newAgent" where automation, "automation.newClaude" where automation:
            let agent = (request["agent"] as? String).map(AgentID.init) ?? .claudeCode
            guard let session = store.newAgent(agent, in: branch) else {
                return ["ok": false, "error": "session creation failed"]
            }
            return ["ok": true, "sessionId": session.id.uuidString]

        // The feedback sheet's Send (⌘⇧F → ⌘↵): fill the two fields the sheet binds and make
        // its exact call. ⌘↵ is a SwiftUI keyboard shortcut, which a synthetic key event can't
        // reach in a window that isn't key — so the author loop (worktree, seeded agent, and
        // the email fallbacks when there is no workspace or no agent left on) is otherwise
        // undrivable headlessly.
        case "automation.feedback" where automation:
            store.feedbackTitle = request["title"] as? String ?? ""
            store.feedbackDraft = request["body"] as? String ?? ""
            store.submitFeedback(store.feedbackDraft)
            return ["ok": true, "mode": String(describing: store.feedbackMode)]

        case "automation.commentMode" where automation:
            guard let session = requestedSession(request, in: branch), session.kind == .browser,
                  let ctrl = BrowserManager.shared.controller(for: session) else {
                return ["ok": false, "error": "no browser session/controller for sessionId"]
            }
            ctrl.toggleCommentMode(store: store)   // the bar button's exact call
            return ["ok": true]

        // Pin which focus rule a background transition follows: "deck" the frontmost case (deck
        // only), "nc" the unfocused one (Notification Center on top of the deck). Focus normally
        // decides, and a driven instance never holds focus on a live desktop, so the frontmost
        // branch is otherwise unreachable. "auto" hands the decision back to focus.
        case "automation.notifRoute" where automation:
            switch request["route"] as? String {
            case "deck": store.automationNotifRoute = .inApp
            case "nc":   store.automationNotifRoute = .notificationCenter
            case "auto": store.automationNotifRoute = nil
            default: return ["ok": false, "error": "route must be deck|nc|auto"]
            }
            return ["ok": true, "active": NSApp.isActive]

        // Cut a new worktree — the ⌘K "Create worktree" frame's exact call, template spawn and
        // all. Returns the path the checkout will land at so the harness can watch it fill.
        case "automation.createWorktree" where automation:
            guard let ws = store.workspace(of: branch), let newBranch = request["branch"] as? String else {
                return ["ok": false, "error": "need branch"]
            }
            let planned = GitService.plannedWorktreePath(repo: ws.url, branch: newBranch)
            store.createWorktree(in: ws, newBranch: newBranch, base: request["base"] as? String)
            return ["ok": true, "worktreePath": planned.path]

        // The synth-app approval prompt, drivable headless: list what's pending and
        // answer it — resolve is the ⌘K confirm frame's exact call.
        case "automation.agentPrompts" where automation:
            return ["ok": true, "prompts": store.agentPrompts.map { p -> [String: Any] in
                ["promptId": p.id.uuidString,
                 "workspace": p.workspace.name,
                 "branch": p.branchName,
                 "base": p.base ?? "",
                 "hasHandoff": p.handoff != nil,
                 "requester": p.requesterTitle ?? ""]
            }]

        case "automation.agentPromptResolve" where automation:
            guard let id = (request["promptId"] as? String).flatMap(UUID.init(uuidString:)),
                  let prompt = store.agentPrompts.first(where: { $0.id == id }),
                  let approved = request["approved"] as? Bool else {
                return ["ok": false, "error": "need promptId + approved"]
            }
            store.resolveAgentPrompt(prompt, approved: approved)
            return ["ok": true]

        // Hand text to a live agent exactly as a browser comment does (CommentMode rung 1),
        // so exercising the verb exercises the product path.
        case "automation.deliver" where automation:
            guard let session = requestedSession(request, in: branch),
                  let text = request["text"] as? String else {
                return ["ok": false, "error": "need sessionId + text"]
            }
            guard let supervisor = store.liveSupervisor(for: session) else {
                return ["ok": false, "error": "no live agent for sessionId"]
            }
            return ["ok": supervisor.deliver(text, to: session.id)]

        // Every session row's derived facts — what the sidebar renders. The seam the agent
        // self-verify harness reads to prove a supervisor is driving kind/status/title.
        case "automation.sessions" where automation:
            let rows = branch.sessions.map { s -> [String: Any] in
                ["sessionId": s.id.uuidString,
                 "kind": s.kind.rawValue,
                 "title": s.title,
                 "status": String(describing: s.status),
                 "unread": s.unread,
                 "liveAgent": store.isLiveAgent(s.id),
                 "agentSessionId": s.agentSessionID ?? ""]
            }
            return ["ok": true, "sessions": rows]

        case "automation.state" where automation:
            guard let session = requestedSession(request, in: branch),
                  let ctrl = BrowserManager.shared.existing(session.id) else {
                return ["ok": false, "error": "no browser controller for sessionId"]
            }
            return ["ok": true,
                    "commentModeActive": ctrl.commentMode?.active ?? false,
                    "targetTitle": ctrl.commentMode?.targetTitle ?? "",
                    "notice": ctrl.commentMode?.notice ?? "",
                    "address": ctrl.address?.absoluteString ?? "",
                    "isHome": ctrl.isHome,
                    "canGoBack": ctrl.canGoBack,
                    "canGoForward": ctrl.canGoForward,
                    "devToolsOpen": ctrl.devToolsOpen]

        // Drill the palette to a session row's frame — the row kebab's exact call.
        case "automation.rowActions" where automation:
            guard let session = requestedSession(request, in: branch) else {
                return ["ok": false, "error": "no session for sessionId"]
            }
            store.openRowActions(.session(session))
            return ["ok": true]

        // Open a session exactly as a palette jump would.
        case "automation.jump" where automation:
            guard let session = requestedSession(request, in: branch) else {
                return ["ok": false, "error": "no session for sessionId"]
            }
            store.jump(to: session)
            return ["ok": true]

        // The layout spine's test handle (009) — the native equivalent of window.SynthLayout.
        // Report the on-screen pane tree so a harness can assert multi-pane render without pixels.
        case "automation.layout" where automation:
            func describe(_ n: PaneNode?) -> Any {
                guard let n else { return NSNull() }
                if n.isLeaf {
                    return ["leaf": true,
                            "session": n.sessionID?.uuidString ?? "",
                            "setup": n.setupBranchID?.uuidString ?? "",
                            "active": n === store.activePane]
                }
                return ["leaf": false, "dir": n.dir?.rawValue ?? "row", "split": n.split,
                        "a": describe(n.a), "b": describe(n.b)]
            }
            return ["ok": true, "panes": store.paneLeaves.count, "tree": describe(store.layout)]

        // Drive a split: subdivide the active pane with `sessionId` (an already-open session moves
        // rather than duplicating — 010's rule). The keyboard/mouse create routes funnel through the
        // same splitPane op; this is the headless driver that proves the spine renders ≥2 panes.
        case "automation.split" where automation:
            guard let session = requestedSession(request, in: branch) else {
                return ["ok": false, "error": "no session for sessionId"]
            }
            guard let target = store.activePane, target.isLeaf else {
                return ["ok": false, "error": "no single-leaf active pane to split"]
            }
            let dir: SplitDir = (request["dir"] as? String == "col") ? .col : .row
            let before = request["before"] as? Bool ?? false
            if let existing = store.leaf(of: session.id), existing !== target {
                store.removeLeaf(existing)   // move, don't duplicate
            }
            store.splitPane(target, session: session.id, dir: dir, before: before)
            return ["ok": true, "panes": store.paneLeaves.count]

        // Drive the mouse drag-to-split drop model (010) headlessly: resolve the pointer (x,y in
        // content coordinates, with the content size) to a zone and apply it — the exact call the
        // content DropDelegate makes on drop, minus the un-drivable system drag gesture.
        case "automation.drop" where automation:
            guard let session = requestedSession(request, in: branch),
                  let x = request["x"] as? Double, let y = request["y"] as? Double,
                  let w = request["w"] as? Double, let h = request["h"] as? Double else {
                return ["ok": false, "error": "need sessionId, x, y, w, h"]
            }
            let dz = store.resolveDrop(at: CGPoint(x: x, y: y),
                                       contentSize: CGSize(width: w, height: h), dragging: session.id)
            let kind: String
            switch dz.kind {
            case .split: kind = "split"; case .rim: kind = "rim"; case .refuse: kind = "refuse"
            }
            if let zone = dz.zone { store.performDrop(session: session.id, zone: zone) }
            return ["ok": true, "kind": kind, "applied": dz.zone != nil, "panes": store.paneLeaves.count]

        // Navigate a browser session — the home "Go to…" field's exact onSubmit call.
        case "automation.browserGo" where automation:
            guard let session = requestedSession(request, in: branch), session.kind == .browser,
                  let ctrl = BrowserManager.shared.controller(for: session),
                  let url = request["url"] as? String else {
                return ["ok": false, "error": "no browser session/controller/url"]
            }
            return ["ok": ctrl.go(url)]

        // Post a real key event through the app's own queue, so the RootView key
        // monitor sees it exactly as a typed key — the window-wide-shortcut test
        // path where TCC swallows CGEvent postToPid entirely.
        // What "Quit Synth?" would say, without presenting it — a modal the harness answered would
        // either kill the instance under test or hang waiting. The sentence is the assertion:
        // it is the only place a running scratch terminal (no row, invisible to `busySessions`)
        // can announce that quitting is about to end it.
        case "automation.quitPrompt" where automation:
            return ["ok": true,
                    "informative": store.quitInformativeText,
                    "busySessions": store.busySessions.count,
                    "scratchCommand": store.busyScratchCommand ?? ""]

        // The ⌘? sheet's live contents. Worth a verb of its own: the HTML design file shipped a
        // shortcuts sheet that threw on every open — for months, silently — because nothing could
        // assert it rendered. A binding that isn't listed here doesn't exist to the user.
        case "automation.shortcuts" where automation:
            return ["ok": true,
                    "open": store.shortcutsOpen,
                    "category": store.shortcutsCategory,
                    "categories": ShortcutsSheet.categoryNames(tabsMode: store.tabsMode),
                    "rows": ShortcutsSheet.rowLabels(tabsMode: store.tabsMode)]

        // The scratch terminal (⌘⇧T) has no sidebar row by design, so `automation.sessions` and
        // `automation.nav` can't see it — this is the only seam that can prove it exists, which
        // branch it runs in, and whether a job is holding the foreground (the fact that decides
        // whether Esc reaches the shell and whether dismissing confirms).
        case "automation.scratch" where automation:
            switch request["action"] as? String ?? "state" {
            case "open":    store.openScratchTerminal()
            case "close":   store.requestCloseScratchTerminal()
            case "confirm": store.closeScratchTerminal()
            case "cancel":  store.scratchConfirmOpen = false
            case "run":
                guard let s = store.scratch, let text = request["text"] as? String else {
                    return ["ok": false, "error": "no scratch terminal / missing text"]
                }
                _ = TerminalManager.shared.submit(text, to: s.session.id)
            default: break
            }
            return ["ok": true,
                    "open": store.scratch != nil,
                    "busy": store.scratch?.busy ?? false,
                    "confirmOpen": store.scratchConfirmOpen,
                    "branch": store.scratch?.branchName ?? "",
                    "command": store.scratch?.runningCommand ?? ""]

        case "automation.key" where automation:
            guard let code = request["keyCode"] as? Int else {
                return ["ok": false, "error": "missing keyCode"]
            }
            var mods = NSEvent.ModifierFlags()
            for m in request["mods"] as? [String] ?? [] {
                switch m {
                case "cmd":   mods.insert(.command)
                case "shift": mods.insert(.shift)
                case "opt":   mods.insert(.option)
                case "ctrl":  mods.insert(.control)
                default: break
                }
            }
            let chars = request["chars"] as? String ?? ""
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.windows.first(where: { $0.isVisible })?.windowNumber ?? 0,
                context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: UInt16(code)) else {
                return ["ok": false, "error": "event build failed"]
            }
            NSApp.postEvent(event, atStart: false)
            return ["ok": true]

        // The in-app deck exactly as NotificationDeck renders it (store.notifOrder), plus the
        // focus fact that decides deck-vs-Notification-Center routing — so a headless harness
        // can assert what toasts are standing without pixels.
        case "automation.notifs" where automation:
            return ["ok": true,
                    "active": NSApp.isActive,
                    // Every Notification Center post this run would have made, recorded instead of
                    // delivered (NotificationService.add) — the unfocused branch, assertable.
                    "nc": NotificationService.shared.captured,
                    "notifs": store.notifOrder.map { n -> [String: String] in
                        ["sessionId": n.id.uuidString,
                         "kind": String(describing: n.kind),
                         "title": store.session(n.id)?.title ?? n.title,
                         // The rest of the card, so a harness can assert the tier system without
                         // pixels: which tier it belongs to, its verb line, the evidence under it,
                         // what its button offers, and whether it is running a countdown.
                         "tier": n.tier.rawValue,
                         "message": n.message ?? notifVerb(store.session(n.id)?.kind ?? n.sessionKind, n.kind),
                         "sub": n.sub ?? "",
                         "action": n.action?.label ?? "",
                         "destructive": String(n.destructive),
                         "drains": String(n.drains)]
                    }]

        // The sidebar tree as navigation sees it — rows, keyboard cursor, open session —
        // so the harness can assert row lifecycle and cursor fallback without pixels.
        case "automation.nav" where automation:
            return ["ok": true,
                    "openSessionId": store.openSessionID?.uuidString ?? "",
                    "navCursor": store.navCursor?.uuidString ?? "",
                    "branchId": branch.id.uuidString,
                    "rows": branch.sessions.map { s -> [String: String] in
                        ["sessionId": s.id.uuidString,
                         "kind": s.kind.rawValue,
                         "title": s.title,
                         "status": String(describing: s.status),
                         "unread": String(s.unread)]
                    }]

        // The `d` shortcut and the ⌘K palette keys, addressable where TCC blocks
        // synthetic keystrokes — each verb is the exact call the key handler makes.
        case "automation.requestDelete" where automation:
            guard let session = requestedSession(request, in: branch) else {
                return ["ok": false, "error": "no session for sessionId"]
            }
            store.requestDelete(.session(session))
            return ["ok": true]

        // Archive a branch row by name, and force a sweep. Without these the sweeper is only
        // testable by waiting a week — `SYNTH_ARCHIVE_*_SECONDS` compress the clocks, and this
        // drives the rest. The evidence comes back per branch so a harness can assert on *why*
        // something was kept, not just that nothing happened.
        case "automation.archiveBranch" where automation:
            guard let name = request["branch"] as? String,
                  let target = store.workspaces.flatMap(\.branches).first(where: { $0.name == name })
            else { return ["ok": false, "error": "no branch named \(request["branch"] ?? "")"] }
            store.softArchiveBranch(target)
            return ["ok": true]

        // The one destructive undo — its expiry deletes the folder. Only reachable through ⌘K's
        // confirm frame in the UI, which a headless harness can't drill to for a branch row.
        case "automation.deleteWorktreeNow" where automation:
            guard let name = request["branch"] as? String,
                  let target = store.workspaces.flatMap(\.branches).first(where: { $0.name == name })
            else { return ["ok": false, "error": "no branch named \(request["branch"] ?? "")"] }
            store.deleteWorktreeNow(target)
            return ["ok": true]

        // The tick runs git off the main actor, so this kicks it off and returns; the harness
        // polls `automation.archiveStatus` for the verdicts it settled on.
        case "automation.archiveSweep" where automation:
            Task { await store.sweepTick(force: true) }
            return ["ok": true]

        // Say "focus came back". Self-dismissing cards bank their remaining life while Synth
        // isn't frontmost — right for a user, and a headless instance never is, so without this
        // a harness can only observe that a card was raised, never that it goes away by itself.
        case "automation.notifFocus" where automation:
            store.setAutomationAppActive(request["active"] as? Bool ?? true)
            return ["ok": true]

        // A card's primary action — its button, a click on its body, and ⌘↩ all land here. Its
        // twin is notifDismiss below; that the two do DIFFERENT things is the thing under test.
        case "automation.notifAction" where automation:
            guard let raw = request["sessionId"] as? String, let id = UUID(uuidString: raw) else {
                return ["ok": false, "error": "need sessionId"]
            }
            store.runNotifAction(id)
            return ["ok": true]

        // The × on a card, addressable by the id the deck reports. Distinct from a click, which
        // runs the card's action — that difference is the thing under test.
        case "automation.notifDismiss" where automation:
            guard let raw = request["sessionId"] as? String, let id = UUID(uuidString: raw) else {
                return ["ok": false, "error": "need sessionId"]
            }
            store.dismissNotif(id)
            return ["ok": true]

        // Undo cards don't drain while the app is unfocused, and a headless one never is —
        // so a harness has to say "the window elapsed" out loud.
        case "automation.notifDrain" where automation:
            store.drainPendingUndos()
            return ["ok": true]

        // Stage a build without Sparkle: same path the real `willInstallUpdateOnQuit` takes, with
        // an installer that records the ask instead of relaunching (a harness can't assert on an
        // instance that just quit). `daysAgo` back-dates the arrival so the reminder's ageing
        // sub-line is readable without waiting days for it.
        case "automation.updateStage" where automation:
            let version = request["version"] as? String ?? "9.9.9"
            store.stageStubUpdate(version: version,
                                  daysAgo: (request["daysAgo"] as? NSNumber)?.doubleValue ?? 0)
            return ["ok": true]

        // "The day rolled over" — the daily reminder, without a day.
        case "automation.updateRemind" where automation:
            store.showUpdateCard()
            return ["ok": true]

        case "automation.updateStatus" where automation:
            return ["ok": true,
                    "pending": store.stagedUpdate != nil,
                    "version": store.stagedUpdate?.version ?? "",
                    "sub": store.updateSubline(),
                    "installRequested": store.updateInstallRequested]

        case "automation.archiveRestore" where automation:
            guard let name = request["branch"] as? String,
                  let target = store.workspaces.flatMap(\.branches)
                    .first(where: { $0.name == name && $0.isArchived })
            else { return ["ok": false, "error": "no archived branch named \(request["branch"] ?? "")"] }
            return ["ok": store.restoreArchivedBranch(target)]

        // The branch rows the sidebar draws, workspace by workspace. `archiveStatus` proves a
        // row reached the Archived list; only this proves it left the tree. The two were assumed
        // to be one fact, and they weren't: the sidebar rendered `branches` while everything else
        // read the archive filter, so an archived row walked back into the tree the moment the
        // undo window committed it.
        case "automation.tree" where automation:
            return ["ok": true,
                    "workspaces": store.workspaces.map { ws -> [String: Any] in
                        ["workspace": ws.name,
                         "count": ws.liveBranches.count,
                         "branches": ws.liveBranches.map(\.name)]
                    }]

        case "automation.archiveStatus" where automation:
            return ["ok": true,
                    "archived": store.workspaces.flatMap { store.archivedBranches(in: $0) }.map { br in
                        ["branch": br.name, "status": store.archiveStatusLine(br),
                         "reason": store.archiveReason(br),
                         "held": String(store.heldFolder(for: br) != nil)]
                    }]

        case "automation.paletteMove" where automation:
            guard let pal = store.palette else { return ["ok": false, "error": "palette closed"] }
            pal.move(request["delta"] as? Int ?? 1)
            return ["ok": true]

        case "automation.paletteEnter" where automation:
            guard let pal = store.palette else { return ["ok": false, "error": "palette closed"] }
            pal.runActive()
            return ["ok": true]

        // Open ⌘K the way the shortcut does, without synthesizing a key event. A headless
        // instance is never frontmost, so a posted ⌘K resolves against whichever window
        // `NSApp.windows` happens to hand back first and may never reach the shortcut at all.
        case "automation.paletteOpen" where automation:
            if store.palette != nil { store.closePalette() }   // Esc, then ⌘K
            store.openPalette()
            fallthrough

        // Say what the palette's search field holds. While the palette is open that field owns
        // first responder, so any keystroke this machine delivers — the developer typing into
        // their own Synth, another harness driving a sibling instance — lands in the query and
        // silently re-filters the rows. A gate asserting on a frame has to be able to state the
        // query rather than inherit whatever arrived, which is why this sets it and reports the
        // frame in one round trip: nothing can drift in between.
        case "automation.paletteQuery" where automation:
            store.palette?.query = request["query"] as? String ?? ""
            fallthrough

        case "automation.palette" where automation:
            guard let pal = store.palette else {
                return ["ok": true, "open": false, "menuOpen": store.activeMenu != nil]
            }
            let frame = pal.stack.last
            return ["ok": true, "open": true,
                    "crumb": frame?.crumb ?? "",
                    // What the rows were filtered by — the difference between "the feature
                    // offered the wrong rows" and "something typed into the palette".
                    "query": pal.query,
                    // The line above the rows — a confirm's reason, a new branch's base. It is
                    // copy, and copy is the thing these frames exist to get right.
                    "note": pal.noteText ?? "",
                    "items": pal.items.map(\.label),
                    "disabled": pal.items.map(\.disabled),
                    // ADR-0013: red marks loss, so a harness must be able to see which rows wear it.
                    "danger": pal.items.map(\.danger),
                    "activeIndex": pal.activeIndex,
                    "menuOpen": store.activeMenu != nil]

        // A window-server-free screenshot: the app caches its own key window's content
        // view into a PNG at `path` — the visual evidence path where TCC denies
        // screencapture window access entirely.
        case "automation.screenshot" where automation:
            guard let path = request["path"] as? String else {
                return ["ok": false, "error": "missing path"]
            }
            // The ⌘K palette floats in its own NSPanel above the main window, so a capture that
            // always grabs the first visible window renders a palette-open moment with no palette
            // in it. Prefer the panel — the front of what the user sees. But a tooltip is an
            // NSPanel too, and one resting over the window silently hijacks every capture, so
            // `"window":"main"` asks for the app's own window and ignores whatever floats above it.
            let visible = NSApp.windows.filter(\.isVisible)
            let target = request["window"] as? String == "main"
                ? visible.first { !($0 is NSPanel) }
                : (visible.first { $0 is NSPanel } ?? visible.first)
            guard let view = target?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return ["ok": false, "error": "no visible window to render"]
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                return ["ok": false, "error": "png encode failed"]
            }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch {
                return ["ok": false, "error": String(describing: error)]
            }
            return ["ok": true, "path": path]

        default:
            return ["ok": false, "error": "unknown verb \(verb)"]
        }
    }

    private static var automation: Bool { Automation.isDriven }

    @MainActor private static func requestedSession(_ request: [String: Any],
                                                    in branch: Branch) -> Session? {
        guard let sid = (request["sessionId"] as? String).flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        return branch.sessions.first { $0.id == sid }
    }
}
