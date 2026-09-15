import Foundation

/// A usage window crossing a line worth a word, said once, for any agent whose reader reports a
/// ceiling.
///
/// The board answers "how close am I to a limit" when you go and look; this answers it when you
/// don't. It reads the same `UsageSection`s the board draws, so an agent is covered the moment its
/// reader reports a `percent` — nothing here knows which agent, plan or window it is looking at.
struct UsageAlerts {
    static let thresholds: [Double] = [80, 95]
    /// The last line is one bad hour from the agent refusing, so its card stays until dismissed.
    static var urgent: Double { thresholds.last! }

    /// One window newly past a line in this reading.
    struct Crossing: Equatable {
        let metric: UsageMetric
        let percent: Double
        let threshold: Double
    }

    /// What has already been said about one window: the highest line it crossed, and when that
    /// window ends. The deadline is what lets a new window speak again without the old one having
    /// been seen to drop — a reset that happens while Synth is quit is never observed as a fall.
    struct Said: Codable, Equatable {
        var threshold: Double
        var resetsAt: Date?
    }

    /// On disk beside the tree's own snapshot, so a relaunch — an update, a crash — doesn't repeat
    /// every alert still standing, and a harness's `SYNTH_STATE_DIR` keeps its memory out of the
    /// user's. Read fresh on every reading: two instances of the same channel share it, and
    /// whichever sees the crossing first is the one that says it.
    static var fileURL: URL {
        PersistenceStore.fileURL.deletingLastPathComponent().appendingPathComponent("usage-alerts.json")
    }

    /// The crossings in `section`, with memory brought up to date on disk.
    static func note(_ section: UsageSection, now: Date = Date()) throws -> [Crossing] {
        var said = try load()
        let crossed = crossings(section, said: &said, now: now)
        try JSONEncoder().encode(said).write(to: fileURL, options: .atomic)
        return crossed
    }

    /// Keyed by agent as well as metric, because a custom agent hosted by Claude Code reads the
    /// same account through the same ids and is still a separate band.
    static func crossings(_ section: UsageSection, said: inout [String: Said], now: Date) -> [Crossing] {
        var crossed: [Crossing] = []
        for metric in section.metrics {
            guard let percent = metric.percent else { continue }
            let key = section.id.rawValue + "/" + metric.id
            let resetsAt: Date? = if case .resets(let at) = metric.detail { at } else { nil }

            // Usage only climbs inside a window, so a lower number than the line last said is the
            // window having reset under us — as is its deadline having passed.
            var prior = said[key]
            if let p = prior, percent < p.threshold || (p.resetsAt.map { $0 <= now } ?? false) {
                prior = nil
            }

            guard let level = thresholds.last(where: { percent >= $0 }) else {
                said[key] = nil
                continue
            }
            if level > prior?.threshold ?? 0 { crossed.append(Crossing(metric: metric, percent: percent, threshold: level)) }
            said[key] = Said(threshold: max(level, prior?.threshold ?? 0), resetsAt: resetsAt)
        }
        return crossed
    }

    private static func load() throws -> [String: Said] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return try JSONDecoder().decode([String: Said].self, from: Data(contentsOf: fileURL))
    }
}
