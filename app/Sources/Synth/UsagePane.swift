import SwiftUI

/// The Usage board (working.html `renderUsage`): one band per hosted agent, one tile per number
/// it can report.
///
/// Every agent is drawn by one code path and one tile. An agent that reports a real rolling-window
/// percentage and one that can only offer a local token total get the SAME frame and the same type
/// scale — what differs is the number inside, never the treatment, because tile size reading as
/// importance would rank the agents rather than describe their data.
struct UsagePane: View {
    @Environment(AppStore.self) private var store
    /// Shared, so stepping out to a session and back shows the last reading instead of asking
    /// every agent again — one of which takes seconds to answer.
    @State private var board = UsageBoard.shared
    @State private var now = Date()

    /// One clock for the whole pane. A timer per counting tile would let them drift apart, and a
    /// board of a dozen windows would wake the app a dozen times a second to say the same thing.
    /// Held in state because a stored publisher is rebuilt every time the parent's body runs, and
    /// a countdown that restarts its second on every unrelated store change never finishes one.
    @State private var clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            head
            ScrollView {
                grid
                    .frame(maxWidth: 760, alignment: .leading)
                    // Centred, like Settings' column: a fixed measure held to one edge of a pane
                    // as wide as the window pools every spare pixel on the other side.
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(clock) { now = $0 }
        .task {
            let agents = store.availableAgents
            board.configure(agents: agents, sources: UsageSources.all(for: agents))
            board.start()
        }
        .onDisappear { board.stop() }
    }

    // MARK: Head (working.html .pane__head)

    private var head: some View {
        HStack(spacing: 10) {
            if store.sidebarCollapsed { SidebarToggle().padding(.trailing, 2) }
            Phos(path: Phosphor.usage, size: 16).foregroundStyle(Theme.inkMuted).frame(width: 18)
            Text("Usage")
                .font(.sans(13, 600))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
        .padding(.leading, store.sidebarCollapsed ? Theme.trafficLightsClearance : 18)
        .padding(.trailing, 18)
        .frame(height: Theme.titlebarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }

    // MARK: Board

    private var grid: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(bands) { band in
                bandHead(band)
                ForEach(band.rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row.tiles) { tile in
                            UsageTile(metric: tile.metric, index: tile.index, now: now)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The agent, in the same uppercase meta voice Settings uses for a section label — a header
    /// means the same thing on both panes.
    private func bandHead(_ band: Band) -> some View {
        HStack(spacing: 9) {
            SessionIcon(kind: .agent(band.section.id), size: 15)
            Text(band.section.title.uppercased())
                .font(.sans(11, 650))
                .kerning(0.66)
                .foregroundStyle(Theme.inkMeta)
            Spacer(minLength: 0)
        }
        .padding(.top, band.first ? 2 : 16)
        .padding(.leading, 2)
        .usageEntrance(index: band.index)
    }

    /// The pane laid out in reading order, with the running index that drives the entrance sweep:
    /// band heads consume one too, so the stagger runs continuously down the board instead of
    /// restarting at every agent.
    private var bands: [Band] {
        var index = 0
        return board.sections.enumerated().map { position, section in
            let head = index
            index += 1
            var rows: [Row] = []
            var pending: [Slot] = []
            for metric in metrics(for: section) {
                pending.append(Slot(id: "\(section.id.rawValue):\(metric.id)", metric: metric, index: index))
                index += 1
                if pending.count == 2 {
                    rows.append(Row(id: pending[0].id, tiles: pending))
                    pending = []
                }
            }
            // An odd metric out would leave a hole in a two-up grid, so it takes the whole row.
            if let last = pending.first { rows.append(Row(id: last.id, tiles: pending)) }
            return Band(id: section.id.rawValue, section: section, index: head,
                        first: position == 0, rows: rows)
        }
    }

    /// A band that has nothing to report says so in a tile of its own rather than being dropped:
    /// the number is an em-dash because the board never invents one to fill the gap, and the tile
    /// carries no eyebrow because there is no measurement here to name.
    private func metrics(for section: UsageSection) -> [UsageMetric] {
        switch section.status {
        case .ready:
            return section.metrics
        case .loading:
            return [UsageMetric(id: "status", label: "", value: "—", percent: nil, detail: .text("checking…"))]
        case .unavailable(let reason):
            return [UsageMetric(id: "status", label: "", value: "—", percent: nil, detail: .text(reason))]
        }
    }

    private struct Band: Identifiable {
        let id: String
        let section: UsageSection
        let index: Int
        let first: Bool
        let rows: [Row]
    }

    private struct Row: Identifiable {
        let id: String
        let tiles: [Slot]
    }

    private struct Slot: Identifiable {
        let id: String
        let metric: UsageMetric
        let index: Int
    }
}

/// One tile, every agent.
///
/// Hierarchy inside it is typographic, in four fixed steps: eyebrow (what this measures, quiet),
/// value (the answer, loud), meter (the answer again, spatially), detail (when it resets, quiet).
/// A metric with no percentage behind it drops the meter and keeps every other step — and the two
/// groups being pushed apart is what keeps that tile's detail line on the same baseline as a
/// metered neighbour's.
private struct UsageTile: View {
    let metric: UsageMetric
    let index: Int
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if !metric.label.isEmpty {
                    Text(metric.label)
                        .font(.sans(11, 550))
                        .foregroundStyle(Theme.ink4)
                }
                RollingNumber(text: metric.value, font: .mono(30, 600), face: 30, tracking: -0.3)
                    .foregroundStyle(Theme.ink)
            }
            Spacer(minLength: 14)
            VStack(alignment: .leading, spacing: 8) {
                if let percent = metric.percent {
                    UsageMeter(percent: percent, tileIndex: index)
                }
                // A window the server reports with no reset time (a per-model cap nothing has been
                // spent against yet) has nothing to say down here, and an empty line would leave
                // the tile looking like it failed to load one.
                if !detail.isEmpty {
                    RollingNumber(text: detail, font: .mono(11), face: 11)
                        .foregroundStyle(Theme.inkMeta)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 146, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        // A lit top edge rather than a heavier shadow: the tile catches light instead of floating,
        // which is what keeps a grid of flat rectangles from reading as a spreadsheet. Inset by the
        // corner radius so the line stops where the corner starts turning.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.dyn(0xFFFFFF, 0.7, 0xFFFFFF, 0.055))
                .frame(height: 1)
                .padding(.horizontal, 14)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
        .usageEntrance(index: index)
    }

    private var detail: String {
        switch metric.detail {
        case .text(let text): return text
        case .resets(let date): return Self.countdown(date.timeIntervalSince(now))
        }
    }

    /// Seconds appear only inside the last hour, where they're the part that's actually changing;
    /// above that they'd be noise on a number that moves once a minute.
    private static func countdown(_ remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "resetting…" }
        let total = Int(remaining)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        if minutes > 0 { return "resets in \(minutes)m \(String(format: "%02d", seconds))s" }
        return "resets in \(seconds)s"
    }
}

/// Bands and tiles arrive on a stagger — the data landing, not a flourish.
///
/// Each view drives its own arrival rather than reading a flag the pane sets once. The board fills
/// in as its readers answer — a local database in milliseconds, an agent that has to ask its own
/// servers in seconds — so tiles are inserted over and over as sections land. A pane-wide flag is
/// true long before most of them exist, and an inserted view whose state was already settled just
/// appears: the sweep would play on the placeholders and never on the numbers.
private struct UsageEntrance: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 7)
            .animation(reduceMotion ? nil
                                    : .timingCurve(0.23, 1, 0.32, 1, duration: 0.3)
                                        .delay(Double(index) * 0.045),
                       value: shown)
            .onAppear { shown = true }
    }
}

private extension View {
    func usageEntrance(index: Int) -> some View {
        modifier(UsageEntrance(index: index))
    }
}
