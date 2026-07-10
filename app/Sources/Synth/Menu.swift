import SwiftUI

/// One creation action offered by a row's menu (a branch offers two: terminal + Claude Code).
struct MenuCreate: Identifiable {
    let id = UUID()
    let icon: String
    /// An agent create row shows that agent's own mark instead of the Phosphor glyph.
    var kind: SessionKind? = nil
    let title: String
    let run: () -> Void
}

/// A request to show the row-action menu, carrying the target's actions.
struct ActiveMenu {
    let rowID: UUID
    let level: RowMenu.Level
    let creates: [MenuCreate]
    let onDelete: () -> Void
    /// Overrides the level's stock confirm copy — the cascade-naming session close
    /// ("…also closes its N browsers", ADR-0011 stage four).
    var confirmText: String? = nil
    /// Session close only: true while the session is busy (ADR-0013).
    var isDestructive: Bool = false
    /// Session close only: skip the confirm step — idle, no owned browsers (ADR-0013).
    var skipsConfirm: Bool = false
}

/// Each kebab publishes its bounds; the root reads the active row's to place the menu.
struct MenuAnchorKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The floating menu card — rendered at the root so it escapes the sidebar clip
/// (like the mock's `position: fixed`), scaling out of the kebab's top-right corner.
struct MenuOverlay: View {
    @Environment(AppStore.self) private var store
    let menu: ActiveMenu
    let kebabRect: CGRect
    let container: CGSize
    let onClose: () -> Void

    @State private var shown = false
    private let width: CGFloat = 178

    private var origin: CGPoint {
        let x = max(8, kebabRect.maxX - width)
        let y = kebabRect.maxY + 6
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        @Bindable var store = store
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            RowMenu(level: menu.level, creates: menu.creates, onDelete: menu.onDelete,
                    confirmText: menu.confirmText,
                    isDestructive: menu.isDestructive, skipsConfirm: menu.skipsConfirm,
                    isPresented: Binding(get: { true }, set: { if !$0 { onClose() } }),
                    confirming: $store.menuConfirming)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.18), radius: 32, y: 12)
                .scaleEffect(shown ? 1 : 0.95, anchor: .topTrailing)
                .opacity(shown ? 1 : 0)
                .offset(x: origin.x, y: origin.y)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.15)) { shown = true } }
    }
}
