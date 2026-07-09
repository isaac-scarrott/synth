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
            Thread.detachNewThread { [weak self] in self?.handle(conn) }
        }
    }

    /// Read one line (request), answer one line (response), close.
    private func handle(_ conn: Int32) {
        defer { close(conn) }
        var acc = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !acc.contains(0x0A), acc.count < 64 * 1024 {
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
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                response = Self.process(request, store: store)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            var out = data
            out.append(0x0A)
            out.withUnsafeBytes { _ = write(conn, $0.baseAddress, $0.count) }
        }
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

        case "automation.commentMode" where automation:
            guard let session = requestedSession(request, in: branch), session.kind == .browser,
                  let ctrl = BrowserManager.shared.controller(for: session) else {
                return ["ok": false, "error": "no browser session/controller for sessionId"]
            }
            ctrl.toggleCommentMode(store: store)   // the bar button's exact call
            return ["ok": true]

        // Pin which surface a background transition notifies on. Focus normally decides, and a
        // driven instance never holds focus on a live desktop, so neither branch is otherwise
        // reachable. "auto" hands the decision back to focus.
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
                    "notifs": store.notifOrder.map { n -> [String: String] in
                        ["sessionId": n.id.uuidString,
                         "kind": String(describing: n.kind),
                         "title": store.session(n.id)?.title ?? n.title]
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

        case "automation.paletteMove" where automation:
            guard let pal = store.palette else { return ["ok": false, "error": "palette closed"] }
            pal.move(request["delta"] as? Int ?? 1)
            return ["ok": true]

        case "automation.paletteEnter" where automation:
            guard let pal = store.palette else { return ["ok": false, "error": "palette closed"] }
            pal.runActive()
            return ["ok": true]

        case "automation.palette" where automation:
            guard let pal = store.palette else {
                return ["ok": true, "open": false, "menuOpen": store.activeMenu != nil]
            }
            let frame = pal.stack.last
            return ["ok": true, "open": true,
                    "crumb": frame?.crumb ?? "",
                    "items": pal.items.map(\.label),
                    "disabled": pal.items.map(\.disabled),
                    "activeIndex": pal.activeIndex,
                    "menuOpen": store.activeMenu != nil]

        // A window-server-free screenshot: the app caches its own key window's content
        // view into a PNG at `path` — the visual evidence path where TCC denies
        // screencapture window access entirely.
        case "automation.screenshot" where automation:
            guard let path = request["path"] as? String else {
                return ["ok": false, "error": "missing path"]
            }
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
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

    private static var automation: Bool {
        ProcessInfo.processInfo.environment["SYNTH_AUTOMATION"] == "1"
    }

    @MainActor private static func requestedSession(_ request: [String: Any],
                                                    in branch: Branch) -> Session? {
        guard let sid = (request["sessionId"] as? String).flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        return branch.sessions.first { $0.id == sid }
    }
}
