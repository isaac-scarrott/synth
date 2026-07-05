import Foundation

/// Minimal Chrome DevTools Protocol client over URLSessionWebSocketTask (ADR-0011
/// stage three). One client per page target — CEF serves a per-target socket at
/// `webSocketDebuggerUrl`, so there is no Target.attachToTarget multiplexing here.
/// All mutable state is confined to `queue`; the public API is callable from any
/// task. Events (Runtime.bindingCalled etc.) arrive on `events`.
final class CDPClient: NSObject, @unchecked Sendable {
    struct Event {
        let method: String
        let params: [String: Any]
    }

    struct CDPError: Error, CustomStringConvertible {
        let description: String
    }

    /// Every protocol event received on this socket, in arrival order. Finished on close.
    let events: AsyncStream<Event>

    private let task: URLSessionWebSocketTask
    private let queue = DispatchQueue(label: "synth.cdp.client")
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var closed = false

    init(url: URL) {
        let session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024   // full-viewport screenshots are large
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self)
        super.init()
        task.resume()
        receiveLoop()
    }

    /// Send a command and await its response. Times out (default 15s) rather than
    /// hanging forever on a wedged target.
    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:],
              timeout: TimeInterval = 15) async throws -> [String: Any] {
        let id: Int = queue.sync { let i = nextID; nextID += 1; return i }
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CDPError(description: "unencodable CDP payload for \(method)")
        }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.pending[id] = { cont.resume(with: $0) }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if let cb = self.pending.removeValue(forKey: id) {
                        cb(.failure(CDPError(description: "timeout waiting for \(method)")))
                    }
                }
            }
            task.send(.string(text)) { [weak self] err in
                guard let err, let self else { return }
                self.queue.async {
                    if let cb = self.pending.removeValue(forKey: id) { cb(.failure(err)) }
                }
            }
        }
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.task.cancel(with: .normalClosure, reason: nil)
            for (_, cb) in self.pending {
                cb(.failure(CDPError(description: "connection closed")))
            }
            self.pending.removeAll()
            self.eventContinuation.finish()
        }
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.close()
            case .success(let msg):
                var text: String?
                if case .string(let s) = msg { text = s }
                if case .data(let d) = msg { text = String(data: d, encoding: .utf8) }
                if let text, let data = text.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    self.queue.async { self.dispatch(obj) }
                }
                self.receiveLoop()
            }
        }
    }

    /// Runs on `queue`.
    private func dispatch(_ obj: [String: Any]) {
        if let id = obj["id"] as? Int {
            guard let cb = pending.removeValue(forKey: id) else { return }
            if let error = obj["error"] as? [String: Any] {
                cb(.failure(CDPError(description: "\(error["message"] ?? error)")))
            } else {
                cb(.success(obj["result"] as? [String: Any] ?? [:]))
            }
        } else if let method = obj["method"] as? String {
            eventContinuation.yield(Event(method: method,
                                          params: obj["params"] as? [String: Any] ?? [:]))
        }
    }
}

// MARK: - Target discovery

extension CDPClient {
    struct PageTarget: Decodable {
        let type: String
        let url: String
        let webSocketDebuggerUrl: String?
    }

    /// The instance endpoint's page targets (`GET /json/list`) — one per browser session.
    static func listPages(port: UInt16) async throws -> [PageTarget] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else {
            throw CDPError(description: "bad CDP port \(port)")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([PageTarget].self, from: data)
            .filter { $0.type == "page" && !$0.url.hasPrefix("devtools://") }
    }

    /// Connect to the page target belonging to a Synth browser session. The CDP port is
    /// per app instance (one endpoint, one target per session), so each candidate is
    /// identified by the `window.__synthSessionId` the engine stamps on every document
    /// (CEFShim sessionTag). `urlHint` orders candidates so the common case needs one probe.
    static func attach(port: UInt16, synthSessionID: UUID,
                       urlHint: URL? = nil) async throws -> CDPClient {
        var candidates = try await listPages(port: port)
        if let hint = urlHint?.absoluteString {
            candidates.sort { ($0.url == hint ? 0 : 1) < ($1.url == hint ? 0 : 1) }
        }
        let want = synthSessionID.uuidString
        for target in candidates {
            guard let ws = target.webSocketDebuggerUrl, let wsURL = URL(string: ws) else { continue }
            let client = CDPClient(url: wsURL)
            let reply = try? await client.send(
                "Runtime.evaluate",
                ["expression": "window.__synthSessionId || null", "returnByValue": true],
                timeout: 5)
            if let result = reply?["result"] as? [String: Any],
               result["value"] as? String == want {
                return client
            }
            client.close()
        }
        throw CDPError(description: "no CDP page target for session \(want) on port \(port)")
    }
}
