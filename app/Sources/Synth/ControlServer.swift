import Foundation

/// The request/response twin of HookServer (ADR-0008 socket infra, ADR-0011 stage two).
/// The hook socket is strictly one-way — fire a signal, close — so control verbs get
/// their own tiny socket (/tmp/synth-ctl-<pid>.sock, advertised in the instance file)
/// rather than distorting that protocol. Wire format: one JSON-line request per
/// connection, one JSON-line response back.
///
/// Verbs (the MCP server's session tools; everything page-level goes over CDP):
///   {"verb":"browser.list","worktreePath":"…"}
///     → {"ok":true,"sessions":[{"sessionId","title","url","branch"}]}
///   {"verb":"browser.create","worktreePath":"…","url":"…"?}
///     → {"ok":true,"sessionId":"…"}   (created exactly like ⌘K New browser:
///        in the matching branch, pre-navigated if url given, selected)
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
                ["sessionId": s.id.uuidString,
                 "title": s.title,
                 "url": s.browserURL?.absoluteString ?? "",
                 "branch": branch.name]
            }
            return ["ok": true, "sessions": sessions]

        case "browser.create":
            let url = (request["url"] as? String).flatMap(URL.fromBrowserInput)
            guard let session = store.newBrowser(in: branch, at: url) else {
                return ["ok": false, "error": "session creation failed"]
            }
            // The engine mounts when the selected pane renders (the next runloop
            // turn) — the stage-one path. Creating it here instead would nest a
            // SwiftUI render pass inside the engine's creation pump and duplicate
            // the engine; callers poll CDP for the target, so the beat is invisible.
            return ["ok": true, "sessionId": session.id.uuidString]

        default:
            return ["ok": false, "error": "unknown verb \(verb)"]
        }
    }
}
