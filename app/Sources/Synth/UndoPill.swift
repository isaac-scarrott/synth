import SwiftUI

/// A soft-deleted row awaiting commit-or-undo. The timing mirrors `InAppNotif`'s done-toast
/// drain — `armedAt`/`remaining` sampled on the same clock the dismissal task sleeps on, so the
/// bar and the commit can never disagree; `armedAt == nil` freezes it (hover-paused).
struct PendingUndo: Identifiable {
    let id: UUID
    let label: String
    let restore: () -> Void
    let commit: () -> Void
    var life: TimeInterval
    var remaining: TimeInterval
    var armedAt: Date?

    func fraction(at now: Date) -> Double {
        let left = armedAt.map { remaining - now.timeIntervalSince($0) } ?? remaining
        return min(1, max(0, left / life))
    }
}

/// working.html `.fb-toast--undo` — the soft-delete safety net. A glass pill at the shell's
/// bottom-centre naming what just went ("Closed typecheck"), an Undo affordance (⌘↩), and a
/// draining bar that commits the removal when it empties. The whole pill is the undo button, and
/// it pauses its drain on hover so the pointer can reach it (working.html `:hover` pause).
struct UndoPill: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        let pending = store.pendingUndo
        Button { store.performUndo() } label: {
            HStack(spacing: 9) {
                Phos(path: Phosphor.reset, size: 15)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 16, height: 16)
                Text(pending?.label ?? "")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.inkOpen)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    Text("Undo").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkOpen)
                    KeyCaps(keys: ["⌘", "↩"])
                }
                .fixedSize()   // the action label never truncates; only the row name (below) may
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(
                    Capsule().fill(Theme.rowHover)
                        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                )
            }
            .padding(EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 8))
            .background(pillSurface)
            // The remaining life made visible — done only, so it commits exactly when it empties.
            .overlay(alignment: .bottom) { if let p = pending { UndoTimerBar(pending: p) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; store.setUndoDrainPaused($0) }
        .padding(.bottom, 22)
        // Entrance: the deck's ~200ms ease-out rise, no bounce.
        .scaleEffect(shown ? 1 : 0.975, anchor: .bottom)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 12)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
        }
    }

    private var pillSurface: some View {
        Capsule()
            .fill(Theme.glass)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().fill(Theme.rowHover).opacity(hovering ? 1 : 0))
            .overlay(Capsule().strokeBorder(Theme.borderStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
    }
}

/// The undo pill's countdown — the deck's `NotifTimerBar` grammar (2px `Theme.focus` bar draining
/// left on the store clock), inset to the capsule and frozen while `armedAt == nil` (hover-paused).
private struct UndoTimerBar: View {
    let pending: PendingUndo

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: pending.armedAt == nil)) { ctx in
            UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                .fill(Theme.focus)
                .frame(height: 2)
                .scaleEffect(x: pending.fraction(at: ctx.date), anchor: .leading)
                .opacity(0.85)
        }
        .padding(.horizontal, 14)
        .allowsHitTesting(false)
    }
}
