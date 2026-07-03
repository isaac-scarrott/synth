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

    static let ink          = Color(hex: 0x1A1A1C)   // tier-1 text
    static let inkMuted     = Color(hex: 0x86868B)
    static let inkFaint     = Color(hex: 0xA8A8AD)

    // Exact per-element greys from working.html
    static let repoName     = Color(hex: 0x1D1D1F)
    static let repoCount    = Color(hex: 0xB8B8BD)
    static let navLabel     = Color(hex: 0xA1A1A6)
    static let chevron      = Color(hex: 0xB8B8BD)
    static let branchName   = Color(hex: 0x737378)   // inactive branch
    static let branchMeta   = Color(hex: 0xBCBCC1)
    static let sessionName  = Color(hex: 0x8A8A8F)
    static let sessionNameUnread = Color(hex: 0x35353A)
    static let sessionIcon  = Color(hex: 0xA1A1A6)   // non-AI

    static let run         = Color(hex: 0x34C759)   // green liveness
    static let idle        = Color(hex: 0xCBCBD0)
    static let working     = Color(hex: 0xF5A623)   // amber (working)
    static let attention   = Color(hex: 0x0A84FF)   // needs-input (?) / unread bullet
    static let danger      = Color(hex: 0xFF3B30)   // error (!)
    static let claude      = Color(hex: 0xC2724C)   // terracotta accent (session__icon--ai)

    static let chipColors: [Color] = [
        Color(hex: 0x6366F1), Color(hex: 0x0EA5E9), Color(hex: 0xF59E0B),
        Color(hex: 0x10B981), Color(hex: 0xEC4899), Color(hex: 0x8B5CF6),
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
    var iconPath: String {
        switch self {
        case .terminal:   return Phosphor.terminal
        case .claudeCode: return Phosphor.sparkle
        }
    }
    var tint: Color {
        switch self {
        case .claudeCode: return Theme.claude
        case .terminal:   return Theme.sessionIcon
        }
    }
}
