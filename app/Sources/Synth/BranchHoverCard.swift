import SwiftUI

// MARK: - Hover state

/// Hover state for the tabs-mode branch card, shared between the `BranchRow` deep in the tree
/// (which reports the pointer) and the root overlay (which draws). It is a view-model rather than
/// a field on `AppStore` because nothing outside these two places has any business reading it:
/// no persistence, no automation verb, no keyboard path.
///
/// The timings are working.html's, and each one is a measurement rather than a taste:
/// 100ms fires while you scrub the tree and 700ms reads as broken, so a cold open waits 350ms —
/// but once one card has been up, the next branch is effectively instant for a short window,
/// because by then you are reading, not passing through.
@MainActor
@Observable
final class BranchHoverCardModel {
    /// The branch whose card is on screen; nil = nothing showing. The overlay tracks the row by
    /// anchor, so the branch object is all it needs — the position is derived, never stored.
    private(set) var branch: Branch?

    /// Every reason the card must not exist, pushed in by the root view so the model can re-check
    /// it when a queued open finally fires (working.html `hcBlocked`, tested both on the pointer
    /// event and inside `hcShow`). Raising it kills any card outright — a card anchored to a row
    /// that is being dragged, renamed or keyboard-navigated is telling a lie.
    @ObservationIgnored var suppressed = false {
        didSet { if suppressed, !oldValue { snap() } }
    }

    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingID: UUID?
    @ObservationIgnored private var warmUntil = Date.distantPast

    /// Rows before the `+N idle` valve. A card you scroll is a window.
    static let cap = 7
    private static let cold = Duration.milliseconds(350)
    private static let warm = Duration.milliseconds(60)
    private static let warmWindow: TimeInterval = 0.4
    private static let grace = Duration.milliseconds(120)

    /// `--ease-out`, working.html's one deceleration curve. No existing app animation matches it.
    static let easeOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
    /// Row → row repositions the *same* card. Rebuilding one per row is the flicker that makes a
    /// hovering list unusable.
    static let glide = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.13)
    /// CSS `ease`, exactly — the card leaves on opacity alone, and quicker than it arrived.
    static let exit = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.09)

    /// The pointer is over `branch`. Driven by `onContinuousHover`, the native `pointermove`:
    /// a list that scrolls under a stationary pointer re-fires `onHover` but never a real move,
    /// and keying off movement is the whole scroll guard.
    func pointerMoved(over branch: Branch) {
        if suppressed { snap(); return }
        // A branch with nothing in it has nothing to say — and it is a real destination, so
        // whatever is open steps down the ordinary way rather than being cut.
        if branch.sessions.isEmpty { queueHide(); return }
        // Already showing this one — but cancel any queued hide first. SwiftUI churns
        // `.ended`/`.active` far more than the DOM churns pointerout/pointerover, so a spurious
        // exit followed by re-entry onto the same row is common here; returning before the cancel
        // would let that 120ms grace run out under a pointer that never actually left.
        if branch.id == self.branch?.id || branch.id == pendingID {
            closeTask?.cancel(); closeTask = nil
            return
        }
        closeTask?.cancel(); closeTask = nil
        openTask?.cancel()
        pendingID = branch.id
        // A card is already up: row → row is immediate, it only glides across. Otherwise the
        // warm window decides whether this is a first look or a continuation of one.
        let wait = self.branch != nil ? .zero
                 : Date() < warmUntil ? Self.warm
                 : Self.cold
        openTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.show(branch)
        }
    }

    /// The pointer left `branch` (or the row lost its reason to show one). Ignored when the
    /// pointer has already landed elsewhere — SwiftUI does not order the enter and the exit of
    /// two neighbouring rows, so a late exit must not cancel the entry that overtook it.
    func pointerLeft(_ branch: Branch) {
        guard self.branch?.id == branch.id || pendingID == branch.id else { return }
        queueHide()
    }

    private func queueHide() {
        openTask?.cancel(); openTask = nil
        pendingID = nil
        guard closeTask == nil, branch != nil else { return }
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.grace)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func show(_ branch: Branch) {
        openTask = nil
        pendingID = nil
        guard !suppressed, !branch.sessions.isEmpty else { return }
        // Measure the worktree only for a branch actually being looked at, and only once the
        // card has committed to opening — hovering is involuntary, and a git spawn per row the
        // pointer merely crossed is the cost this deferral avoids. Deduped and floored by the
        // cache, so a re-open inside 30s spawns nothing; the line fills in when git answers.
        DiffStatCache.shared.warm([branch])
        if self.branch == nil {
            withAnimation(Self.easeOut) { self.branch = branch }
        } else {
            // Same node, new anchor: the position animates, the contents swap under it.
            withAnimation(Self.glide) { self.branch = branch }
        }
    }

    /// The ordinary fade out, which also opens the warm window the next branch benefits from.
    private func hide() {
        closeTask = nil
        guard branch != nil else { return }
        warmUntil = Date().addingTimeInterval(Self.warmWindow)
        withAnimation(Self.exit) { branch = nil }
    }

    /// Cut the card dead — no fade, and no warm window to soften the next one. This is what a
    /// suppression does: whatever the card was anchored to is no longer trustworthy.
    func snap() {
        openTask?.cancel(); openTask = nil
        closeTask?.cancel(); closeTask = nil
        pendingID = nil
        warmUntil = .distantPast
        branch = nil
    }
}

/// The branch rows publish their bounds; the root overlay reads the hovered one's to place the
/// card. Its own key rather than `MenuAnchorKey` — that one belongs to the kebab cluster, and a
/// shared dictionary would have the two surfaces racing to describe different rectangles.
struct BranchHoverAnchorKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Overlay

/// Places the card beside its row and animates it in and out. Mounted at the window root so it
/// escapes the sidebar's clip (working.html's `position: fixed`), above the notification deck and
/// below every modal.
struct BranchHoverCardOverlay: View {
    @Environment(BranchHoverCardModel.self) private var hover
    let anchors: [UUID: Anchor<CGRect>]

    /// Horizontal gap from the row, and the margin the clamp keeps off each window edge.
    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 12

    var body: some View {
        // Both reads happen in the ordinary body pass, not inside the GeometryReader's content:
        // that closure runs at layout time, and an observation registered there is not reliably
        // the one that invalidates this view — the diffstat would then land silently and only
        // show up on some later open.
        let branch = hover.branch
        // nil until the measurement lands, and the branch line simply isn't drawn until it does —
        // warming from `show` rather than here keeps the git spawns to the branch being looked at.
        let diffStat = branch.flatMap { DiffStatCache.shared.line(for: $0) }
        return GeometryReader { proxy in
            if let branch, let anchor = anchors[branch.id] {
                let row = proxy[anchor]
                BranchHoverCard(branch: branch, diffStat: diffStat)
                    .offset(x: min(row.maxX + Self.gap,
                                   proxy.size.width - BranchHoverCard.width - Self.margin),
                            // Clamp, never flip: the sidebar is pinned to the left of a window
                            // always far wider than 260 + 300, so a horizontal flip would be dead
                            // code that only ever fired as a bug.
                            //
                            // Clamped against the height the card would have WITH its branch line,
                            // even before git has answered. The real height grows by that line
                            // mid-open, and clamping against the current one would place the card
                            // against the bottom edge and then jump it up when the measurement
                            // lands. Over-reserving costs a branch with no line 32.5pt of headroom
                            // at the very bottom of the window, and nothing anywhere else.
                            y: max(Self.margin,
                                   min(row.minY - 4,
                                       proxy.size.height - BranchHoverCard.clampHeight(branch: branch) - Self.margin)))
                    // In: 140ms, opacity plus a 4pt slide out of the row — the direction encodes
                    // where it came from. Out: opacity only, and quicker.
                    .transition(.asymmetric(
                        insertion: AnyTransition.opacity
                            .combined(with: .modifier(active: HoverCardSlide(dx: -4),
                                                      identity: HoverCardSlide(dx: 0)))
                            .animation(BranchHoverCardModel.easeOut),
                        removal: AnyTransition.opacity.animation(BranchHoverCardModel.exit)))
            }
        }
        // Read-only, and that single decision is what removes the hover-trap, the safe triangle,
        // and every focus/menu concern with them. Acting on a session is what clicking the row
        // and landing in the tab strip is for.
        .allowsHitTesting(false)
        // A visual affordance, not content: the same summary rides the branch row's own
        // accessibility label, so the answer is reachable without a pointer and no hover-only
        // surface exists in the accessibility tree at all.
        .accessibilityHidden(true)
    }
}

/// The entry slide. `AnyTransition.offset` would move the card's *layout*, which here is an
/// absolute offset already — this shifts only the rendered result.
private struct HoverCardSlide: ViewModifier {
    let dx: CGFloat
    func body(content: Content) -> some View { content.offset(x: dx) }
}

// MARK: - The card

/// The sessions a tabs-mode branch row stopped listing, unpacked one level.
///
/// Reaching for a branch row fades its whole rail — the PR glyph and the roll-up both go to 0
/// under the action cluster — so the instant you point at a worktree you lose its only
/// per-session signal. This is what pays that back. Scope is deliberately one question: "is
/// anything in here waiting on me or broken, and is anything still moving?" The branch name is
/// never repeated; the row under the pointer is already showing it.
struct BranchHoverCard: View {
    let branch: Branch
    /// The branch's worktree diffstat (`"+412 −128 · 6 ahead of main"`), or nil when there is
    /// nothing to say — then the branch line carries the PR chip alone, with no separator.
    let diffStat: String?

    /// Fixed, not a maximum: a card that resizes per row jitters as you run down the list, and
    /// that reads as cheap.
    static let width: CGFloat = 300
    static let radius: CGFloat = 12
    private static let pad: CGFloat = 5
    private static let rowHeight: CGFloat = 28
    private static let lineHeight: CGFloat = 24
    /// A 0.5pt rule inset 4pt above and below.
    private static let ruleHeight: CGFloat = 8.5

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    var body: some View {
        let (shown, hidden) = Self.rows(branch)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { session in
                HoverCardSessionRow(session: session, plate: Theme.glass)
            }
            if hidden > 0 {
                Self.footLine { Text(verbatim: "+\(hidden) idle") }
            }
            if Self.hasBranchLine(branch: branch, diffStat: diffStat) {
                rule
                Self.footLine { branchLine }
            }
        }
        .padding(Self.pad)
        .frame(width: Self.width)
        .background(shape.fill(Theme.glass).background(.ultraThinMaterial, in: shape))
        .overlay(shape.strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
    }

    private var rule: some View {
        Rectangle().fill(Theme.border)
            .frame(height: 0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    /// The branch's own line: the PR *number* the rail's bare state glyph has no room to say, and
    /// a diffstat that lives nowhere else in the shell. Deliberately monochrome apart from the PR
    /// glyph — this app spends colour on state, and a diffstat is not a state.
    @ViewBuilder private var branchLine: some View {
        HStack(spacing: 5) {
            if let pr = branch.pr {
                HStack(spacing: 4) {
                    Phos(path: pr.state.glyph, size: 13)
                        .foregroundStyle(pr.state.tint)
                    Text(verbatim: "#\(pr.number)")
                        .font(.sans(11, 600, tabular: true))
                }
            }
            if let diffStat {
                // The separator is its own item so the spacing lands evenly on both sides.
                if branch.pr != nil { Text(verbatim: "·") }
                Text(diffStat)
            }
        }
    }

    private static func footLine<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.sans(11, 500, tabular: true))
            .foregroundStyle(Theme.inkFaint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: lineHeight, alignment: .leading)
    }

    // MARK: Content rules

    /// "Interesting" = not idle, or idle with output nobody has read. Everything else is filler
    /// the eye steps over on every single hover, and that cost compounds while its value does not.
    private static func isLive(_ session: Session) -> Bool {
        session.status.rollup != .idle || session.unread
    }

    /// The sessions the card lists, and how many idle ones it swallowed.
    ///
    /// Flat, in sidebar order, splits not folded — and **never** re-sorted by state: the card has
    /// to map onto the tab strip you are about to land in, and state ranking is carried by the
    /// glyph column, not by rows moving around under the pointer. Every live session shows;
    /// idle ones fill the remaining space up to the cap, and the rest collapse to `+N idle`.
    static func rows(_ branch: Branch) -> (shown: [Session], hidden: Int) {
        let all = branch.sessions
        let quiet = all.filter { !isLive($0) }
        let room = max(0, BranchHoverCardModel.cap - (all.count - quiet.count))
        guard quiet.count > room else { return (all, 0) }
        let dropped = Set(quiet.dropFirst(room).map(\.id))
        return (all.filter { !dropped.contains($0.id) }, dropped.count)
    }

    /// No PR and no diffstat: neither the line nor the rule above it.
    static func hasBranchLine(branch: Branch, diffStat: String?) -> Bool {
        branch.pr != nil || diffStat != nil
    }

    /// The card's height, computed rather than measured — every row in it is a fixed height, and
    /// the vertical clamp needs the number *before* the card is laid out.
    static func height(branch: Branch, diffStat: String?) -> CGFloat {
        let (shown, hidden) = rows(branch)
        var h = pad * 2 + CGFloat(shown.count) * rowHeight
        if hidden > 0 { h += lineHeight }
        if hasBranchLine(branch: branch, diffStat: diffStat) { h += ruleHeight + lineHeight }
        return h
    }

    /// What the vertical clamp reserves: the height the card will have *once* its diffstat lands,
    /// not the one it has while git is still being asked. The card grows by a line mid-open, and a
    /// clamp that tracked that growth would place the card on the bottom edge and then jump it.
    static func clampHeight(branch: Branch) -> CGFloat {
        height(branch: branch, diffStat: "")
    }
}

/// One session: `[14pt icon][name][meta][16pt indicator]`. The icon and the indicator are the
/// sidebar's own components rather than re-derived state, so the card can never disagree with the
/// rail it stands in for, and it introduces no status vocabulary of its own.
private struct HoverCardSessionRow: View {
    @Environment(AppStore.self) private var store
    let session: Session
    /// The card's own fill, worn as the plate behind the unread dot.
    let plate: Color

    /// One fact per session, and only where the session genuinely produces one — a step count, a
    /// failure count. Nothing in the app plumbs a counter today (`Session` carries no numeric
    /// field and the hook wire format has none), so this is always nil and the column collapses.
    /// It is deliberately NOT the status word: the indicator column already says that, and
    /// duplicating it is exactly what the design cut. A real `String?` drops straight in here.
    ///
    /// No clocks either: the glyph already says whether a session needs you, and an "8m" beside
    /// it is an ageing number that never once changed whether you'd go there.
    private var meta: String? { nil }

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(session.title)
                .font(.sans(12.5, session.unread ? 560 : 500))
                .foregroundStyle(session.unread ? Theme.sessionNameUnread : Theme.inkMeta)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(meta ?? "")
                .font(.sans(11, 500, tabular: true))
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
            indicator
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    /// Literally the tab's icon — same component, same unread mark, only the plate behind the dot
    /// changes to the card's own fill. Two copies of that recipe would be two things to keep in
    /// step, and the whole point of this card is that it cannot disagree with what it stands in for.
    private var icon: some View {
        TabIcon(session: session, ring: plate)
    }

    /// The same status/owner slot the sidebar row carries: a browser owned by an agent wears the
    /// owner's mark instead of a liveness dot.
    @ViewBuilder private var indicator: some View {
        if session.ownerSessionID != nil, let owner = store.owner(of: session) {
            OwnedIndicator(ownerKind: owner.kind)
        } else if session.ownerSessionID != nil {
            OwnedIndicator()
        } else {
            StatusIndicator(status: session.status)
        }
    }
}

// MARK: - The spoken form

extension Branch {
    /// The card's answer in words, carried by the branch row itself so it is reachable without a
    /// pointer (working.html `hcLabel`). Only non-zero parts appear, and working + running are
    /// summed — the distinction is an implementation detail of the beat, not something to say
    /// out loud. Empty when the branch has no sessions, which is also when there is no card.
    var hoverCardLabel: String? {
        guard !sessions.isEmpty else { return nil }
        func count(_ state: RollupState) -> Int { sessions.filter { $0.status.rollup == state }.count }
        var parts = ["\(sessions.count) session\(sessions.count == 1 ? "" : "s")"]
        if count(.input) > 0 { parts.append("\(count(.input)) needs input") }
        if count(.error) > 0 { parts.append("\(count(.error)) failed") }
        let running = count(.work) + count(.run)
        if running > 0 { parts.append("\(running) running") }
        let unread = sessions.filter(\.unread).count
        if unread > 0 { parts.append("\(unread) unread") }
        return "\(name) — \(parts.joined(separator: ", "))"
    }
}

/// Puts that summary on the branch row. Gated on tabs mode: with the tree three deep the session
/// rows are already in the accessibility tree, one each, and rolling them up onto their parent
/// would only say the same thing twice.
struct BranchHoverCardLabel: ViewModifier {
    let branch: Branch
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, let label = branch.hoverCardLabel {
            // `.combine` first: the row is a ZStack of the branch button and the hover-revealed
            // action cluster, so without it the label has no single element to land on and gets
            // pushed down onto the buttons inside instead. The card itself is accessibilityHidden,
            // which makes this row the only place the answer exists for a non-pointer reader.
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: label))
        } else {
            content
        }
    }
}
