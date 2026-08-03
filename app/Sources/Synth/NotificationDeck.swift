import SwiftUI

/// The in-app notification layer (working.html's `.notifs`): background sessions escalated to
/// quiet glass toasts, stacked bottom-left, hugging the sidebar. One toast reads plainly; two
/// or more collapse into a deck — a burning undo first, then standing asks, then receipts,
/// newest first inside each (`InAppNotif.band`) — the two behind the front peeking, anything
/// past three folded under a "+N" pill. Hovering the deck fans it into individually clickable
/// cards and holds every draining toast's countdown; a click runs the card's action, ⌘↩ the
/// front's. A card buried under "+N" holds its countdown too — it is not on screen to be read.
/// Mounted at the window root so it sits at the whole shell's bottom-left corner, over the
/// sidebar (hidden in settings), and driven purely by `AppStore.notifOrder`.
///
/// Three tiers ride one chassis. Tier 1 (`.attention`) is sticky: a session asking, a session
/// that broke, an app operation that failed, a decision waiting. Tier 2 is the undo window.
/// Tier 3 (`.ambient`) is a result — smaller chip, tighter padding, lighter verb. The tier
/// changes presence, never the shape, so a deck of mixed tiers still reads as one stack.
struct NotificationDeck: View {
    @Environment(AppStore.self) private var store
    @State private var hovering = false
    @State private var cardHeights: [UUID: CGFloat] = [:]

    // How far each card behind the front rises, TOP edge to top edge (working.html --peek), and
    // how the peeking cards shrink / dim; a fourth+ card hides behind "+N".
    fileprivate static let peekRise: CGFloat = 10.5
    /// One entry per `AppStore.notifDeckDepth` — how far a card dims as it falls back.
    fileprivate static let peekOpacity: [Double] = [1, 0.7, 0.45]
    fileprivate static let cardWidth: CGFloat = 320
    fileprivate static let cornerRadius: CGFloat = 13

    // The hover-fan can't be driven headless (no pointer over an inactive window), so a
    // DEBUG-only flag forces the spread for screenshotting. Always false in release.
    private var debugSpread: Bool {
        #if DEBUG
        return store.debugDeckSpread
        #else
        return false
        #endif
    }

    var body: some View {
        let order = store.notifOrder
        if !order.isEmpty {
            let spread = (hovering || debugSpread) && order.count > 1
            let heights = order.map { cardHeights[$0.id] ?? 56 }
            let frontH = heights[0]
            let peeks = min(order.count, Self.peekOpacity.count)
            let collapsedH = frontH + CGFloat(peeks - 1) * Self.peekRise + 6
            let offsets = Self.offsets(heights: heights, frontH: frontH, spread: spread)
            let fannedH = heights.reduce(0) { $0 + $1 + 9 } - 9 + 4

            ZStack(alignment: .bottomLeading) {
                ForEach(Array(order.enumerated()), id: \.element.id) { index, notif in
                    NotifCard(notif: notif, isFront: index == 0) { h in cardHeights[notif.id] = h }
                        .modifier(DeckPlacement(index: index, spread: spread, count: order.count,
                                                offsetY: offsets[index]))
                        .zIndex(Double(100 - index))
                }
                if order.count > Self.peekOpacity.count, !spread {
                    MorePill(count: order.count - Self.peekOpacity.count)
                        .offset(x: 13, y: -(frontH + CGFloat(Self.peekOpacity.count - 1) * Self.peekRise + 8))
                        .zIndex(200)
                        .transition(.opacity)
                }
            }
            .frame(width: Self.cardWidth, alignment: .bottomLeading)
            .frame(height: spread ? fannedH : collapsedH, alignment: .bottomLeading)
            .animation(.easeOut(duration: 0.24), value: spread)
            .animation(.easeOut(duration: 0.24), value: order.map(\.id))
            // Drop measured heights for toasts that have left the deck — NotifCard only ever
            // writes into cardHeights, so without this it grows one entry per notified session.
            .onChange(of: order.map(\.id)) { _, ids in
                let live = Set(ids)
                cardHeights = cardHeights.filter { live.contains($0.key) }
            }
            .onHover { over in
                guard !store.pointerStale else { return }
                hovering = over
                store.setNotifDrainPaused(over)
            }
            // The deck can vanish under the pointer (last card clicked away) with no
            // exit hover event — don't leave the next raise's drain frozen.
            .onDisappear { store.setNotifDrainPaused(false) }
            .padding(22)
        }
    }

    /// Where each card sits, measured from the deck's shared bottom edge.
    ///
    /// Collapsed, cards are anchored by their **top** edge: card i's top sits `peekRise * i`
    /// above the front card's top, whatever the two heights are. A flat rise off the shared
    /// bottom edge only worked while every card was the same height — a 52pt card behind a 66pt
    /// front vanishes under it completely, and heights vary the moment a card can carry a
    /// sub-line. Fanned, cards stack by their own heights plus a gutter.
    static func offsets(heights: [CGFloat], frontH: CGFloat, spread: Bool) -> [CGFloat] {
        guard heights.count > 1 else { return heights.map { _ in 0 } }
        var out: [CGFloat] = []
        var fan: CGFloat = 0
        for (i, h) in heights.enumerated() {
            out.append(spread ? -fan : -(frontH + CGFloat(i) * peekRise - h))
            fan += h + 9
        }
        return out
    }
}

/// Places a card within the deck by its rank. A lone card sits flat; behind the front, cards
/// rise + shrink + dim (collapsed) or fan to their own heights at full size (spread).
private struct DeckPlacement: ViewModifier {
    let index: Int
    let spread: Bool
    let count: Int
    let offsetY: CGFloat

    func body(content: Content) -> some View {
        let single = count <= 1
        let i = CGFloat(index)
        let scale: CGFloat = single ? 1 : (spread ? 1 : max(0.5, 1 - i * 0.045))
        let opacity: Double = single ? 1 : (spread ? 1 : (index < NotificationDeck.peekOpacity.count ? NotificationDeck.peekOpacity[index] : 0))
        content
            .scaleEffect(scale, anchor: .bottom)
            .offset(y: single ? 0 : offsetY)
            .opacity(opacity)
            // Cards folded behind "+N" ignore the pointer until the deck is fanned.
            .allowsHitTesting(spread || opacity > 0)
    }
}

/// One glass toast — the sidebar indicator escalated: the state glyph in a tinted chip, the
/// row's identity (workspace colour · kind icon · title), a one-line verb, optional evidence
/// under it, the card's own action button, and a dismiss × on hover. Entering with a calm rise
/// (working.html `.notif.in`).
private struct NotifCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let notif: InAppNotif
    let isFront: Bool
    let onHeight: (CGFloat) -> Void
    @State private var shown = false
    @State private var hovering = false

    private var session: Session? { store.session(notif.id) }
    // The live session when it still exists; the notif's raise-time snapshot once an
    // exit-close toast has outlived its row.
    private var displayKind: SessionKind { session?.kind ?? notif.sessionKind }
    private var displayTitle: String { session?.title ?? notif.title }
    /// A card with nothing to name carries no who-line at all. The row used to render
    /// unconditionally, so a message raised with an empty title floated a dot and a 12pt glyph
    /// over nothing.
    private var showsWho: Bool { notif.kind != .undo && !displayTitle.isEmpty }
    private var chipColor: Color {
        let idx = session.flatMap { s in store.branch(of: s).flatMap { store.workspace(of: $0) }?.colorIndex }
            ?? notif.colorIndex
        guard let idx else { return Theme.inkFaint }
        return Theme.chipColors[idx % Theme.chipColors.count]
    }
    private var ambient: Bool { notif.tier == .ambient }

    var body: some View {
        HStack(spacing: ambient ? 10 : 11) {
            glyph
            VStack(alignment: .leading, spacing: 1) {
                if showsWho { who }
                Text(notif.message ?? notifVerb(displayKind, notif.kind))
                    .font(.system(size: 12.5, weight: ambient ? .medium : .semibold))
                    .foregroundStyle(ambient ? Theme.ink2 : Theme.inkOpen)
                    .lineLimit(1).truncationMode(.tail)
                if let sub = notif.sub {
                    Text(sub)
                        .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            // The text column takes the slack itself (working.html's `1fr`) rather than a Spacer
            // between it and the button: a Spacer is a third column, so the HStack's gap is paid
            // twice and the words lose 17pt of a 320pt card to whitespace nobody asked for.
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = notif.action { actionButton(action) }
        }
        .padding(ambient
                 ? EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 12)
                 : EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 12))
        .frame(width: NotificationDeck.cardWidth, alignment: .leading)
        .background(cardSurface)
        // Attention cards ask for an answer, so they carry no bar and never self-dismiss.
        .overlay(alignment: .bottom) { if notif.drains { NotifTimerBar(notif: notif) } }
        // Clip before the shadow and before the ×: the bar is clipped by the card's own corner
        // radius, the shadow stays outside it, and the × is free to sit over the corner.
        .clipShape(RoundedRectangle(cornerRadius: NotificationDeck.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
        // The body still carries the primary action, so the whole card stays a big target — the
        // × and the button sit above it and consume their own clicks.
        //
        // Order is load-bearing: the card's hit shape must be pinned UNDER the × overlay, not
        // over it. A `contentShape` above the × confines everything beneath it to that one
        // rounded rect — and the × hangs 6pt past the top-right corner, so the only live part of
        // it was the thin crescent where the disc laps the corner. Its centre, and the whole
        // outer two thirds, answered nothing: a × that lit up on hover, took the pointer, and
        // could not be clicked shut unless you happened to aim at its inside edge.
        .contentShape(RoundedRectangle(cornerRadius: NotificationDeck.cornerRadius))
        .onTapGesture { store.runNotifAction(notif.id) }
        // 9 = the 6pt the disc overhangs the corner by, plus the 3pt of invisible target ring
        // around it, so the disc itself still lands on working.html's -6/-6.
        .overlay(alignment: .topTrailing) { dismissButton.offset(x: 9, y: -9) }
        .onHover { hovering = $0 }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { onHeight(g.size.height) }
                    .onChange(of: g.size.height) { _, h in onHeight(h) }
            }
        )
        // Entrance: a ~200ms ease-out rise, no bounce (working.html translateY/scale/opacity).
        .scaleEffect(shown ? 1 : 0.975, anchor: .bottom)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 12)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
        }
    }

    private var glyphColor: Color {
        switch notif.kind {
        case .error: return Theme.danger
        case .input: return Theme.input
        case .done:  return Theme.run
        case .undo:  return notif.destructive ? Theme.danger : Theme.inkMuted
        // The app talking about its own work never wears a session's state colour.
        case .neutral: return Theme.ink4
        }
    }
    private var glyphPath: String {
        switch notif.kind {
        case .error: return Phosphor.exclamation
        case .input: return Phosphor.question
        case .done:  return notif.iconPath ?? Phosphor.check
        case .undo:  return notif.iconPath ?? Phosphor.reset
        case .neutral: return notif.iconPath ?? Phosphor.check
        }
    }

    // The escalated sidebar AttentionGlyph: same Phosphor path + state colour, breathing on
    // needs-input. Attention wears it in a 26pt chip, ambient in 22 — a result, not a summons.
    private var glyph: some View {
        let box: CGFloat = ambient ? 22 : 26
        let mark: CGFloat = ambient ? 14 : 17
        // An undo card for a closed session shows that session's own mark, so you can tell a
        // Claude row from a terminal at a glance. Everything else uses a glyph.
        return Group {
            if notif.kind == .undo, notif.iconPath == nil {
                SessionIcon(kind: notif.sessionKind, size: mark)
            } else {
                Phos(path: glyphPath, size: mark)
            }
        }
            .foregroundStyle(glyphColor)
            .modifier(BreatheIf(on: notif.kind == .input))
            .frame(width: box, height: box)
            .background(RoundedRectangle(cornerRadius: ambient ? 7 : 8).fill(glyphColor.opacity(0.13)))
    }

    private var who: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(chipColor).frame(width: 7, height: 7)
            Group {
                if let path = notif.iconPath, notif.kind != .undo {
                    Phos(path: path, size: 12).foregroundStyle(Theme.inkFaint)
                } else {
                    SessionIcon(kind: displayKind, size: 12, tint: Theme.inkFaint)
                }
            }
            .frame(width: 12, height: 12)
            Text(displayTitle)
                .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    /// The action is a real target with the chord printed inside it, not grey helper text beside
    /// it. Only the front card shows the keys, because ⌘↩ only ever aims at the front card.
    private func actionButton(_ action: NotifAction) -> some View {
        Button { store.runNotifAction(notif.id) } label: {
            HStack(spacing: 6) {
                Text(action.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(action.danger ? Theme.danger : Theme.ink2)
                if isFront { NotifKeyCaps() }
            }
            .padding(EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 8))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.raised)
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(action.danger ? Theme.danger.opacity(0.28) : Theme.border, lineWidth: 0.5))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// Leaving is not acting. It fades in on hover so a resting deck stays quiet, and sits over
    /// the corner so it never moves the layout.
    private var dismissButton: some View {
        Button { store.dismissNotif(notif.id) } label: {
            Phos(path: Phosphor.close, size: 9)
                .foregroundStyle(Theme.ink4)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(Theme.raised)
                        .overlay(Circle().strokeBorder(Theme.borderStrong, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                )
                // An 18pt disc half-hanging off a corner is a mean thing to ask a pointer to
                // land on, so the target reaches 3pt past what it draws — the ring is invisible
                // and moves nothing (working.html `.notif__x::before`).
                .padding(3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: NotificationDeck.cornerRadius, style: .continuous)
            .fill(Theme.glass)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NotificationDeck.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NotificationDeck.cornerRadius, style: .continuous).fill(Theme.rowHover).opacity(hovering ? 1 : 0))
            .overlay(RoundedRectangle(cornerRadius: NotificationDeck.cornerRadius, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 0.5))
    }
}

/// working.html `.notif__timer` — a self-dismissing card's remaining life made visible: a 2pt
/// `--focus` bar along the bottom edge, draining left linearly.
///
/// The bar has two ends and they are not the same problem. The origin end is arbitrary, so it
/// fades out over 20pt and nothing terminates it; the far end is where the corner is, so the
/// card's own radius clips it (the caller applies `.clipShape` above this overlay) rather than
/// the bar retreating 13pt and pretending the corner is not there. The live edge in between
/// stays crisp, because nothing masks the middle — and the last moments of the drain dissolve
/// into the taper instead of a 2pt stub snapping to zero.
///
/// It renders the same store clock the dismissal task sleeps on, so bar and timer can never
/// disagree; a paused deck shows it frozen at the banked fraction. Deliberately not gated on
/// reduce-motion — the bar is the timer's display, not decoration.
/// ⌘↩ printed inside a card's button. Deliberately not `KeyCaps`, which is the palette's
/// `.cmdk__key` — working.html gives the card its own smaller cap (`.notif__act kbd`: 10px mono,
/// 15pt square, tighter gap) and the difference is load-bearing rather than cosmetic. The card is
/// 320pt wide with the verb line and the button competing for it, and the palette's caps are wide
/// enough to eat the words: "Synth 0.13.1 is ready" truncated at "is r…" while they were in here.
private struct NotifKeyCaps: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(["⌘", "↩"], id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.ink4)
                    .lineLimit(1).fixedSize()
                    .frame(minWidth: 15, minHeight: 15)
                    .padding(.horizontal, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.panel)
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Theme.line, lineWidth: 0.5))
                    )
            }
        }
    }
}

private struct NotifTimerBar: View {
    let notif: InAppNotif

    private var tint: Color { notif.destructive ? Theme.danger : Theme.focus }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: notif.armedAt == nil)) { ctx in
            Rectangle()
                .fill(tint)
                .frame(height: 2)
                .scaleEffect(x: notif.timerFraction(at: ctx.date), anchor: .leading)
                .opacity(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The mask sits outside the scale, so the taper holds still while the fill
                // drains through it.
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 20 / NotificationDeck.cardWidth)],
                                   startPoint: .leading, endPoint: .trailing)
                )
        }
        .allowsHitTesting(false)
    }
}

/// working.html `.notifs__more` — a quiet "+N" pill for cards folded behind a deck deeper than three.
private struct MorePill: View {
    let count: Int
    var body: some View {
        Text("+\(count)")
            .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(
                Capsule().fill(Theme.glass)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.borderStrong, lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// Applies the sidebar's `attn-breathe` only for needs-input (errors sit still), so the glyph
/// reuse matches Sidebar.swift exactly.
private struct BreatheIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { on ? AnyView(content.attnBreathe()) : AnyView(content) }
}
