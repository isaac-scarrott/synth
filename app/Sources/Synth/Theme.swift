import SwiftUI
import AppKit

/// Colours and metrics lifted from working.html's CSS variables. Every colour is
/// appearance-adaptive: a dynamic NSColor resolves to the light or dark value against
/// the view's effective appearance (driven by `.preferredColorScheme`, see RootView).
/// Call sites are unchanged — the whole app themes by editing this one file, exactly
/// like working.html's `:root` / `:root[data-theme="dark"]`.
enum Theme {
    // Surfaces + structure
    static let canvas      = dyn(0xEBEBED, 0x0D0D0F)   // grey backdrop / near-black desktop
    static let panel       = dyn(0xFFFFFF, 0x1B1B1D)   // content surface
    static let sidebar     = dyn(0xF4F4F5, 0x202023)   // sidebar surface
    static let raised      = dyn(0xFFFFFF, 0x29292C)   // raised fills: menus, pills, fields
    static let border      = mono(0.07, 0.09)          // hairline (black→white overlay)
    static let borderStrong = mono(0.10, 0.13)
    static let rowHover    = mono(0.035, 0.05)
    static let rowSelected = mono(0.05, 0.08)
    static let line        = mono(0.10, 0.12)           // control border
    static let selRing     = Color(hex: 0x0A84FF).opacity(0.5)

    // Text tiers
    static let ink          = dyn(0x1A1A1C, 0xF3F3F5)   // tier-1 text
    static let inkMuted     = dyn(0x86868B, 0x9A9AA1)
    static let inkFaint     = dyn(0xA8A8AD, 0x6D6D74)

    // Secondary ink tiers (used inline across menus, palette, settings, shortcuts)
    static let ink2         = dyn(0x46464C, 0xCDCDD3)   // crumbs, shortcut labels, kebab-hover glyph
    static let ink3         = dyn(0x58585D, 0xB7B7BD)   // settings scope name
    static let ink4         = dyn(0x6A6A70, 0xA1A1A8)   // menu confirm label, palette icon
    static let inkOpen      = dyn(0x2C2C30, 0xEAEAEE)   // open session name
    static let menuIcon     = dyn(0x7A7A80, 0xA1A1A8)   // popover item icons
    static let termBg       = dyn(0x1B1B1E, 0x131315)   // code editor surface (Settings)
    static let chrome       = dyn(0xF6F6F7, 0x242427)   // browser toolbar (--chrome)
    static let tuiBg        = dyn(0xF4F2EC, 0x131315)   // terminal card: light "paper" / dark card
    static let tuiHair      = mono(0.13, 0.06)          // terminal card inset hairline
    static let paletteActive = dyn(0x0A5FD6, 0x6BA9FF)  // ⌘K active-row label
    /// Frosted popover fill layered over `.ultraThinMaterial` (⌘K / menus).
    static let glass = Color(nsColor: NSColor(name: nil) {
        $0.isDarkAqua ? NSColor(hex: 0x1E1E22).withAlphaComponent(0.86)
                      : NSColor.white.withAlphaComponent(0.86)
    })

    // Exact per-element greys from working.html
    static let repoName     = dyn(0x1D1D1F, 0xF2F2F4)
    static let repoCount    = dyn(0xB8B8BD, 0x7E7E85)
    static let navLabel     = dyn(0xA1A1A6, 0x8B8B92)
    static let chevron      = dyn(0xB8B8BD, 0x6E6E75)
    static let branchName   = dyn(0x737378, 0x909097)   // inactive branch
    static let branchMeta   = dyn(0xBCBCC1, 0x76767D)
    static let sessionName  = dyn(0x8A8A8F, 0x8F8F96)
    static let sessionNameUnread = dyn(0x35353A, 0xE8E8EC)
    static let sessionIcon  = dyn(0xA1A1A6, 0x88888F)   // non-AI

    // State + accent — vivid tokens read on both themes.
    static let run         = Color(hex: 0x34C759)   // green liveness
    static let working     = Color(hex: 0xF5A623)   // amber (working)
    static let attention   = Color(hex: 0x0A84FF)   // needs-input (?) / unread bullet
    static let danger      = Color(hex: 0xFF3B30)   // error (!)
    static let agent       = Color(hex: 0xC2724C)   // terracotta accent (session__icon--ai)

    static let chipColors: [Color] = [
        Color(hex: 0x6366F1), Color(hex: 0x0EA5E9), Color(hex: 0xF59E0B),
        Color(hex: 0x10B981), Color(hex: 0xEC4899), Color(hex: 0x8B5CF6),
    ]

    static let sidebarWidth: CGFloat = 260
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 460
    static let titlebarInset: CGFloat = 28   // room for the traffic lights
    static let radiusApp: CGFloat = 14
    static let radiusPanel: CGFloat = 20
    static let cardInset: CGFloat = 12

    /// A colour that resolves light/dark against the effective appearance.
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDarkAqua ? NSColor(hex: dark) : NSColor(hex: light) })
    }
    /// A black overlay in light, inverted to a white overlay in dark (hovers, borders, dividers).
    static func mono(_ lightAlpha: Double, _ darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.isDarkAqua ? NSColor(white: 1, alpha: darkAlpha) : NSColor(white: 0, alpha: lightAlpha)
        })
    }
}

extension NSAppearance {
    var isDarkAqua: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
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

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green:   Double((hex >> 8) & 0xFF) / 255,
            blue:    Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension SessionKind {
    /// The monochrome glyph a kind falls back to. Agents normally render their own mark
    /// (`SessionIcon` / AgentMarks.swift); the sparkle stands in for one Synth has no artwork
    /// for, so a third agent looks reasonable before anyone draws it.
    var iconPath: String {
        switch self {
        case .terminal: return Phosphor.terminal
        case .agent:    return Phosphor.sparkle
        case .browser:  return Phosphor.globe
        }
    }
    var tint: Color {
        switch self {
        case .agent: return Theme.agent
        case .terminal, .browser: return Theme.sessionIcon
        }
    }
}
