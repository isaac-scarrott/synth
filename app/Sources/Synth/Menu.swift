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
