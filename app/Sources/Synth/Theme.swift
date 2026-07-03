import SwiftUI

/// Colours and metrics lifted from the HTML design (big-picture-design.html).
enum Theme {
    static let canvas      = Color(hex: 0xEBEBED)   // grey backdrop
    static let panel       = Color(hex: 0xFDFDFD)   // off-white sidebar/content
    static let rowHover    = Color.black.opacity(0.035)
    static let rowSelected = Color.black.opacity(0.05)
    static let selRing     = Color(hex: 0x0A84FF).opacity(0.5)

    static let ink         = Color(hex: 0x1D1D1F)   // tier-1 text
    static let inkMuted    = Color(hex: 0x737378)   // tier-2 (branch) text
    static let inkFaint    = Color(hex: 0xB8B8BD)   // tier-3 / meta

    static let run         = Color(hex: 0x34C759)   // green liveness
    static let idle        = Color(hex: 0xC7C7CC)
    static let attention   = Color(hex: 0x0A84FF)   // needs-input (?)
    static let danger      = Color(hex: 0xFF3B30)   // error (!)
    static let claude      = Color(hex: 0xC96442)   // terracotta accent

    static let chipColors: [Color] = [
        Color(hex: 0x6E62E5), Color(hex: 0x2A9D8F), Color(hex: 0xE0A93B),
        Color(hex: 0xD1495B), Color(hex: 0x3A86FF), Color(hex: 0x8338EC),
    ]

    static let sidebarWidth: CGFloat = 260
    static let titlebarInset: CGFloat = 28   // room for the traffic lights
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
        case .terminal:   return "apple.terminal"
        case .claudeCode: return "sparkle"
        case .browser:    return "globe"
        case .simulator:  return "iphone"
        }
    }
    var tint: Color {
        switch self {
        case .claudeCode: return Theme.claude
        default:          return Theme.inkMuted
        }
    }
}
