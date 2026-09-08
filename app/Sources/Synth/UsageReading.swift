import Foundation

/// Run one short-lived program and hand back its stdout, giving up after `timeout`.
///
/// Every usage reader that isn't an HTTP call reaches its agent through a subprocess, and each of
/// those can stall on something outside Synth: a keychain deciding to ask, an agent's CLI waiting
/// on a server that never answers. The board reads on a timer, so a reader with no deadline would
/// leave its band saying "loading" for the rest of the session — the deadline is what turns that
/// into an honest "unavailable".
enum UsageCommand {
    /// Why a reader got nothing. These five outcomes used to collapse into one `nil`, so a band
    /// showed whatever reason its caller assumed rather than what happened — a user who *is*
    /// signed in was told they are not, and a wedged CLI left no trace anywhere.
    enum Failure: Error, LocalizedError {
        case notExecutable
        case timedOut(TimeInterval)
        case exited(Int32)
        case outputNotUTF8

        var errorDescription: String? {
            switch self {
            case .notExecutable:    return "not an executable file"
            case .timedOut(let t):  return "no answer within \(Int(t))s"
            case .exited(let code): return "exited \(code)"
            case .outputNotUTF8:    return "output was not UTF-8"
            }
        }
    }

    static func output(_ path: String, _ args: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try run(path, args, timeout: timeout) })
            }
        }
    }

    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure.notExecutable }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        try proc.run()

        // Drain on another queue: a program that outruns the pipe buffer blocks forever against a
        // parent that only starts reading once the child has exited.
        let box = OutputBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            throw Failure.timedOut(timeout)
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw Failure.exited(proc.terminationStatus) }
        guard let text = String(data: box.data, encoding: .utf8) else { throw Failure.outputNotUTF8 }
        return text
    }

    /// Ferries the drained output across the semaphore's happens-before edge.
    private final class OutputBox: @unchecked Sendable { var data = Data() }
}

/// How a usage number reaches the tile. The view renders `value` as written, so units, currency
/// and scale are settled here rather than in four sources that would each pick their own.
enum UsageFormat {
    /// Token counts run to hundreds of millions and the tile is one line, so the headline is
    /// scaled rather than grouped. A decimal only below 100 in the scaled unit, which keeps every
    /// value to three or four glyphs however big the history gets.
    static func tokens(_ count: Int) -> String {
        for (scale, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where Double(count) >= scale {
            let scaled = Double(count) / scale
            return scaled >= 100 ? "\(Int(scaled.rounded()))\(suffix)"
                                 : String(format: "%.1f%@", scaled, suffix)
        }
        return "\(count)"
    }

    /// Formatted the way the account states the amount, not the way the Mac is set: an account
    /// billed in dollars says so on a machine in Britain, and the currency the agent reported is
    /// the only fact here worth preserving.
    static func money(_ amount: Double, currency: String, places: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        return formatter.string(from: NSNumber(value: amount))
            ?? String(format: "%.\(places)f %@", amount, currency)
    }

    /// A reset deadline, from either spelling of ISO-8601 the agents send: Anthropic's carries
    /// fractional seconds, Antigravity's doesn't, and a parser configured for one rejects the
    /// other outright.
    static func timestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// The detail line for a window that resets, or a blank one when the agent didn't say when.
    /// A missing deadline is not a reason to guess one — a bucket that reports no reset simply
    /// shows its percentage.
    ///
    /// A deadline that is *present* and unreadable is a different thing: the agent changed how it
    /// spells a date, and every countdown on its band has quietly become a blank line. That is
    /// counted. It does not throw — one unreadable timestamp must not cost the reader the
    /// percentage beside it, which is the number they came for.
    static func resetDetail(_ raw: String?) -> UsageDetail {
        guard let raw else { return .text("") }
        guard let date = timestamp(raw) else {
            Fault.report(.app, .uncaught, severity: .degraded,
                         evidence: "usage reset time is neither ISO-8601 spelling: \(raw)")
            return .text("")
        }
        return .resets(at: date)
    }
}

/// A reader reached its agent, got an answer, and could not make sense of it.
///
/// This is the failure the board most needed a name for. Every source parses something whose shape
/// is decided elsewhere — a JSON body, a tab-separated table, another product's database schema —
/// and each parse was written to yield nothing rather than to fail. Nothing then reads on the board
/// exactly like "you have used none of it", which is the one thing it must never say when it
/// doesn't know.
enum UsageUnreadable: Error, LocalizedError {
    /// The transport worked; what came back was not a shape this build can read.
    case shape(StaticString)
    /// A status the caller has no answer for. The number is the whole diagnosis.
    case http(Int)
    /// SQLite's own message — local-only, and the only thing that says which of open, prepare and
    /// step gave up.
    case database(String)

    var errorDescription: String? {
        switch self {
        case .shape(let what):  return "unrecognised \(what)"
        case .http(let status): return "HTTP \(status)"
        case .database(let m):  return "sqlite: \(m)"
        }
    }
}
