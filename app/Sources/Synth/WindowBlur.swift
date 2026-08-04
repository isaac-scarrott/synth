import AppKit

/// The blurred desktop behind the whole shell.
///
/// A window-server effect rather than a view: `CGSSetWindowBackgroundBlurRadius` blurs whatever sits
/// behind the window and adds **no tint of its own**. That is the whole reason it is here instead of
/// an `NSVisualEffectView`. Every AppKit material tints as well as blurs, and that tint multiplies
/// with `Theme.windowCoat` exactly the way a second coat would: behind the design file's alphas,
/// `.underWindowBackground` left roughly 4% of the wallpaper showing and dragged light mode's
/// near-white down to a flat grey. An untinted blur is what `backdrop-filter: blur()` does, which is
/// what working.html was tuned against — and what Ghostty does, which is where the look came from.
///
/// The call is private API, so the symbols are resolved once at runtime and translucency is treated
/// as a **progressive enhancement**: if they cannot be found, `isAvailable` is false, the window stays
/// opaque and `Theme.windowCoat` resolves to a solid colour. A macOS that drops the call makes Synth
/// look the way it did before any of this existed. That matters more than it sounds — the failure to
/// avoid is not "no blur", it is a translucent shell over a *sharp* desktop, which is unreadable.
enum WindowBlur {
    /// The design file approximates this with `blur(50px)`; the two scales are not the same units, and
    /// 60 is where a real desktop stopped reading as a recognisable photo behind the chrome. Radius is
    /// the dial to reach for before opacity — it costs no contrast, where the coat costs legibility.
    static let radius = 60

    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias SetBlurRadius = @convention(c) (UInt32, UInt32, Int32) -> Int32

    /// Resolved once. `dlopen(nil, …)` searches the images already loaded in this process, so this
    /// finds the symbols if CoreGraphics exports them and quietly fails if it does not.
    private static let resolved: (connection: UInt32, setBlur: SetBlurRadius)? = {
        guard let image = dlopen(nil, RTLD_LAZY),
              let connectionSymbol = dlsym(image, "CGSMainConnectionID"),
              let blurSymbol = dlsym(image, "CGSSetWindowBackgroundBlurRadius")
        else {
            NSLog("Synth: window-server blur unavailable — the window stays opaque")
            return nil
        }
        return (unsafeBitCast(connectionSymbol, to: MainConnectionID.self)(),
                unsafeBitCast(blurSymbol, to: SetBlurRadius.self))
    }()

    static var isAvailable: Bool { resolved != nil }

    /// Idempotent, and re-asserted whenever the window is adopted: the radius is per-window state in
    /// the window server, and a window that is recreated loses it.
    static func apply(to window: NSWindow) {
        guard let resolved, window.windowNumber > 0 else { return }
        _ = resolved.setBlur(resolved.connection, UInt32(window.windowNumber), Int32(radius))
    }
}
