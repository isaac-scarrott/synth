import Foundation

/// Run one short-lived program and hand back its stdout, giving up after `timeout`.
///
/// Every usage reader that isn't an HTTP call reaches its agent through a subprocess, and each of
/// those can stall on something outside Synth: a keychain deciding to ask, an agent's CLI waiting
/// on a server that never answers. The board reads on a timer, so a reader with no deadline would
/// leave its band saying "loading" for the rest of the session — the deadline is what turns that
/// into an honest "unavailable".
enum UsageCommand {
    static func output(_ path: String, _ args: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(path, args, timeout: timeout))
            }
        }
    }

    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

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
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: box.data, encoding: .utf8)
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
    static func resetDetail(_ raw: String?) -> UsageDetail {
        guard let raw, let date = timestamp(raw) else { return .text("") }
        return .resets(at: date)
    }
}
