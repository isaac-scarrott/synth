import SwiftUI

/// The Usage board: one band per hosted agent, one tile per number it can report.
struct UsagePane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Text("Usage")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
