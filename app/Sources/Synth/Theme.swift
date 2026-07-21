import SwiftUI
import AppKit

/// Colours and metrics lifted from working.html's CSS variables. Every colour is
/// appearance-adaptive: a dynamic NSColor resolves to the light or dark value against
/// the view's effective appearance (driven by `.preferredColorScheme`, see RootView).
/// Call sites are unchanged — the whole app themes by editing this one file, exactly
/// like working.html's `:root` / `:root[data-theme="dark"]`.
enum Theme {
    // Surfaces + structure. The ramp is the app icon's own squircle gradient, read in the same
    // direction: `raised` is its top stop (#282B30), `sidebar` its middle, `canvas` one step past
    // its bottom. The charcoal is not neutral — it holds hue ~223° at ~10% saturation.
    static let canvas      = dyn(0xE9EAEE, 0x0D0F13)   // grey backdrop / near-black desktop
    static let panel       = dyn(0xFAFBFC, 0x191B1F)   // content surface
    static let sidebar     = dyn(0xF0F1F4, 0x1D1F24)   // sidebar surface
    static let raised      = dyn(0xFFFFFF, 0x282B30)   // raised fills: menus, pills, fields
    static let border      = mono(0.07, 0.09)          // hairline (black→white overlay)
    static let borderStrong = mono(0.10, 0.13)
    static let rowHover    = mono(0.035, 0.05)
    static let rowSelected = mono(0.05, 0.08)
    static let line        = mono(0.10, 0.12)           // control border
    static let selRing     = accent.opacity(0.5)

    // Text tiers
    static let ink          = dyn(0x1C1E23, 0xE6E8ED)   // tier-1 text (unified with repoName primary)
    static let inkMuted     = dyn(0x7E808A, 0x8D9099)
    static let inkFaint     = dyn(0xA6A8B0, 0x666A72)

    // Secondary ink tiers (used inline across menus, palette, settings, shortcuts)
    static let ink2         = dyn(0x44464E, 0xC4C7CF)   // crumbs, shortcut labels, kebab-hover glyph
    static let ink3         = dyn(0x54565E, 0xADB0B9)   // settings scope name
    static let ink4         = dyn(0x666971, 0x979AA3)   // menu confirm label, palette icon
    static let ink5         = dyn(0x787B84, 0x83868F)   // branch / mono label
    static let inkOpen      = dyn(0x2B2D34, 0xDCDEE4)   // open session name
    /// One tier for every faint meta grey. The eight it replaced sat within 5% lightness of each
    /// other — a hierarchy nobody could see — and several failed contrast; this clears 4.63:1.
    static let inkMeta      = dyn(0x6B6E76, 0x8D9099)
    static let menuIcon     = dyn(0x7A7A80, 0x979AA3)   // popover item icons
    static let termBg       = dyn(0x191B1F, 0x121317)   // code editor surface (Settings)
    static let chrome       = dyn(0xF2F3F6, 0x22252B)   // browser toolbar (--chrome)
    static let tuiBg        = dyn(0xF3EFE7, 0x121317)   // terminal card: light "paper" / dark card
    static let tuiHair      = mono(0.13, 0.06)          // terminal card inset hairline
    static let paletteActive = accent                   // ⌘K active-row label
    /// Frosted popover fill layered over `.ultraThinMaterial` (⌘K / menus).
    static let glass = Color(nsColor: NSColor(name: nil) {
        $0.isDarkAqua ? NSColor(hex: 0x1F2228).withAlphaComponent(0.86)
                      : NSColor(hex: 0xFAFBFD).withAlphaComponent(0.84)
    })

    // Exact per-element greys from working.html
    static let repoName     = dyn(0x1C1E23, 0xE6E8ED)
    static let repoCount    = inkMeta
    static let navLabel     = inkMeta
    static let chevron      = inkMeta
    static let branchName   = ink3                      // inactive branch (parent tier above sessions)
    static let branchMeta   = inkMeta
    static let sessionName  = inkMeta
    static let sessionNameUnread = dyn(0x34363D, 0xECEEF2)
    static let sessionIcon  = inkMeta                   // non-AI

    // State + accent.
    /// The brand accent: the icon's champagne mark in dark. Light can't use it — at 87% lightness
    /// it fails contrast on white — so light takes a copper of the same warm family (4.78:1).
    /// Spent only on focus, selection, the ⌘K active row and the open-session tint.
    static let accent      = dyn(0xA86038, 0xEEE0CD)
    /// The mark's own pair — charcoal on light, champagne on dark (--focus): the active pane's bar.
    static let focus       = dyn(0x1E2126, 0xEEE0CD)
    static let run         = Color(hex: 0x34C759)   // green liveness
    static let working     = Color(hex: 0xF5A623)   // amber (working) — 4° off champagne, so it
                                                    // stays put and the accent keeps clear of it
    /// Liveness (running / working), working.html `--live`. Tuned per theme: the dark theme's
    /// bright cyan washes out on a light sidebar, so light drops to a deeper one.
    static let live        = dyn(0x0891B2, 0x22D3EE)
    /// Needs-input state only: a desaturated sibling of the charcoal's own 223° hue. Never brand.
    static let input       = dyn(0x3A6DB3, 0x7EA6DC)
    static let danger      = Color(hex: 0xFF3B30)   // error (!)
    static let copper      = dyn(0xA05633, 0xC2724C)   // the AI mark (session__icon--ai, ind--owned)

    /// PR states — GitHub's own hues, tuned per theme (working.html `--pr-*`). Identity, not
    /// brand: they only ever colour a branch's pull-request glyph and header chip.
    static let prOpen      = dyn(0x1A7F37, 0x57AB5A)
    static let prMerged    = dyn(0x8250DF, 0xB083F0)
    static let prClosed    = dyn(0xCF222E, 0xE5534B)
    static let prQueued    = dyn(0x0969DA, 0x4493F8)   // in the merge queue — waiting, not yet merged

    /// Identity, not brand: six hues at 34% saturation, each ≥15° from every reserved colour and
    /// ≥27° from each other, all clearing 4.6:1 for their white letter.
    static let chipColors: [Color] = [
        Color(hex: 0x7569B5), Color(hex: 0x477B90), Color(hex: 0x7B773D),
        Color(hex: 0x3E7E74), Color(hex: 0xAD587F), Color(hex: 0xA158AD),
    ]

    static let sidebarWidth: CGFloat = 260
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 460
    /// The titlebar band — working.html's `--titlebar-h`. The sidebar's top strip and every
    /// pane header are exactly this tall, so the traffic lights, the sidebar toggle, the pane
    /// title and the DEV tag all share one centre line across the sidebar/content seam.
    static let titlebarHeight: CGFloat = 50
    /// Traffic lights (working.html `.traffic`): 12pt circles, 20pt from the leading edge,
    /// 20pt pitch, centred in the band. WindowChrome puts AppKit's real buttons here.
    static let trafficLightInset: CGFloat = 20
    static let trafficLightPitch: CGFloat = 20
    /// Where a collapsed pane header starts: the lights end at 72pt, then the mock's 10pt gap.
    static let trafficLightsClearance: CGFloat = 82
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

extension PRState {
    /// The state's colour (working.html `.pr--open/merged/closed`).
    var tint: Color {
        switch self {
        case .open: return Theme.prOpen
        case .merged: return Theme.prMerged
        case .closed: return Theme.prClosed
        case .queued: return Theme.prQueued
        }
    }
    /// A merged PR wears the merge glyph; open, closed and queued all wear pull-request (the
    /// colour tells them apart), matching working.html.
    var glyph: String { self == .merged ? Phosphor.gitMerge : Phosphor.gitPullRequest }
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
        case .agent: return Theme.copper
        case .terminal, .browser: return Theme.sessionIcon
        }
    }
}
