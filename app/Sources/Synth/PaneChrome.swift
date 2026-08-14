import AppKit
import SwiftUI

// working.html `----- Driven surfaces`: the chrome Synth wraps around something it drives.
// One vocabulary, two speakers — the embedded browser and the simulator — so a surface is a
// framed card with a toolbar: hardware/navigation buttons on the left, one identity field that
// names what is loaded and reopens the "open…" surface, a mono badge for the number that changes
// as you drive, then the tools. Anything a second surface would want lives here under `pane*`;
// what genuinely belongs to one keeps its own name and stays in that pane's file.

extension View {
    /// `.pane-bar`: the chrome-grey toolbar strip, with the hairline that parts it from the view.
    func paneBar() -> some View {
        self
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(Theme.chrome)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 0.5)
            }
    }
}

/// `.pane-btn`: 26×26, radius 7, muted glyph; hover fills + darkens, press dips to 0.9,
/// disabled fades to 0.32, `is-on` keeps the hover look (the DevTools on-state).
struct PaneBarButton: View {
    let icon: String
    let help: String
    var disabled = false
    var on = false
    var rotation: Double = 0
    let action: () -> Void
    @State private var hovering = false

    private var lit: Bool { (hovering && !disabled) || on }

    var body: some View {
        Button(action: action) {
            Phos(path: icon, size: 16)
                .foregroundStyle(lit ? Theme.ink : Theme.inkMuted)
                .rotationEffect(.degrees(rotation))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(lit ? Theme.rowHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PaneBarPressStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.32 : 1)
        .help(help)
        .onHover { hovering = $0 && !disabled }
    }
}

/// `.pane-btn:active`: scale(0.9).
struct PaneBarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

/// `.pane-badge`: the one number that moves while you drive — the browser's zoom, the simulator's
/// viewport — as a compact mono pill beside the identity field. With an `action` it is the
/// browser's clickable reset and takes the hover treatment; without one it is a readout, and a
/// hover look on a thing that does nothing is a lie about what a click would do.
struct PaneBadge: View {
    let text: String
    var help: String?
    var action: (() -> Void)?
    @State private var hovering = false

    private var lit: Bool { hovering && action != nil }

    private var label: some View {
        // verbatim: a readout — a percentage, a pixel count — not a quantity to group by locale.
        Text(verbatim: text)
            .font(.mono(11))
            .lineLimit(1)
            .fixedSize()                     // a readout that wraps is a readout clipped mid-line
            .foregroundStyle(lit ? Theme.ink : Theme.inkMuted)
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 7).fill(lit ? Theme.rowHover : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(lit ? Theme.borderStrong : Theme.border, lineWidth: 0.5))
    }

    var body: some View {
        if let action {
            Button(action: action) {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .helpIfPresent(help)
        } else {
            label.helpIfPresent(help)
        }
    }
}

private extension View {
    @ViewBuilder
    func helpIfPresent(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

/// `.pane-field`: search glyph + mono input on a raised panel card, with the blue focus ring.
/// Shared by the browser's home surface and both surfaces' drops.
struct GoToField: View {
    let placeholder: String
    var seed: String?
    var focusNonce: Int = 0
    let onSubmit: (String) -> Void
    var onCancel: (() -> Void)?

    @State private var text: String
    @FocusState private var focused: Bool

    init(placeholder: String, seed: String? = nil, focusNonce: Int = 0,
         onSubmit: @escaping (String) -> Void, onCancel: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self.seed = seed
        self.focusNonce = focusNonce
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _text = State(initialValue: seed ?? "")
    }

    var body: some View {
        HStack(spacing: 9) {
            Phos(path: Phosphor.search, size: 16).foregroundStyle(Theme.inkFaint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.mono(13))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .focused($focused)
                .onSubmit { onSubmit(text) }
                .onExitCommand { onCancel?() }
        }
        .padding(.vertical, 11).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(focused ? Theme.accent : Theme.borderStrong, lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .inset(by: -2)
                .stroke(Theme.accent.opacity(0.16), lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        .onAppear {
            focused = true
            // Seeded (a drop): what is loaded now, pre-selected so a keystroke replaces it —
            // working.html's input.select().
            if seed != nil {
                DispatchQueue.main.async {
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                }
            }
        }
        .onChange(of: focusNonce) { _, _ in focused = true }
    }
}

/// `.pane-rec__label`: the uppercase header over a list of things this surface can open.
struct PaneRecLabel: View {
    let text: String
    let topPadding: CGFloat

    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(.sans(11, 600)).kerning(0.44)
            .foregroundStyle(Theme.inkFaint)
            .padding(.top, topPadding).padding(.horizontal, 4).padding(.bottom, 7)
    }
}

/// `.pane-rec__item`: glyph · mono key · faint trailing name, hover-filled row. The key is the
/// thing the surface opens — a URL for the browser, a bundle id for the simulator.
struct PaneRecRow: View {
    let icon: String
    let key: String
    var name: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Phos(path: icon, size: 15).foregroundStyle(Theme.inkFaint)
                Text(key)
                    .font(.mono(12))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if !name.isEmpty {
                    Text(name)
                        .font(.sans(12))
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `.pane-drop`: the surface's "open…" panel, floated under the bar over whatever is loaded.
/// Both drops carry the same card, shadow and entrance; only their contents differ.
struct PaneDrop<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.borderStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.17), radius: 18, y: 14)
            .padding(.horizontal, 10).padding(.top, 1)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -6)
            .onAppear {
                if reduceMotion { shown = true }
                else { withAnimation(.easeOut(duration: 0.14)) { shown = true } }
            }
    }
}
