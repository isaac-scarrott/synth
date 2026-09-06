import Foundation
import SQLite3

/// OpenCode's token and cost history, read from the local database it already keeps.
///
/// One reader serves both generations because they differ in where the history lives, not in what
/// it says — v2 is a preview of the same product, and a board that showed them in two different
/// shapes would be reporting on Synth's plumbing rather than on the user's spending.
///
/// Neither generation has a rate limit to report: opencode talks to whichever provider the user
/// signed in, and the ceiling — if there is one at all — belongs to that account, not to opencode.
/// So every metric here is a running total with no meter behind it.
struct OpencodeUsageSource: UsageSource {
    enum Generation: Sendable { case v1, v2 }

    let descriptor: AgentDescriptor
    let generation: Generation
    var agent: AgentID { descriptor.id }

    /// How long the aggregate may run before it is abandoned. Comfortably above what the scan
    /// measures today on a multi-gigabyte history, and well inside the poll that started it.
    private static let scanBudget: TimeInterval = 20

    /// Both generations share this one file — v2 kept the name and added tables beside v1's.
    /// (`opencode-local.db` next to it is a dead stub and is deliberately not read.)
    private static var databasePath: String {
        NSHomeDirectory() + "/.local/share/opencode/opencode.db"
    }

    func load() async -> UsageSection {
        guard let totals = await Self.totals(generation), totals.messages > 0 else {
            return UsageSection(id: agent, title: descriptor.displayName,
                                status: .unavailable("no local history"))
        }
        let metrics = [
            UsageMetric(id: agent.rawValue + ".tokens", label: "Tokens",
                        value: UsageFormat.tokens(totals.tokens), percent: nil,
                        detail: .text("all time")),
            // A subscription or OAuth provider — Copilot, a Claude or ChatGPT plan — prices
            // nothing per call, so $0.00 beside millions of tokens is the true answer rather than
            // a missing one. Imputing list prices would invent exactly the number this board
            // exists not to invent.
            UsageMetric(id: agent.rawValue + ".cost", label: "Est. cost",
                        value: UsageFormat.money(totals.cost, currency: "USD"), percent: nil,
                        detail: .text("all time")),
        ]
        return UsageSection(id: agent, title: descriptor.displayName, metrics: metrics)
    }

    // MARK: History

    /// v1's own era. Its `session` rollup columns look like the cheap answer and are not one —
    /// recent rows carry zeros — so the totals are aggregated from the messages themselves.
    private static let v1Query = """
        SELECT sum(coalesce(json_extract(data, '$.tokens.input'), 0)
                 + coalesce(json_extract(data, '$.tokens.output'), 0)),
               sum(coalesce(json_extract(data, '$.cost'), 0)),
               count(*)
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant'
        """

    /// v2's own era, and only that. Installing opencode2 imported every v1 session into v2's
    /// tables keeping the original row ids, so `session_message` holds both histories — counting
    /// it whole would report v1's spending twice, once under each agent's band. A genuinely-v2
    /// session is the one stamped with a v2 build (`0.0.0-beta-…`, the preview's own versioning).
    private static let v2Query = """
        SELECT sum(coalesce(json_extract(m.data, '$.tokens.input'), 0)
                 + coalesce(json_extract(m.data, '$.tokens.output'), 0)),
               sum(coalesce(json_extract(m.data, '$.cost'), 0)),
               count(*)
        FROM session_message m
        JOIN session_v2 s ON s.id = m.session_id
        WHERE m.type = 'assistant' AND s.version LIKE '0.0.0%'
        """

    private static func totals(_ generation: Generation) async -> (tokens: Int, cost: Double, messages: Int)? {
        let sql = generation == .v1 ? v1Query : v2Query
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: aggregate(sql))
            }
        }
    }

    /// Sum in SQL, never in Swift. The shared database runs to gigabytes of message JSON, and
    /// stepping those rows across into Swift to add them up turns a read the board can wait on
    /// into a scan it can't.
    private static func aggregate(_ sql: String) -> (tokens: Int, cost: Double, messages: Int)? {
        var db: OpaquePointer?
        // Read-only, so a live opencode writing into the same WAL is never blocked by the board —
        // and so a bug here can never damage the user's history.
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        // Bounds waiting for a lock. It does nothing about how long the scan itself runs, which is
        // the risk here: this is a full `json_extract` pass over gigabytes of message JSON.
        sqlite3_busy_timeout(db, 5000)

        // So the scan carries its own deadline. Without one a database that has grown past what
        // this query can walk in reasonable time would leave the band on "checking…" and, because
        // a refresh only starts once the last has finished, keep every other agent's number stale
        // behind it.
        let deadline = Date().addingTimeInterval(scanBudget)
        let expiry = UnsafeMutablePointer<Date>.allocate(capacity: 1)
        expiry.initialize(to: deadline)
        defer { expiry.deinitialize(count: 1); expiry.deallocate() }
        sqlite3_progress_handler(db, 20_000, { context in
            guard let context else { return 0 }
            return Date() >= context.assumingMemoryBound(to: Date.self).pointee ? 1 : 0
        }, UnsafeMutableRawPointer(expiry))

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        return (tokens: Int(sqlite3_column_int64(statement, 0)),
                cost: sqlite3_column_double(statement, 1),
                messages: Int(sqlite3_column_int64(statement, 2)))
    }
}
