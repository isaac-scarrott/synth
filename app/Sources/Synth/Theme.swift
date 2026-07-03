import SwiftUI

/// Colours and metrics lifted verbatim from working.html's CSS variables.
enum Theme {
    static let canvas      = Color(hex: 0xEBEBED)   // grey backdrop
    static let panel       = Color(hex: 0xFFFFFF)   // white content
    static let sidebar     = Color(hex: 0xF4F4F5)   // grey sidebar
    static let border      = Color.black.opacity(0.07)
    static let borderStrong = Color.black.opacity(0.10)
    static let rowHover    = Color.black.opacity(0.035)
    static let rowSelected = Color.black.opacity(0.05)
    static let selRing     = Color(hex: 0x0A84FF).opacity(0.5)

    static let ink         = Color(hex: 0x1A1A1C)   // tier-1 text
    static let inkMuted    = Color(hex: 0x86868B)   // tier-2 (branch) text
    static let inkFaint    = Color(hex: 0xA8A8AD)   // tier-3 / meta

    static let run         = Color(hex: 0x34C759)   // green liveness
    static let idle        = Color(hex: 0xC7C7CC)
    static let working     = Color(hex: 0xF5A623)   // amber (working)
    static let attention   = Color(hex: 0x0A84FF)   // needs-input (?)
    static let danger      = Color(hex: 0xFF3B30)   // error (!)
    static let claude      = Color(hex: 0xC96442)   // terracotta accent

    static let chipColors: [Color] = [
        Color(hex: 0x6E62E5), Color(hex: 0x2A9D8F), Color(hex: 0xE0A93B),
        Color(hex: 0xD1495B), Color(hex: 0x3A86FF), Color(hex: 0x8338EC),
    ]

    static let sidebarWidth: CGFloat = 260
    static let titlebarInset: CGFloat = 28   // room for the traffic lights
    static let radiusApp: CGFloat = 14
    static let radiusPanel: CGFloat = 20
    static let cardInset: CGFloat = 12
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension SessionKind {
    var symbol: String {
        switch self {
        case .terminal:   return "chevron.left.forwardslash.chevron.right"
        case .claudeCode: return "sparkle"
        }
    }
    var tint: Color {
        switch self {
        case .claudeCode: return Theme.claude
        case .terminal:   return Theme.inkMuted
        }
    }
}
