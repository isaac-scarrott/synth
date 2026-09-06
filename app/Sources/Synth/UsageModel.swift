import Foundation

/// What the Usage board can say about one agent, and the contract every source fills in.
///
/// The board's whole claim is that a number on it came from the agent's own account. So the model
/// carries no defaults and no placeholder arithmetic: a source either reports a metric or it
/// doesn't, and a section that reports nothing says why (`UsageStatus.unavailable`) rather than
/// showing a zero that would read as "you have used none of it".

/// One number on the board. `percent` is what makes a tile show a meter, so it is present only
/// where the agent genuinely reports a ceiling — a token total or a credit balance has none, and
/// its tile is the same tile with no meter in it.
struct UsageMetric: Identifiable, Hashable, Sendable {
    /// Stable across refreshes, so a changed value rolls its digits instead of the tile being
    /// replaced wholesale. Sources mint it from something durable (the API's own key for the
    /// window), never from the array index, which reorders when a server-sent list changes length.
    let id: String
    /// The eyebrow: what this measures.
    let label: String
    /// The headline. A percentage arrives already formatted ("62%") so a source that reports
    /// money or tokens can render its own units without the view knowing about currencies.
    let value: String
    /// 0–100, *used* — never remaining. Antigravity reports `remaining_fraction`, so its source
    /// inverts on the way in rather than leaving two conventions loose in the UI.
    let percent: Double?
    /// The quiet line under the meter.
    let detail: UsageDetail
}

/// A detail line is either fixed text or a deadline the board counts down to. Modelling the
/// countdown as a date rather than a pre-rendered string is what lets the tile tick without the
/// source being asked again — and what stops a reopened pane from restarting the clock.
enum UsageDetail: Hashable, Sendable {
    case text(String)
    case resets(at: Date)
}

/// Why a section has no metrics. The board never invents a number to fill the gap, so this is the
/// only other thing a band can say.
enum UsageStatus: Hashable, Sendable {
    case ready
    case loading
    /// Shown verbatim in place of tiles: "not signed in", "no usage data", a transport error.
    case unavailable(String)
}

/// One agent's band: its name, and whatever it could tell us.
struct UsageSection: Identifiable, Sendable {
    let id: AgentID
    let title: String
    let metrics: [UsageMetric]
    let status: UsageStatus

    init(id: AgentID, title: String, metrics: [UsageMetric] = [], status: UsageStatus = .ready) {
        self.id = id
        self.title = title
        self.metrics = metrics
        self.status = status
    }
}

/// Where one agent's numbers come from. Implementations live beside the supervisor they read —
/// each agent's usage arrives over a different transport, the same way its status does.
protocol UsageSource: Sendable {
    var agent: AgentID { get }
    /// Read the agent's own account/history. Returns a section whose status says what happened;
    /// throwing is reserved for programmer error, not for "the user isn't signed in".
    func load() async -> UsageSection
}

/// The board's state, refreshed on an interval while the pane is on screen.
///
/// Polling is per-agent and independent: one agent's network call failing or hanging must not
/// stop another's local read from landing, so sections are merged in as they arrive rather than
/// gathered into one all-or-nothing snapshot.
@MainActor @Observable final class UsageBoard {
    private(set) var sections: [UsageSection] = []
    private(set) var refreshing = false
    private(set) var lastRefresh: Date?

    /// A remote window doesn't move fast enough to be worth asking about more often than this, and
    /// the endpoints are rate-limited like everything else on the account.
    static let refreshInterval: TimeInterval = 60

    private var sources: [UsageSource] = []
    private var ticker: Task<Void, Never>?

    /// The agents to show, in registry order, each with whatever source can read it. An agent with
    /// no source at all still gets a band — saying "no usage data" is information, and silently
    /// dropping an installed agent would read as Synth not knowing about it.
    func configure(agents: [AgentDescriptor], sources: [UsageSource]) {
        self.sources = sources
        let known = Set(sources.map(\.agent))
        sections = agents.map { agent in
            UsageSection(id: agent.id,
                         title: agent.displayName,
                         status: known.contains(agent.id) ? .loading : .unavailable("no usage data"))
        }
    }

    /// Start polling. Safe to call again — an already-running ticker is left alone so reopening
    /// the pane doesn't stack timers or restart every countdown.
    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(UsageBoard.refreshInterval))
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        await withTaskGroup(of: UsageSection.self) { group in
            for source in sources {
                group.addTask { await source.load() }
            }
            for await section in group {
                merge(section)
            }
        }
        lastRefresh = Date()
    }

    /// Replace one band in place. Order is fixed by `configure`, so a slow source landing last
    /// never reshuffles the board under the reader.
    private func merge(_ section: UsageSection) {
        guard let i = sections.firstIndex(where: { $0.id == section.id }) else { return }
        sections[i] = section
    }
}
