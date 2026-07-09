import SwiftUI

/// The in-app notification layer (working.html's `.notifs`): background sessions escalated to
/// quiet glass toasts, stacked bottom-left, hugging the sidebar. One toast reads plainly; two
/// or more collapse into a deck — most-urgent in front, the two behind peeking, anything past
/// three folded under a "+N" pill. Hovering the deck fans it into individually clickable cards;
/// a click jumps to that session, ⌘↩ to the front. Mounted as an overlay on the content pane
/// (hidden in settings) and driven purely by `AppStore.notifOrder`.
struct NotificationDeck: View {
    @Environment(AppStore.self) private var store
    @State private var hovering = false
    @State private var cardHeights: [UUID: CGFloat] = [:]

    // How far peeking cards rise / dim behind the front (working.html --i math): each step up
    // 10.5px, scaled 0.045 smaller, at opacity 1 / 0.7 / 0.45; a fourth+ card hides behind "+N".
    fileprivate static let peekRise: CGFloat = 10.5
    fileprivate static let peekOpacity: [Double] = [1, 0.7, 0.45]
    fileprivate static let cardWidth: CGFloat = 320

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
            let frontH = order.first.flatMap { cardHeights[$0.id] } ?? 56
            let step = frontH + 9                       // fanned gap: card height + breathing room
            let peeks = min(order.count, Self.peekOpacity.count)
            let collapsedH = frontH + CGFloat(peeks - 1) * Self.peekRise + 6
            let fannedH = CGFloat(order.count - 1) * step + frontH + 4

            ZStack(alignment: .bottomLeading) {
                ForEach(Array(order.enumerated()), id: \.element.id) { index, notif in
                    NotifCard(notif: notif, isFront: index == 0) { h in cardHeights[notif.id] = h }
                        .modifier(DeckPlacement(index: index, spread: spread, count: order.count, step: step))
                        .zIndex(Double(100 - index))
                }
                if order.count > Self.peekOpacity.count, !spread {
                    MorePill(count: order.count - Self.peekOpacity.count)
                        .offset(x: 13, y: -(frontH + 26))
                        .zIndex(200)
                        .transition(.opacity)
                }
            }
            .frame(width: Self.cardWidth, alignment: .bottomLeading)
            .frame(height: spread ? fannedH : collapsedH, alignment: .bottomLeading)
            .animation(.easeOut(duration: 0.24), value: spread)
            .animation(.easeOut(duration: 0.24), value: order.map(\.id))
            .onHover { hovering = $0 }
            .padding(22)
        }
    }
}

/// Places a card within the deck by its rank. A lone card sits flat; behind the front, cards
/// rise + shrink + dim (collapsed) or fan to an even gap at full size (spread).
private struct DeckPlacement: ViewModifier {
    let index: Int
    let spread: Bool
    let count: Int
    let step: CGFloat

    func body(content: Content) -> some View {
        let single = count <= 1
        let i = CGFloat(index)
        let offsetY: CGFloat = single ? 0 : (spread ? -i * step : -i * NotificationDeck.peekRise)
        let scale: CGFloat = single ? 1 : (spread ? 1 : max(0.5, 1 - i * 0.045))
        let opacity: Double = single ? 1 : (spread ? 1 : (index < NotificationDeck.peekOpacity.count ? NotificationDeck.peekOpacity[index] : 0))
        content
            .scaleEffect(scale, anchor: .bottom)
            .offset(y: offsetY)
            .opacity(opacity)
            // Cards folded behind "+N" ignore the pointer until the deck is fanned.
            .allowsHitTesting(spread || opacity > 0)
    }
}

/// One glass toast — the sidebar indicator escalated: the state glyph in a tinted chip, the
/// row's identity (workspace colour · kind icon · title), a one-line verb, and — front only —
/// the muted ⌘↩ hint. Entering with a calm rise (working.html `.notif.in`).
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
    private var chipColor: Color {
        let idx = session.flatMap { s in store.branch(of: s).flatMap { store.workspace(of: $0) }?.colorIndex }
            ?? notif.colorIndex
        guard let idx else { return Theme.inkFaint }
        return Theme.chipColors[idx % Theme.chipColors.count]
    }

    var body: some View {
        // A system toast (no session — a failed background worktree op) persists until
        // this click; a session toast jumps as before.
        Button { if let s = session { store.jump(to: s) } else { store.clearNotif(notif.id) } } label: {
            HStack(spacing: 11) {
                glyph
                VStack(alignment: .leading, spacing: 1) {
                    who
                    Text(notif.message ?? notifVerb(displayKind, notif.kind))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.inkOpen)
                        .lineLimit(1).truncationMode(.tail)
                }
                if isFront {
                    Spacer(minLength: 6)
                    hint
                }
            }
            .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 12))
            .frame(width: NotificationDeck.cardWidth, alignment: .leading)
            .background(cardSurface)
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
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
        case .input: return Theme.attention
        case .done:  return Theme.run
        }
    }
    private var glyphPath: String {
        switch notif.kind {
        case .error: return Phosphor.exclamation
        case .input: return Phosphor.question
        case .done:  return Phosphor.check
        }
    }

    // The escalated sidebar AttentionGlyph: same Phosphor path + state colour, breathing on
    // needs-input, in a 26px chip tinted 13% of the state colour.
    private var glyph: some View {
        Phos(path: glyphPath, size: 17)
            .foregroundStyle(glyphColor)
            .modifier(BreatheIf(on: notif.kind == .input))
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(glyphColor.opacity(0.13)))
    }

    private var who: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(chipColor).frame(width: 7, height: 7)
            Group {
                if let path = notif.iconPath {
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

    private var hint: some View {
        HStack(spacing: 5) {
            KeyCaps(keys: ["⌘", "↩"])
            // ⌘↩ on a system toast acknowledges it (nowhere to jump) — say so.
            Text(session == nil ? "dismiss" : "jump")
                .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
        }
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 13)
            .fill(Theme.glass)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).fill(Theme.rowHover).opacity(hovering ? 1 : 0))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.borderStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
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
