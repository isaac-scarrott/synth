import Foundation
import OSLog

/// opencode2 (OpenCode's v2 preview CLI): the same "subscribe, don't instrument" shape as
/// `OpencodeSupervisor`, over a materially different transport. v1 is one unauthenticated server
/// per session, printing everything at the root (`/event`, `/tui/*`, `/global/health`). v2 splits
/// the TUI from its server (`serve`, reachable over `--server <url>`), gates every route behind
/// HTTP Basic auth (user `opencode`, a password the server would normally mint itself), and moves
/// the real API under `/api/*` — `/api/event`, `/api/health`, `/api/session/*` — leaving the bare
/// paths serving its web UI's HTML shell.
///
/// The port and password are both minted here, same as v1's port, and both ride the launch:
/// `synth-hook` starts `opencode2 serve --port <port>` with `OPENCODE_PASSWORD=<password>` in its
/// own environment, waits for it to actually answer (v2's `--server` does not retry a server that
/// isn't up yet — it dies with a "could not reach server" error, verified empirically), and only
/// then starts the visible TUI as `opencode2 --server http://127.0.0.1:<port>` with the same
/// password so it can authenticate to the server it just watched come up. Two processes, but one
/// row: the shim reports the *TUI's* exit as the row's end, and tears the server down with it.
///
/// v2 has no equivalent of v1's `/tui/append-prompt` — verified empirically (creating a session
/// over the API does not make an already-open TUI display it; `POST .../view` only acknowledges an
/// idle notification, and the internal `tui.session.select`/`tui.prompt.append` commands the binary
/// still carries strings for are never exposed over HTTP). So delivery here is the same paste-and-
/// submit `TerminalManager` already does for Claude Code, confirmed live against a real TUI: typed
/// text lands in its prompt box and a trailing Enter submits it.
@MainActor final class Opencode2Supervisor: AgentSupervisor {
    let id = AgentID.opencode2

    private weak var bus: EventBus?
    private static let log = Logger(subsystem: bundleIdentifier, category: "opencode2")

    /// The `serve` port assigned per session, handed to the shim as `SYNTH_OPENCODE2_PORT`.
    private var ports: [UUID: Int] = [:]
    /// The Basic-auth password minted per session, handed over as `SYNTH_OPENCODE2_PASSWORD` — the
    /// one thing v1 never needed, because its server took no credentials at all.
    private var passwords: [UUID: String] = [:]
    private var streams: [UUID: Opencode2EventStream] = [:]
    /// opencode2's own session id for each row. Subagent sessions are excluded the same way v1
    /// excludes them, but v2's `session.created` payload was never observed carrying a `parentID`
    /// in this preview build — the check is kept for forward compatibility (a field a preview adds
    /// later degrades gracefully into exactly what v1 already does) rather than depended upon.
    private var agentSessionIDs: [UUID: String] = [:]
    private var childSessionIDs: [UUID: Set<String>] = [:]
    /// Bumped whenever a row's session is created or a turn starts — `deliverConfirmed` watches it
    /// to tell a paste the TUI accepted from one it dropped while still booting.
    private var turnTicks: [UUID: Int] = [:]

    init(bus: EventBus) { self.bus = bus }

    // MARK: Launch

    func decorate(_ env: inout [String: String], sessionID: UUID, agent: AgentDescriptor) {
        guard agent.resolvedCommand != nil else { return }
        let port = ports[sessionID] ?? Self.freePort()
        ports[sessionID] = port
        let password = passwords[sessionID] ?? Self.generatePassword()
        passwords[sessionID] = password

        agent.exportRealCommand(into: &env)
        env["SYNTH_OPENCODE2_PORT"] = String(port)
        env["SYNTH_OPENCODE2_PASSWORD"] = password
        // A relaunch of the same row reuses the path, so the previous server's log goes with it —
        // what is wanted there is why *this* one died, not why the last one did.
        env["SYNTH_OPENCODE2_LOG"] = Self.logPath(sessionID)
        try? FileManager.default.createDirectory(atPath: Self.root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: Self.logPath(sessionID))
        // An embedded agent must not self-update mid-session — the same rule `OpencodeSupervisor`
        // and `AntigravitySupervisor` both apply, and v2 reads the same variable v1 does.
        env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        Self.adoptKeybinds()
    }

    func launchCommand(binary: String, resume: String?, flags: String) -> String {
        let extra = flags.isEmpty ? "" : " " + flags
        if let resume { return "exec \(binary) --session \(shellQuoteAgentArg(resume))\(extra)" }
        return "exec \(binary)\(extra)"
    }

    // MARK: Supervision

    /// A resumed row's `session.created` never fires for its own conversation — only for a
    /// subagent's, if any turn ever starts one — so `isRowSession`'s own fallback (treat an event
    /// as the row's own until some id is known) would otherwise wait forever to learn which id is
    /// "its own", and would treat a subagent's as that answer the first time one shows up. Seeding
    /// it here, before `attach` starts the stream, means the very first event is already correctly
    /// filtered instead of racing a subagent for the slot.
    func seedResume(session: UUID, resumeID: String) {
        agentSessionIDs[session] = resumeID
    }

    func attach(session: UUID) {
        guard streams[session] == nil, let port = ports[session], let password = passwords[session]
        else { return }
        let stream = Opencode2EventStream(
            port: port, password: password,
            onOpen: {
                Task { @MainActor [weak self] in self?.bus?.post(.agentReady(session)) }
            },
            onEvent: { event in
                Task { @MainActor [weak self] in self?.handle(event, session: session) }
            }
        )
        streams[session] = stream
        stream.start()
    }

    func detach(session: UUID) {
        streams[session]?.stop()
        streams[session] = nil
        agentSessionIDs[session] = nil
        childSessionIDs[session] = nil
        turnTicks[session] = nil
        ports[session] = nil
        passwords[session] = nil
    }

    // MARK: Delivery

    /// No injection API survives from v1 (see the type doc) — this is a plain terminal paste, the
    /// same path Claude Code's supervisor uses. But `agentReady` fires once the *server* answers,
    /// not once the visible TUI process has actually started reading its own stdin — confirmed
    /// live that a paste landing in that gap is silently dropped, the same race v1's own TUI-fill
    /// API had to survive (its comment: "the server starts listening before the TUI subscribes to
    /// it"). So this re-pastes until a turn actually starts, watched over the event stream rather
    /// than a confirmation response, since a terminal paste has none.
    func deliver(_ text: String, to session: UUID) -> Bool {
        guard ports[session] != nil else { return false }
        Task { await self.deliverConfirmed(text, session: session) }
        return true
    }

    private func deliverConfirmed(_ text: String, session: UUID) async {
        for _ in 0..<12 {                       // ~12s of TUI boot, then give up
            guard streams[session] != nil else { return }   // the row went away mid-wait
            let before = turnTicks[session] ?? 0
            _ = TerminalManager.shared.submit(text, to: session)
            for _ in 0..<10 {                   // ~2s for the turn to show on the event stream
                try? await Task.sleep(nanoseconds: 200_000_000)
                if (turnTicks[session] ?? 0) > before { return }
            }
        }
        Self.log.error("opencode2 never accepted the delivered prompt")
    }

    // MARK: Event stream

    /// Map one opencode2 event onto Synth's derived status facts. v2's envelope is flatter than
    /// v1's (`{id, created, type, data}`, no `properties` wrapper) and its lifecycle events are
    /// split into explicit outcomes (`session.execution.started/succeeded/failed/interrupted`)
    /// rather than v1's generic busy/idle pair — verified live against a real turn, including a
    /// genuine interrupt and a genuine permission ask.
    private func handle(_ event: [String: Any], session: UUID) {
        guard let bus, let type = event["type"] as? String else { return }
        let data = event["data"] as? [String: Any] ?? [:]

        switch type {
        case "session.created", "session.updated":
            // Confirmed live: v2's own field is `sessionID` here too (not `id` — the top-level
            // `POST /api/session` response body uses `id`, but the *event* envelope keys every
            // session-scoped event by `sessionID`, `session.created` included).
            guard let ocID = data["sessionID"] as? String else { return }
            if data["parentID"] is String {
                childSessionIDs[session, default: []].insert(ocID)
                return
            }
            if agentSessionIDs[session] == nil {
                agentSessionIDs[session] = ocID
                turnTicks[session, default: 0] += 1   // a first prompt created the conversation
                bus.post(.agentSessionCaptured(session, ocID))
            }

        // A dedicated rename event, fired once the title agent (or the user) actually names the
        // conversation — unlike v1, there is no placeholder title to filter out here.
        case "session.renamed":
            guard isRowSession(data, session), let title = data["title"] as? String else { return }
            bus.post(.titleChanged(session, title))

        case "session.execution.started":
            guard isRowSession(data, session) else { return }
            turnTicks[session, default: 0] += 1
            bus.post(.statusChanged(session, .working))

        case "session.execution.succeeded":
            guard isRowSession(data, session) else { return }
            bus.post(.statusChanged(session, .idle))
            bus.post(.markUnread(session))

        // A dedicated terminal event for "the user hit escape mid-turn" — v2's cleaner answer to
        // v1's `MessageAbortedError` string-matched out of a generic error event. A user interrupt
        // is a clean stop, never a red row.
        case "session.execution.interrupted":
            guard isRowSession(data, session) else { return }
            bus.post(.statusChanged(session, .idle))

        case "session.execution.failed":
            guard isRowSession(data, session) else { return }
            bus.post(.statusChanged(session, .error))
            bus.post(.markUnread(session))

        case "permission.asked":
            guard isRowSession(data, session) else { return }
            bus.post(.statusChanged(session, .needsInput))

        // `question.*` has no successor by that name in v2 (`OPENCODE_ENABLE_QUESTION_TOOL` is
        // gone from the binary); the Form system generalises it, and opencode2's own UI classifies
        // `form.created`/`form.replied`/`form.cancelled` as the same "question" surface permission
        // events are.
        //
        // `form.created` is the one event in v2 that wraps its payload — `{form: {sessionID, …}}`
        // where every other session-scoped event puts `sessionID` at the top of `data`. Matched on
        // the flat shape it finds no id at all, so `isRowSession` rejects it and every question
        // opencode2 asks goes unreported. Its own reply/cancel events are flat, which is what made
        // the difference invisible to read: only the ask is nested.
        case "form.created":
            guard let form = data["form"] as? [String: Any], isRowSession(form, session)
            else { return }
            bus.post(.statusChanged(session, .needsInput))

        case "permission.replied", "form.replied", "form.cancelled":
            guard isRowSession(data, session) else { return }
            bus.post(.statusChanged(session, .working))

        default:
            break
        }
    }

    private func isRowSession(_ data: [String: Any], _ session: UUID) -> Bool {
        guard let ocID = data["sessionID"] as? String else { return false }
        if childSessionIDs[session]?.contains(ocID) == true { return false }
        guard let known = agentSessionIDs[session] else { return true }
        return known == ocID
    }

    // MARK: Keybinds

    /// opencode2 keeps v1's most destructive default: `app.exit` is bound to `ctrl+c` (alongside
    /// `ctrl+d` and `<leader>q`), and `session.interrupt` only to `escape`. So the one gesture
    /// every agent user reaches for mid-turn quits the agent — verified live, idle and mid-turn
    /// alike, exiting 0 in under a second with no confirmation, which reads to Synth as a clean
    /// quit and parks the row on a Reopen card. Claude Code interrupts on that key, and two
    /// agents in one app must not disagree about a stop gesture.
    ///
    /// v1's supervisor fixes this without touching the user's own file, via `OPENCODE_TUI_CONFIG`
    /// — an overlay merged after their config. v2 removed that variable and shipped no
    /// replacement: `OPENCODE_CONFIG_DIR` moves the whole directory, and a shadowed copy of it
    /// would swallow the TUI's own writes to this very file, which opencode2 rewrites on every
    /// preference toggle. So the binding is claimed in `cli.json` itself, the way `OpencodeTheme`
    /// already claims `theme` in it: only where the binding is still opencode2's own default (or
    /// already ours), preserving every other key, and refusing outright on a file — or a
    /// `keybinds` block — it cannot parse. A binding the user chose is one they meant.
    private static func adoptKeybinds(home: URL = AgentTheme.defaultHome()) {
        // key: what Synth wants it to be, what opencode2 ships it as.
        let claims = [("app.exit", "ctrl+d,<leader>q", "ctrl+c,ctrl+d,<leader>q"),
                      ("session.interrupt", "escape,ctrl+c", "escape")]
        let url = OpencodeTheme.configDir(home: home).appendingPathComponent("cli.json")
        var config: [String: Any] = ["$schema": "https://opencode.ai/v2/cli.json"]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            config = parsed
        } else if !OpencodeTheme.mayCreateCLIConfig(dir: url.deletingLastPathComponent(),
                                                    home: home) {
            return
        }
        var keybinds: [String: Any] = [:]
        if let existing = config["keybinds"] {
            guard let block = existing as? [String: Any] else { return }
            keybinds = block
        }
        for (key, ours, theirs) in claims {
            guard let current = keybinds[key] else { continue }
            guard let bound = current as? String, bound == ours || bound == theirs else { return }
        }
        guard claims.contains(where: { keybinds[$0.0] as? String != $0.1 }) else { return }
        for (key, ours, _) in claims { keybinds[key] = ours }
        config["keybinds"] = keybinds
        // `withoutEscapingSlashes` because this file is the user's to read: the `$schema` URL comes
        // back out as `https:\/\/opencode.ai/...` without it, which is valid JSON and looks broken.
        guard let out = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? out.write(to: url, options: .atomic)) != nil else { return }
        // opencode2 writes this file 0600; an atomic replace would otherwise widen it to 0644.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }


    // MARK: Paths

    /// Where the shim points `serve`'s stdout and stderr. One dir per Synth process (reaped by
    /// `HookEnvironment` once the pid is gone), one file per row.
    ///
    /// The row's PTY is the one place this must never go — that was 0.41.1's bug, and /dev/null
    /// was its fix. But /dev/null also means a server that dies takes the reason with it, and the
    /// TUI dies moments later with nothing to say beyond "could not reach server". A file keeps
    /// the terminal clean and the crash readable.
    static let root = "/tmp/synth-oc2-\(getpid())"

    static func logPath(_ session: UUID) -> String { root + "/" + session.uuidString + ".log" }

    /// Ask the kernel for a free loopback port, exactly as `OpencodeSupervisor` does — the shim
    /// binds it a moment later, and a collision just retries.
    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { return 0 }
        var out = sockaddr_in()
        let got = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return 0 }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    /// A password only Synth and the two processes it starts ever see — pinned via
    /// `OPENCODE_PASSWORD` rather than left to the server to mint and print, so the shim never
    /// races reading it back off stdout (confirmed: pinning it suppresses the "server password"
    /// line entirely, and the server accepts it immediately).
    private static func generatePassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "A")
            .replacingOccurrences(of: "/", with: "B")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A Server-Sent-Events subscription to one opencode2 server, reconnecting until stopped —
/// structurally identical to `OpencodeEventStream`, differing only in the path prefix and the
/// Basic-auth header every v2 route requires.
final class Opencode2EventStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let port: Int
    private let authHeader: String
    private let onOpen: @Sendable () -> Void
    private let onEvent: @Sendable ([String: Any]) -> Void

    private var urlSession: URLSession!
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private let lock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stopped }
        set { lock.lock(); _stopped = newValue; lock.unlock() }
    }

    init(port: Int, password: String,
         onOpen: @escaping @Sendable () -> Void,
         onEvent: @escaping @Sendable ([String: Any]) -> Void) {
        self.port = port
        let credentials = Data("opencode:\(password)".utf8).base64EncodedString()
        self.authHeader = "Basic \(credentials)"
        self.onOpen = onOpen
        self.onEvent = onEvent
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeInterval(INT_MAX)
        config.timeoutIntervalForResource = TimeInterval(INT_MAX)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func start() { connectWhenServing(after: 0) }

    func stop() {
        stopped = true
        task?.cancel()
        urlSession.invalidateAndCancel()
    }

    /// `serve` takes a beat to bind after the shim spawns it and the shim already waits for that
    /// before starting the visible TUI — but the Swift side has no ordering guarantee against that
    /// external process, so it probes the same way `OpencodeEventStream` does.
    private func connectWhenServing(after delay: TimeInterval) {
        guard !stopped else { return }
        Task.detached { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self else { return }
            while !self.stopped {
                if await self.isServing() { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !self.stopped else { return }
            self.connect()
        }
    }

    private func isServing() async -> Bool {
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/health")!)
        probe.timeoutInterval = 1
        probe.setValue(authHeader, forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: probe) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func connect() {
        guard !stopped else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/event")!)
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        task = urlSession.dataTask(with: req)
        task?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
        onOpen()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        let separator = Data("\n\n".utf8)
        while let frame = buffer.firstRange(of: separator) {
            let chunk = buffer[buffer.startIndex..<frame.lowerBound]
            buffer.removeSubrange(buffer.startIndex..<frame.upperBound)
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("data:") {
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                guard let json = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
                else { continue }
                onEvent(event)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        buffer.removeAll(keepingCapacity: false)
        connectWhenServing(after: 0.25)
    }
}
