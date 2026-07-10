import Foundation
import OSLog

/// opencode: hosted as its own TUI inside the session's PTY, supervised over the HTTP event
/// stream that same process serves. Where Claude Code has to be instrumented (a shim injecting
/// hook commands that shell back over a unix socket), opencode already publishes a typed,
/// ordered `/event` SSE bus where every event carries its `sessionID` — so the supervisor is a
/// subscriber, not a callback sink.
///
/// One server per session: the launch shim passes `--port <assigned>` (a server binds to exactly
/// one worktree, and a Synth branch *is* one worktree), and the app subscribes to that port.
///
/// The server is loopback-only and unauthenticated. `OPENCODE_SERVER_PASSWORD` would secure it,
/// but opencode's own TUI races its credentials: it can issue a request before auth is applied
/// and dies on the resulting 401, taking the session with it. Since a bare `opencode` in any
/// terminal already serves an unauthenticated loopback port (on a random rather than an assigned
/// one — equally enumerable), Synth doesn't widen the exposure by leaving it off.
@MainActor final class OpencodeSupervisor: AgentSupervisor {
    let id = AgentID.opencode

    private weak var bus: EventBus?
    private static let log = Logger(subsystem: bundleIdentifier, category: "opencode")

    /// The HTTP port assigned to each session's opencode server, handed to the shim as
    /// `SYNTH_OPENCODE_PORT` so the TUI serves there and we know where to subscribe.
    private var ports: [UUID: Int] = [:]
    /// The live SSE subscription per session, cancelled on detach.
    private var streams: [UUID: OpencodeEventStream] = [:]
    /// opencode's own top-level session id for each row — the delivery target. Child (subagent)
    /// sessions carry a `parentID` and never become the row's identity.
    private var agentSessionIDs: [UUID: String] = [:]
    /// opencode session ids known to be subagents, so their status/idle never drives the row.
    private var childSessionIDs: [UUID: Set<String>] = [:]
    /// Bumped every time a row visibly starts work. `deliverConfirmed` watches it to tell a
    /// prompt the TUI accepted from one it dropped while still booting.
    private var turnTicks: [UUID: Int] = [:]

    init(bus: EventBus) { self.bus = bus }

    // MARK: Launch

    func decorate(_ env: inout [String: String], sessionID: UUID) {
        guard let real = AgentRegistry.opencode.resolvedBinary else { return }
        let port = ports[sessionID] ?? Self.freePort()
        ports[sessionID] = port

        env[AgentRegistry.opencode.realBinaryEnvKey] = real
        env["SYNTH_OPENCODE_PORT"] = String(port)
        // The `question` tool is what lets an agent stop and ask the user — the needs-input
        // signal Synth's unattended-agent notifications depend on. It is env-gated, and unlike
        // a tool permission it still fires when everything else is auto-approved.
        env["OPENCODE_ENABLE_QUESTION_TOOL"] = "1"
        // An embedded agent must not self-update mid-session or rewrite the terminal title
        // Synth derives the row name from.
        env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        env["OPENCODE_DISABLE_TERMINAL_TITLE"] = "1"
    }

    func launchCommand(resume: String?, flags: String) -> String {
        let extra = flags.isEmpty ? "" : " " + flags
        if let resume { return "exec opencode --session \(shellQuoteAgentArg(resume))\(extra)\n" }
        return "exec opencode\(extra)\n"
    }

    // MARK: Supervision

    /// The stream's callbacks arrive on URLSession's delegate queue; every fact they carry lands
    /// on the store, so they hop to the main actor before touching anything.
    func attach(session: UUID) {
        guard streams[session] == nil, let port = ports[session] else { return }
        let stream = OpencodeEventStream(
            port: port,
            onOpen: {
                Task { @MainActor [weak self] in
                    // The stream is open, so the server is listening: the row can now be handed
                    // text. The shim announced the launch a beat earlier — announcing readiness
                    // then would have delivered comments into a port nothing was bound to yet.
                    self?.bus?.post(.agentReady(session))
                }
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
    }

    // MARK: Delivery

    /// Deliver text through opencode's own API rather than by typing at the terminal: fill the
    /// TUI's prompt and submit it. No bracketed paste, no timed Enter, and nothing to mis-deliver
    /// into a shell if the agent isn't running (the port simply has no server).
    ///
    /// The TUI endpoints — not `session.prompt` — because the TUI *is* the surface the user is
    /// looking at, and it has no session at all until its first prompt (opencode creates the
    /// conversation lazily). Posting to a session id would either fail on a fresh row or start a
    /// conversation the visible TUI never shows.
    func deliver(_ text: String, to session: UUID) -> Bool {
        guard let port = ports[session] else { return false }
        Task { await self.deliverConfirmed(text, session: session, port: port) }
        return true
    }

    /// The server starts listening before the TUI subscribes to it, and `tui/append-prompt` is
    /// *published as an event* — a 200 only means the server accepted it, not that a TUI was
    /// there to receive it. Text handed over in that window is silently dropped. So post, watch
    /// for the row to actually start a turn, and re-post until it does. `clear-prompt` first, so
    /// a retry after a landed append can't submit the message twice over.
    private func deliverConfirmed(_ text: String, session: UUID, port: Int) async {
        for _ in 0..<12 {                       // ~12s of TUI boot, then give up
            let before = turnTicks[session] ?? 0
            do {
                try await Self.post(port: port, path: "/tui/clear-prompt", body: [:])
                try await Self.post(port: port, path: "/tui/append-prompt", body: ["text": text])
                try await Self.post(port: port, path: "/tui/submit-prompt", body: [:])
            } catch {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            for _ in 0..<5 {                    // 1s for the turn to show on the event stream
                try? await Task.sleep(nanoseconds: 200_000_000)
                if (turnTicks[session] ?? 0) > before { return }
            }
        }
        Self.log.error("OpenCode never accepted the delivered prompt")
    }

    private static func post(port: Int, path: String, body: [String: Any]) async throws {
        var req = request(port: port, path: path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: Event stream

    private static func request(port: Int, path: String) -> URLRequest {
        URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    }

    /// Map one opencode event onto Synth's derived status facts. Everything else — token
    /// deltas, tool progress, file watches — stays in the local firehose (docs/adr/0001).
    private func handle(_ event: [String: Any], session: UUID) {
        guard let bus, let type = event["type"] as? String else { return }
        let props = event["properties"] as? [String: Any] ?? [:]

        switch type {
        case "session.created", "session.updated", "session.deleted":
            guard let info = props["info"] as? [String: Any], let ocID = info["id"] as? String else { return }
            // A subagent (the `task` tool) gets its own session under a parent. Its lifecycle
            // must never drive the row — the parent is still working while it runs.
            if info["parentID"] is String {
                childSessionIDs[session, default: []].insert(ocID)
                return
            }
            if type == "session.deleted" { return }
            if agentSessionIDs[session] == nil {
                agentSessionIDs[session] = ocID
                turnTicks[session, default: 0] += 1   // a first prompt created the conversation
                bus.post(.agentSessionCaptured(session, ocID))
            }
            // opencode names a session from its first user message; until then the title is a
            // placeholder ("New session - <ISO>") that must not become the row's name.
            if let title = info["title"] as? String, !Self.isDefaultTitle(title) {
                bus.post(.titleChanged(session, title))
            }

        case "session.status":
            guard isRowSession(props, session) else { return }
            let status = (props["status"] as? [String: Any])?["type"] as? String
            if status == "busy" {
                turnTicks[session, default: 0] += 1
                bus.post(.statusChanged(session, .working))
            }

        case "session.idle":
            guard isRowSession(props, session) else { return }
            bus.post(.statusChanged(session, .idle))
            bus.post(.markUnread(session))

        case "session.error":
            guard isRowSession(props, session) else { return }
            // A user interrupt reports as an error *and* settles the session to idle. It is the
            // opencode spelling of Claude's 130/143: a clean stop, never a red row.
            let name = (props["error"] as? [String: Any])?["name"] as? String
            if name == "MessageAbortedError" {
                bus.post(.statusChanged(session, .idle))
            } else {
                bus.post(.statusChanged(session, .error))
                bus.post(.markUnread(session))
            }

        // Both channels mean "the agent stopped and is waiting on a human". `permission.asked`
        // is suppressed when a tool is auto-approved; `question.asked` fires regardless, which
        // is why an unattended agent still surfaces.
        case "permission.asked", "question.asked":
            guard isRowSession(props, session) else { return }
            bus.post(.statusChanged(session, .needsInput))

        case "permission.replied", "question.replied", "question.rejected":
            guard isRowSession(props, session) else { return }
            bus.post(.statusChanged(session, .working))

        case "session.compacted":
            // `/clear`'s analog: the conversation restarts, so a stale generated name must go.
            guard isRowSession(props, session) else { return }
            bus.post(.titleReset(session))

        default:
            break
        }
    }

    /// True when an event belongs to the row's own top-level opencode session rather than one
    /// of its subagents. Events keyed only by `sessionID` (status/idle/error/permission) carry
    /// no `parentID`, so parentage is resolved from the map built off `session.created`.
    private func isRowSession(_ props: [String: Any], _ session: UUID) -> Bool {
        guard let ocID = props["sessionID"] as? String else { return false }
        if childSessionIDs[session]?.contains(ocID) == true { return false }
        guard let known = agentSessionIDs[session] else { return true }
        return known == ocID
    }

    /// opencode's placeholder name before its title agent runs ("New session - 2026-07-08T…").
    private static func isDefaultTitle(_ title: String) -> Bool {
        title.hasPrefix("New session - ")
    }

    /// Ask the kernel for a free loopback port, then hand it to the shim. A bind-probe races in
    /// principle; in practice the shim claims it milliseconds later and a collision just retries.
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
}

/// A Server-Sent-Events subscription to one opencode server, reconnecting until stopped.
///
/// Built on `URLSessionDataDelegate` rather than `URLSession.bytes(for:)`: the async-bytes API
/// buffers, and intermittently never returns the response headers for a never-ending stream —
/// the socket connects and the app then waits forever for status it will never see. The delegate
/// hands over each chunk as it lands, which is what an event stream needs.
final class OpencodeEventStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let port: Int
    private let onOpen: @Sendable () -> Void
    private let onEvent: @Sendable ([String: Any]) -> Void

    private var urlSession: URLSession!
    private var task: URLSessionDataTask?
    /// SSE frames are `data: {...}\n\n`; a chunk can split one, so bytes accumulate here.
    private var buffer = Data()
    private let lock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stopped }
        set { lock.lock(); _stopped = newValue; lock.unlock() }
    }

    init(port: Int,
         onOpen: @escaping @Sendable () -> Void,
         onEvent: @escaping @Sendable ([String: Any]) -> Void) {
        self.port = port
        self.onOpen = onOpen
        self.onEvent = onEvent
        super.init()
        let config = URLSessionConfiguration.ephemeral
        // The stream is idle between events; the default 60s request timeout would kill it.
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

    /// Wait until the server answers HTTP, then open the stream.
    ///
    /// The shim announces the launch before opencode binds, so a naive retry loop fires a dozen
    /// failed data tasks in the ~3s the port is dead. URLSession pools those attempts, and the
    /// one that finally connects can end up on a socket whose response is never delivered — the
    /// stream sits ESTABLISHED and silent forever. Probing with an ordinary request first means
    /// exactly one SSE task is ever created, once there is something to serve it.
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
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/global/health")!)
        probe.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: probe) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func connect() {
        guard !stopped else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Without this URLSession offers gzip and holds the response until enough bytes
        // accumulate to decode — fatal for a stream whose whole point is immediacy.
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

    /// The stream dropped (the agent quit, or the server restarted) — wait for it to serve again.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        buffer.removeAll(keepingCapacity: false)
        connectWhenServing(after: 0.25)
    }
}
