import Foundation

/// Claude Code's rate limits, read from the account that Claude Code itself is signed into.
///
/// The credential comes back through `/usr/bin/security` rather than `SecItemCopyMatching`
/// because the keychain item's ACL trusts that one tool and nothing else: read in-process, macOS
/// puts an authorisation dialog in front of it — every 60 seconds, for as long as the board is
/// open. Shelling out is how Claude Code reads its own token, and it is what keeps the poll
/// silent.
struct ClaudeUsageSource: UsageSource {
    /// Carried whole rather than as an id so a custom agent hosted by Claude Code keeps its own
    /// name and its own binary — the same descriptor its supervisor is handed.
    let descriptor: AgentDescriptor
    var agent: AgentID { descriptor.id }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func load() async -> UsageSection {
        guard let token = await Self.accessToken() else { return section(.unavailable("not signed in")) }

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        if let version = await ClaudeVersion.shared.value(of: descriptor) {
            request.setValue("claude-code/\(version)", forHTTPHeaderField: "User-Agent")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return section(.unavailable("usage unavailable")) }
        guard http.statusCode != 401 else { return section(.unavailable("sign in to Claude Code")) }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return section(.unavailable("usage unavailable")) }

        let metrics = Self.windows(json) + Self.spend(json) + Self.extraUsage(json)
        guard !metrics.isEmpty else { return section(.unavailable("no usage data")) }
        return UsageSection(id: agent, title: descriptor.displayName, metrics: metrics)
    }

    private func section(_ status: UsageStatus) -> UsageSection {
        UsageSection(id: agent, title: descriptor.displayName, status: status)
    }

    // MARK: Response

    /// `limits[]` is the server's own list of the windows this account is capped on: the session,
    /// the all-models week, and a row per model that is separately scoped. Both its length and its
    /// labels are decided server-side, so it is rendered as a list — reading `five_hour` and
    /// `seven_day` off the top level instead would freeze the board at today's set and quietly
    /// miss the next bucket Anthropic adds.
    private static func windows(_ json: [String: Any]) -> [UsageMetric] {
        (json["limits"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let kind = entry["kind"] as? String, let percent = number(entry["percent"])
            else { return nil }
            let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String

            let label: String
            switch kind {
            case "session": label = "Current session"
            case "weekly_all": label = "Current week · all models"
            case "weekly_scoped":
                // A scoped row is "the week, for this model" and nothing else. Without the name
                // there is nothing to tell the reader what it caps, so it is dropped rather than
                // shown as a second, unexplained week.
                guard let model else { return nil }
                label = "Current week · " + model
            default: label = readable(kind)
            }

            return UsageMetric(id: "claude." + kind + (model.map { "." + $0 } ?? ""),
                               label: label,
                               value: "\(Int(percent.rounded()))%",
                               percent: percent,
                               detail: UsageFormat.resetDetail(entry["resets_at"] as? String))
        }
    }

    /// Credits, but only on an account that has them switched on. `spend` is reported either way,
    /// and on an account that never enabled it the amount is a real zero against no limit — a
    /// tile there would be describing a feature the user doesn't have.
    private static func spend(_ json: [String: Any]) -> [UsageMetric] {
        guard let spend = json["spend"] as? [String: Any], spend["enabled"] as? Bool == true,
              let used = amount(spend["used"]) else { return [] }
        let limit = amount(spend["limit"])
        return [UsageMetric(id: "claude.spend", label: "Usage credits", value: used,
                            percent: number(spend["percent"]),
                            detail: .text(limit.map { "of \($0)" } ?? ""))]
    }

    /// The same rule for the separate extra-usage pool: shown only where the account reports it
    /// enabled, since every other account reports it as nulls.
    private static func extraUsage(_ json: [String: Any]) -> [UsageMetric] {
        guard let extra = json["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
              let used = number(extra["used_credits"]), let currency = extra["currency"] as? String
        else { return [] }
        let places = extra["decimal_places"] as? Int ?? 2
        let limit = number(extra["monthly_limit"]).map {
            "of \(UsageFormat.money($0, currency: currency, places: places)) this month"
        }
        return [UsageMetric(id: "claude.extra_usage", label: "Extra usage",
                            value: UsageFormat.money(used, currency: currency, places: places),
                            percent: number(extra["utilization"]),
                            detail: .text(limit ?? ""))]
    }

    /// Money arrives as minor units plus the exponent that scales them, so the currency's own
    /// number of decimal places rides along instead of being assumed to be two.
    private static func amount(_ raw: Any?) -> String? {
        guard let money = raw as? [String: Any], let minor = number(money["amount_minor"]),
              let currency = money["currency"] as? String else { return nil }
        let exponent = money["exponent"] as? Int ?? 2
        return UsageFormat.money(minor / pow(10, Double(exponent)), currency: currency, places: exponent)
    }

    private static func number(_ raw: Any?) -> Double? { (raw as? NSNumber)?.doubleValue }

    /// A `kind` this build has never seen still gets a tile: a bucket appearing on the account is
    /// exactly the thing the board should be showing, and its key is at least readable.
    private static func readable(_ kind: String) -> String {
        let words = kind.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: Credential

    /// `security` prints the whole credential blob; the bearer is lifted out of it and goes no
    /// further than the request header.
    private static func accessToken() async -> String? {
        guard let out = await UsageCommand.output(
                "/usr/bin/security",
                ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                timeout: 5),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}

/// `claude --version`, asked once per run. The endpoint is Claude Code's own, so it is asked under
/// Claude Code's user agent; the version behind that can't change while the app is running, and
/// re-spawning the CLI on every poll would cost more than the request it decorates.
private actor ClaudeVersion {
    static let shared = ClaudeVersion()

    private var asked = false
    private var version: String?

    func value(of descriptor: AgentDescriptor) async -> String? {
        guard !asked else { return version }
        asked = true
        guard let binary = descriptor.resolvedBinary,
              let out = await UsageCommand.output(binary, ["--version"], timeout: 10)
        else { return nil }
        // "2.1.263 (Claude Code)" — the version is the first field, the rest is the product name.
        version = out.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return version
    }
}
