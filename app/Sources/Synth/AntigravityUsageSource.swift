import Foundation

/// Antigravity's quota buckets, read by asking its own CLI.
///
/// `agy -p "/quota"` prints one tab-separated row per bucket: group, bucket, percentage, reset
/// time. Every one of those names is server-supplied — none of them appears anywhere in the
/// binary — and so is how many rows come back, so this parses whatever it is handed rather than
/// looking for the two groups of two that happen to exist today.
struct AntigravityUsageSource: UsageSource {
    let descriptor: AgentDescriptor
    var agent: AgentID { descriptor.id }

    /// `agy` reaches Antigravity's servers to answer either question, and takes seconds about it.
    /// Generous enough that a slow answer still lands within one refresh, short enough that a
    /// wedged CLI never outlives the poll that started it.
    private static let timeout: TimeInterval = 25

    func load() async -> UsageSection {
        guard let binary = descriptor.resolvedBinary else {
            return UsageSection(id: agent, title: descriptor.displayName,
                                status: .unavailable("no quota data"))
        }
        // Two round trips to the same servers; asked together so the band doesn't wait out one
        // before starting the other.
        async let quota = UsageCommand.output(binary, ["-p", "/quota"], timeout: Self.timeout)
        async let credits = UsageCommand.output(binary, ["-p", "/credits"], timeout: Self.timeout)

        let metrics = Self.buckets(await quota) + Self.credits(await credits)
        guard !metrics.isEmpty else {
            return UsageSection(id: agent, title: descriptor.displayName,
                                status: .unavailable("no quota data"))
        }
        return UsageSection(id: agent, title: descriptor.displayName, metrics: metrics)
    }

    // MARK: Parsing

    /// The percentage `agy` prints is what is LEFT — it reports headroom where the board reports
    /// spend — so it is inverted here, at the one place the two conventions meet.
    private static func buckets(_ output: String?) -> [UsageMetric] {
        rows(output).compactMap { fields in
            guard fields.count >= 4,
                  let remaining = Double(fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            else { return nil }
            let used = max(0, min(100, 100 - remaining))
            return UsageMetric(id: "antigravity.\(fields[0]).\(fields[1])",
                               label: group(fields[0]) + " · " + bucket(fields[1]),
                               value: "\(Int(used.rounded()))%",
                               percent: used,
                               detail: UsageFormat.resetDetail(fields[3]))
        }
    }

    /// `/credits` prints the same two-column table, but only some of its rows are counts — an
    /// upgrade link rides along in the same shape — so a row is shown only where the value is
    /// genuinely a number.
    private static func credits(_ output: String?) -> [UsageMetric] {
        rows(output).compactMap { fields in
            guard fields.count == 2, Double(fields[1]) != nil else { return nil }
            return UsageMetric(id: "antigravity.credits." + fields[0], label: fields[0],
                               value: fields[1], percent: nil, detail: .text(""))
        }
    }

    private static func rows(_ output: String?) -> [[String]] {
        (output ?? "").split(separator: "\n").map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    /// "Gemini Models" → "Gemini", "Claude and GPT models" → "Claude & GPT". What is dropped is
    /// what every group carries, and keeping it would push the part that actually differs off the
    /// end of a narrow tile.
    private static func group(_ raw: String) -> String {
        var words = raw.split(separator: " ").map(String.init)
        if let last = words.last?.lowercased(), last == "models" || last == "model" { words.removeLast() }
        return words.map { $0.lowercased() == "and" ? "&" : $0 }.joined(separator: " ")
    }

    /// "Five Hour Limit Remaining" → "5-hour", "Weekly Limit Remaining" → "weekly". "Remaining"
    /// has to go or the label would contradict the number under it, "Limit" is what every row is,
    /// and a spelled-out window length becomes a numeral so the tile reads at a glance.
    private static func bucket(_ raw: String) -> String {
        var words = raw.split(separator: " ").map { $0.lowercased() }
        while let last = words.last, last == "remaining" || last == "limit" { words.removeLast() }
        if let numeral = words.first.flatMap({ numerals[$0] }) { words[0] = numeral }
        return words.joined(separator: "-")
    }

    private static let numerals = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                                   "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
                                   "eleven": "11", "twelve": "12", "twenty-four": "24"]
}
