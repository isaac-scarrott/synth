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

/// Why a section has no metrics. The board never invents a number to fill the gap, so these are the
/// only other things a band can say.
enum UsageStatus: Hashable, Sendable {
    case ready
    case loading
    /// The answer, and it is nothing: "not signed in", "no local history". The reader reached the
    /// agent and the agent has no numbers to give.
    case unavailable(String)
    /// We could not find out. Held apart from `unavailable` because on a board whose whole claim is
    /// that a number came from the agent's own account, "you have used none of it" and "we couldn't
    /// read it" are opposite statements, and the board used to make the first one for both.
    case failed(String)
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
    /// The band's heading, held here as well as in the section so the board can still name an agent
    /// whose read threw before it had a section to put a name on.
    var title: String { get }
    /// Read the agent's own account/history. A status is the answer — "not signed in", "no local
    /// history"; a throw is the absence of one, and `UsageBoard.refresh` is the door that catches
    /// it. Nothing here decides between the two twice.
    func load() async throws -> UsageSection
}

/// The board's state, refreshed on an interval while the pane is on screen.
///
/// Polling is per-agent and independent: one agent's network call failing or hanging must not
/// stop another's local read from landing, so sections are merged in as they arrive rather than
/// gathered into one all-or-nothing snapshot.
@MainActor @Observable final class UsageBoard {
    /// One board for the app, not one per visit. Its readings cost a keychain read, a network
    /// round trip and a database scan, and an agent that has to ask its own servers takes seconds
    /// — so stepping out to a session and back shows what was already known rather than starting
    /// every reader again from cold.
    static let shared = UsageBoard()

    private(set) var sections: [UsageSection] = []
    private(set) var refreshing = false

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
        let existing = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        sections = agents.map { agent in
            // A band already carrying numbers keeps them: reopening the pane should show the last
            // reading and let the poll replace it, not blank every agent back to "checking…".
            if let held = existing[agent.id], case .ready = held.status { return held }
            return UsageSection(id: agent.id,
                                title: agent.displayName,
                                status: known.contains(agent.id) ? .loading : .unavailable("no usage data"))
        }
    }

    /// Start polling. Safe to call again — an already-running ticker is left alone so reopening
    /// the pane doesn't stack timers or restart every countdown.
    func start() {
        guard ticker == nil else { return }
        ticker = Guarded.mainTask { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try await Task.sleep(for: .seconds(UsageBoard.refreshInterval))
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

        await withTaskGroup(of: UsageSection?.self) { group in
            for source in sources {
                group.addTask { await Self.read(source) }
            }
            for await section in group {
                if let section { merge(section) }
            }
        }
    }

    /// The door every usage read comes in through. A source that throws has not reported "none" —
    /// it has failed to report at all, and this is the one place with both facts in hand: the band
    /// to say so on, and the agent to count it against.
    nonisolated private static func read(_ source: UsageSource) async -> UsageSection? {
        do {
            return try await source.load()
        } catch is CancellationError {
            // The pane closed mid-read. Leaving the band as it stands is the honest end to work
            // nobody is waiting for any more.
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            // Once per source per run. The read is retried every 60s and its own band already
            // shows the failure continuously, so repeating the event says nothing new and would
            // spend the process-wide fault budget on a condition that is not changing.
            if firstFailure(for: source.agent) {
                Fault.report(.usage, .usageReadFailed, severity: .degraded,
                             details: [.sessionKind(.agent(source.agent)), .stage(.ready)],
                             evidence: error.localizedDescription)
            }
            return UsageSection(id: source.agent, title: source.title,
                                status: .failed("couldn't read usage"))
        }
    }

    /// Sources whose failure has already been counted this run — see the catch in `read`.
    /// Static and lock-guarded because `read` is nonisolated: "once per run" is a property of
    /// the process, not of a board that may be rebuilt when the pane reopens.
    private static let unreadableLock = NSLock()
    nonisolated(unsafe) private static var reportedUnreadable: Set<AgentID> = []

    nonisolated private static func firstFailure(for agent: AgentID) -> Bool {
        unreadableLock.lock(); defer { unreadableLock.unlock() }
        return reportedUnreadable.insert(agent).inserted
    }

    /// Replace one band in place. Order is fixed by `configure`, so a slow source landing last
    /// never reshuffles the board under the reader.
    private func merge(_ section: UsageSection) {
        guard let i = sections.firstIndex(where: { $0.id == section.id }) else { return }
        sections[i] = section
    }
}
