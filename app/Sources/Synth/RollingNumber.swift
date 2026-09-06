import SwiftUI

/// A number whose digits roll to their new face instead of being swapped out (working.html
/// `.roll`, after kitlangton/rolling-number).
///
/// Each digit is its own reel of 0–9 clipped to one line box and translated to the face it is
/// showing, so a change is one offset and a change that lands mid-flight retargets from wherever
/// the reel had got to rather than restarting. Everything that isn't a digit — a `%`, a `$`, the
/// separators in "4d 6h" — is drawn once and never moves, so the number keeps its place while its
/// digits turn.
///
/// `face` is the reel's stride and the height of the visible window: one em, the same as the CSS
/// `line-height: 1`. Passing it in rather than measuring is what lets one implementation serve
/// both the 30pt headline and the 11pt line under the meter.
struct RollingNumber: View {
    let text: String
    let font: Font
    let face: CGFloat
    var tracking: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                if let digit = digit(character) {
                    DigitReel(digit: digit, font: font, face: face, tracking: tracking,
                              delay: Double(index) * 0.026)
                } else {
                    Text(String(character)).font(font).tracking(tracking).frame(height: face)
                }
            }
        }
        // Same shape (same digits in the same places) → the reels line up with the glyphs and roll.
        // A different shape means a digit was gained or a separator moved, so the reels no longer
        // mean what they did: redraw rather than animate one number's digits into another's.
        .id(shape)
    }

    private func digit(_ character: Character) -> Int? {
        guard character.isASCII, let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
        return value
    }

    private var shape: String {
        String(text.map { digit($0) == nil ? $0 : "#" })
    }
}

private struct DigitReel: View {
    let digit: Int
    let font: Font
    let face: CGFloat
    let tracking: CGFloat
    /// The left-to-right sweep: a multi-digit change arrives as one gesture rather than all at once.
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<10, id: \.self) { value in
                Text(String(value)).font(font).tracking(tracking).frame(height: face)
            }
        }
        .offset(y: -CGFloat(digit) * face)
        .frame(height: face, alignment: .top)
        .clipped()
        .animation(reduceMotion ? nil
                                : .timingCurve(0.34, 1.28, 0.52, 1, duration: 0.56).delay(delay),
                   value: digit)
    }
}
