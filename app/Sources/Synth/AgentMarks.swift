import SwiftUI

/// Which mark an agent renders in an icon slot. An agent Synth doesn't have artwork for falls
/// back to the sparkle, so a third agent needs no code here to look reasonable.
enum AgentMark: Sendable {
    case clawd
    case openCode
    case sparkle
}

/// Claude Code's mascot, Clawd — reproduced pixel-exactly from the sprite `claude` itself draws
/// on startup (quadrant-block glyphs `▐▛███▜▌ / ▝▜█████▛▘ / ▘▘ ▝▝`, decoded to a 16×5 grid).
/// Anthropic publishes no vector of him, so the running binary is the authoritative source.
///
/// Those grid cells are NOT square. A quadrant block is half a terminal cell each way, and a
/// monospace cell is about 1:2 (width:height) — so each cell of the sprite renders twice as tall
/// as it is wide, and Clawd is 16×10 (1.6:1), not 16×5. Drawing the cells square squashes him.
///
/// Monochrome and tinted, so he inherits Synth's "an AI works here" accent and adapts to both
/// appearances. Wider than tall, so he fits the slot's width and centres on its height.
struct ClawdMark: View {
    var size: CGFloat = 16
    var color: Color = Theme.agent

    /// Row-merged runs of the sprite: (x, y, width) in grid cells. Ten rects, not 54 cells.
    private static let runs: [(x: Int, y: Int, w: Int)] = [
        (2, 0, 12),
        (2, 1, 2), (5, 1, 6), (12, 1, 2),   // the gaps are his eyes
        (0, 2, 16),                          // claws, spanning the full width
        (2, 3, 12),
        (3, 4, 1), (5, 4, 1), (10, 4, 1), (12, 4, 1),   // legs
    ]
    private static let cells = (w: CGFloat(16), h: CGFloat(5))
    /// A sprite cell is twice as tall as it is wide (see above).
    private static let cellAspect: CGFloat = 2

    var body: some View {
        Canvas { ctx, canvas in
            // Fit to width; even at true proportions he is wider than tall.
            let unit = canvas.width / Self.cells.w
            let cellH = unit * Self.cellAspect
            let originY = (canvas.height - Self.cells.h * cellH) / 2
            var path = Path()
            for run in Self.runs {
                path.addRect(CGRect(x: CGFloat(run.x) * unit,
                                    y: originY + CGFloat(run.y) * cellH,
                                    width: CGFloat(run.w) * unit,
                                    height: cellH))
            }
            ctx.fill(path, with: .color(color))
        }
        .frame(width: size, height: size)
        // A pixel sprite must not be smoothed into mush at small sizes.
        .drawingGroup()
    }
}

/// OpenCode's official square mark: the block "o" — an outer ring with a two-tone inner block,
/// its upper half left open so the row's background shows through. Geometry is the brand's own
/// (opencode.ai/favicon.svg, viewBox 512, ring 128…384 × 96…416, hole 192…320 × 160…352), and
/// the colours are the brand's light/dark pairs rather than Synth's agent accent — the glyph
/// says "agent", not the colour.
struct OpenCodeMark: View {
    var size: CGFloat = 16
    /// Set to force the mark monochrome (a destructive palette row tints its icon red).
    var monochrome: Color?

    private static let box: CGFloat = 512
    private static let outer = CGRect(x: 128, y: 96, width: 256, height: 320)
    private static let hole = CGRect(x: 192, y: 160, width: 128, height: 192)
    private static let inner = CGRect(x: 192, y: 224, width: 128, height: 128)

    private var ringColor: Color { monochrome ?? Theme.dyn(0x211E1E, 0xF1ECEC) }
    private var innerColor: Color { monochrome ?? Theme.dyn(0xCFCECD, 0x4B4646) }

    var body: some View {
        Canvas { ctx, canvas in
            // The mark is 256×320 — taller than wide. Fit its height, centre its width.
            let unit = canvas.height / Self.box
            let inset = (canvas.width - Self.box * unit) / 2
            func rect(_ r: CGRect) -> CGRect {
                CGRect(x: inset + r.minX * unit, y: r.minY * unit,
                       width: r.width * unit, height: r.height * unit)
            }
            var ring = Path()
            ring.addRect(rect(Self.outer))
            ring.addRect(rect(Self.hole))
            ctx.fill(ring, with: .color(ringColor), style: FillStyle(eoFill: true))

            var block = Path()
            block.addRect(rect(Self.inner))
            ctx.fill(block, with: .color(innerColor))
        }
        .frame(width: size, height: size)
        .drawingGroup()
    }
}

/// The one place a session's icon is chosen. Agents render their own mark; terminals and browsers
/// keep their Phosphor glyph. `tint` overrides everything — a destructive row paints its icon red.
struct SessionIcon: View {
    let kind: SessionKind
    var size: CGFloat = 16
    /// nil = each mark's natural colour (agent accent, or OpenCode's brand greys).
    var tint: Color?

    var body: some View {
        switch kind.agentID.flatMap({ AgentRegistry.descriptor($0)?.mark }) {
        case .clawd:
            ClawdMark(size: size, color: tint ?? Theme.agent)
        case .openCode:
            OpenCodeMark(size: size, monochrome: tint)
        case .sparkle:
            Phos(path: Phosphor.sparkle, size: size).foregroundStyle(tint ?? Theme.agent)
        case nil:
            // Not an agent (or an agent with no descriptor): the kind's own glyph.
            Phos(path: kind.iconPath, size: size).foregroundStyle(tint ?? kind.tint)
        }
    }
}
