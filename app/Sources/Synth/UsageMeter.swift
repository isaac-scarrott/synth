import SwiftUI

/// The level ladder under a tile's number (working.html `.usage-meter`): segments descending left
/// to right, lit as far as the quota spent.
///
/// A filling bar says "progress"; a level running down a fader says "headroom left", which is the
/// actual question being asked here. State colour lives only in here — the value above stays
/// `Theme.ink` at every percentage, so a board of agents reads as one surface rather than a
/// traffic-light panel.
struct UsageMeter: View {
    /// 0–100, used.
    let percent: Double
    /// The tile's place in the pane's entrance sweep — the segments grow after their own tile has.
    let tileIndex: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flipped once the meter is on screen, so the growth animates on a view that already exists.
    /// Reading a flag the pane had already set would insert the segments fully grown.
    @State private var grown = false

    private static let segments = 24
    private static let height: CGFloat = 32
    /// What a segment measures in a half-width tile, which is where the ladder was drawn: the
    /// 760pt board, less the 10pt column gap, halved, less 32pt of tile padding and the 23 gaps
    /// between segments, over 24 of them. Capping it keeps the meter the same object in a tile
    /// that spans the whole row — left to widen freely a segment there reaches 27pt and the ladder
    /// reads as a row of lozenges instead.
    private static let segmentWidth: CGFloat = {
        let column: CGFloat = (760 - 10) / 2      // board width, less the column gap, halved
        let content: CGFloat = column - 32        // less the tile's own padding
        return (content - CGFloat(segments - 1) * 3) / CGFloat(segments)
    }()

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<Self.segments, id: \.self) { segment in
                Capsule()
                    .fill(segment < lit ? litColour : Theme.mono(0.05, 0.07))
                    .frame(maxWidth: Self.segmentWidth)
                    .frame(height: Self.segmentHeight(segment))
                    .scaleEffect(y: grown || reduceMotion ? 1 : 0.06, anchor: .bottom)
                    .opacity(grown || reduceMotion ? 1 : 0)
                    .animation(reduceMotion ? nil
                                            : .timingCurve(0.23, 1, 0.32, 1, duration: 0.32)
                                                .delay(Double(tileIndex) * 0.045 + Double(segment) * 0.012 + 0.09),
                               value: grown)
            }
        }
        .onAppear { grown = true }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height, alignment: .bottom)
    }

    private var lit: Int { Int((percent / 100 * Double(Self.segments)).rounded()) }

    private var litColour: Color {
        percent >= 95 ? Theme.danger : percent >= 80 ? Theme.working : Theme.accent
    }

    /// A linear ramp from full height at the left to 30% of it at the right.
    private static func segmentHeight(_ segment: Int) -> CGFloat {
        let ramp = 100 - (Double(segment) / Double(segments - 1)) * 70
        return CGFloat(ramp) / 100 * height
    }
}
