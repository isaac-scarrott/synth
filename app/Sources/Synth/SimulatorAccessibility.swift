import CoreGraphics
import Foundation
import ObjectiveC

// The accessibility tree of whatever the device is showing (ADR-0015): what is on screen, as
// structure rather than pixels. This is the observation rung an agent should reach for first,
// because a tree of a real screen is a few hundred bytes where its screenshot is a megabyte.
//
// There is no XCTest runner and no injected test bundle, for the same reason Indigo HID has
// neither: the device is read from outside, so this works on any app including ones we did not
// build. The mechanism is the one Simulator.app itself uses.
//
//   * `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]` is the XPC
//     channel to the guest's accessibility server. It carries opaque `AXPTranslatorRequest`s.
//   * `AXPTranslator` (AccessibilityPlatformTranslation.framework, which SimulatorKit links, so it
//     is loadable from any process) turns those into an `AXPMacPlatformElement` tree that answers
//     the ordinary NSAccessibility selectors.
//   * The translator only knows *which device* to send a request to through its
//     `bridgeTokenDelegate`. Inside Simulator.app that slot is filled by
//     `SimAccessibilityManager` per display view; out here it is nil, and every
//     `frontmostApplication…` call returns nil until we fill it ourselves.
//
// Three properties of that slot shape everything below:
//
//   * There is exactly ONE slot per process, so there is exactly one dispatcher
//     (`SimulatorAccessibilityBridge.shared`) and requests are told apart by a per-call token.
//     Two panes on two devices must not fight over it.
//   * The translator re-reads `bridgeDelegateToken` off every translation object it touches, so a
//     child element that was not stamped makes its own sub-request silently fail. The token is
//     stamped onto the root and pre-walked over the subtree before anything is read.
//   * `AXPMacPlatformElement` inherits most of its accessibility properties from AppKit's
//     `NSObject (NSAccessibility)` category, but not all of them: `accessibilityEnabled`,
//     `accessibilityHidden` and `accessibilityTraits` have no selector here, and `valueForKey:`
//     on an absent key raises. Every read is therefore guarded by `respondsToSelector:` — which
//     is also how a future OS moving a property shows up as a missing field instead of a crash.

// MARK: - Failures

/// Why a tree could not be read. Each case says which link in the chain broke, because "no
/// elements" and "the bridge never answered" look identical to a caller and mean opposite things.
enum SimulatorAccessibilityFailure: Error, CustomStringConvertible {
    case frameworkUnavailable(String)
    case translatorUnavailable(String)
    case delegateUnsupported(missing: [String])
    case selectorUnavailable(className: String, selector: String)
    case noFrontmostApplication(udid: String)
    case springBoardDead(udid: String, detail: String)
    case unavailable(String)
    /// No projection from the interface's space into the display's could be confirmed against the
    /// device, so there is no honest way to say where an element is.
    case unconfirmedProjection(interface: CGSize, display: CGSize, roundTrips: Int)

    var description: String {
        switch self {
        case let .frameworkUnavailable(detail):
            return "Could not load AccessibilityPlatformTranslation.framework: \(detail)"
        case let .translatorUnavailable(detail):
            return "AXPTranslator is unusable in this OS: \(detail)"
        case let .delegateUnsupported(missing):
            return "AXPTranslator's bridge-token delegate protocol now requires "
                + missing.joined(separator: ", ") + ", which Synth does not implement — the "
                + "accessibility bridge would return empty trees, so it was not installed."
        case let .selectorUnavailable(className, selector):
            return "\(className) does not respond to -\(selector) in this OS."
        case let .noFrontmostApplication(udid):
            return "Device \(udid) reported no frontmost application. Its accessibility server "
                + "answered, so something is on screen that it will not describe — launch an app "
                + "and try again."
        case let .springBoardDead(udid, detail):
            return "Device \(udid)'s accessibility server is not answering: \(detail)"
        case let .unconfirmedProjection(interface, display, roundTrips):
            return "The app's interface is \(Int(interface.width))×\(Int(interface.height))pt "
                + "against a \(Int(display.width))×\(Int(display.height))pt display, and none of "
                + "the ways it could be sitting on that display survived being checked against the "
                + "device (\(roundTrips) hit tests). Without that, an element's centre cannot be "
                + "turned into a coordinate simulator_tap takes. Use simulator_screenshot, or "
                + "rotate back to portrait. Refusing rather than answering, because the "
                + "coordinates would look valid and tap the wrong element."
        case let .unavailable(detail):
            return detail
        }
    }
}

// MARK: - Values

/// One element, already projected into the coordinates a caller acts in: `centre` is normalised
/// 0..1 from the top-left of the display, which is exactly what `simulator.tap` takes. Nothing
/// about the device's pixel density or the pane's scale reaches a caller.
struct SimulatorAccessibilityElement {
    var role: String
    var subrole: String?
    var label: String?
    var identifier: String?
    var value: String?
    var centre: CGPoint
    var isEnabled: Bool
    var isFocused: Bool

    /// Whether this element tells a caller anything. An unlabelled, unidentified, valueless
    /// container is pure structure: its children are listed on their own lines, so printing it
    /// only spends tokens.
    var carriesInformation: Bool {
        label?.isEmpty == false || identifier?.isEmpty == false || value?.isEmpty == false
    }

    /// `role[/subrole]|label|cx,cy` plus a tag per remaining fact. Positional for the three fields
    /// that are always present, tagged for the ones that usually are not — which is what keeps a
    /// line short without printing `null` three times.
    var line: String {
        var fields = [
            subrole.map { "\(role)/\($0)" } ?? role,
            Self.escape(label ?? ""),
            String(format: "%.3f,%.3f", centre.x, centre.y),
        ]
        if let identifier, !identifier.isEmpty { fields.append("#" + Self.escape(identifier)) }
        if let value, !value.isEmpty { fields.append("value=" + Self.escape(value)) }
        if !isEnabled { fields.append("disabled") }
        if isFocused { fields.append("focused") }
        return fields.joined(separator: "|")
    }

    /// Labels can be paragraphs — iOS concatenates a cell's whole content into one string. A line
    /// per element is only cheap if a line stays a line, so newlines and the delimiter are folded
    /// out and anything past `labelLimit` is elided.
    private static let labelLimit = 140

    /// Flattens one app-controlled string into one field of one line. The app under test chooses its
    /// accessibility labels, and this output is read by an agent as authoritative — so a label
    /// containing a line separator could forge extra rows, and one containing the field delimiter
    /// could forge extra fields. Replacing LF alone was not enough: CR, CRLF, NEL and the Unicode
    /// line/paragraph separators all start a new line in something that splits on newlines.
    static func escape(_ text: String) -> String {
        var flat = text
        for separator in ["\r\n", "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            flat = flat.replacingOccurrences(of: separator, with: " ")
        }
        flat = flat.replacingOccurrences(of: "|", with: "/")
        if flat.count > labelLimit {
            flat = String(flat.prefix(labelLimit - 1)) + "…"
        }
        return flat
    }
}

/// A whole answer: the app that was described, the geometry its coordinates are in, and the
/// elements worth printing. Rendered flat, one element per line — the format RocketSim and
/// sim-use both converged on, and the reason the tree is worth having at all.
struct SimulatorAccessibilityTree {
    /// The frontmost application's accessibility label, which is its display name.
    var application: String?
    /// The display's size in points, which the normalised centres are fractions of.
    var pointSize: CGSize
    /// Elements worth printing, outermost first.
    var elements: [SimulatorAccessibilityElement]
    /// How many elements the walk visited, including the ones filtered out. The gap between this
    /// and `elements.count` is how much pure structure the screen had.
    var visitedCount: Int
    /// Set when the walk stopped early, so a caller knows the list is not the whole screen.
    var truncation: String?
    /// Set when the interface's orientation could not be confirmed against the device and the
    /// centres below are the display's own space *assumed* rather than proved. A caller aiming taps
    /// at them is entitled to know which of the two it got.
    var geometryCaveat: String?

    /// The whole point of the format. One legend line, then one line per element.
    func render() -> String {
        // Not `Int(_:)` directly: the point size comes out of a private property whose type is not
        // ours to rely on, and `Int(nan)` is a trap rather than a wrong number.
        func points(_ value: CGFloat) -> Int { value.isFinite ? Int(value) : 0 }
        var lines = [
            // The app's own accessibility label, so it is escaped like any other field it controls —
            // a newline here would forge a row in output an agent reads as authoritative.
            "\(SimulatorAccessibilityElement.escape(application ?? "unknown app")) — "
            + "\(points(pointSize.width))×\(points(pointSize.height))pt, "
                + "\(elements.count) of \(visitedCount) elements",
            "role|label|cx,cy then #identifier value= disabled focused; cx,cy is the element's "
                + "centre, 0..1 from the top-left — tap it there",
        ]
        if let geometryCaveat { lines.append("! " + geometryCaveat) }
        lines += elements.map(\.line)
        if let truncation { lines.append("(\(truncation))") }
        return lines.joined(separator: "\n")
    }

    var byteCount: Int { render().utf8.count }

    /// The first element whose label contains `text`, case-insensitively. The check's way of
    /// asserting a tree is the tree of the app it launched.
    func firstElement(labelContaining text: String) -> SimulatorAccessibilityElement? {
        elements.first { $0.label?.range(of: text, options: .caseInsensitive) != nil }
    }
}

// MARK: - The two coordinate spaces

/// How the interface's coordinate space sits on the display's.
///
/// These are different spaces whenever the interface is rotated, and every verb here straddles them:
/// AXP reports element frames in the interface's space, while `tap` — and, measured on this Xcode,
/// `objectAtPoint:` — address the display, which never rotates. iOS draws its rotated interface
/// sideways into the same framebuffer, so the whole difference is a quarter turn over a transposed
/// extent.
///
/// `turn` is the orientation the interface is *laid out for*, and its own transform is the right one
/// to apply — the same `displayPoint(fromUpright:)` the pane uses to send a click to Indigo, because
/// the interface's space and the upright picture the user sees are one space. Verified against a
/// booted device: with the interface laid out for `landscapeRight`, `landscapeRight`'s transform
/// takes every element's centre to a display point where a hit test returns that same element, and
/// the other three do not.
struct SimulatorInterfaceProjection: Equatable {
    /// The interface's full extent in its own points — the display's point size, transposed when the
    /// interface is landscape.
    var interfaceSize: CGSize
    /// The quarter turn that carries a point in the interface onto the display.
    var turn: SimulatorOrientation

    /// An interface point, in the interface's own points, as a normalised display point — which is
    /// exactly what `tap` takes.
    func displayPoint(_ point: CGPoint) -> CGPoint {
        turn.displayPoint(fromUpright: CGPoint(
            x: point.x / interfaceSize.width, y: point.y / interfaceSize.height))
    }

    /// The other way round: a normalised display point back into the interface's own points. Used to
    /// ask which projections are even consistent with an answer the guest has already given.
    func interfacePoint(fromDisplay point: CGPoint) -> CGPoint {
        let upright = turn.uprightPoint(fromDisplay: point)
        return CGPoint(x: upright.x * interfaceSize.width, y: upright.y * interfaceSize.height)
    }

    /// Every projection a display of this size admits. All four, always: an app may refuse to rotate
    /// and an app may be laid out for a rotation nobody here asked for, so which one is real is a
    /// question for the device rather than for arithmetic.
    static func candidates(displayPointSize: CGSize) -> [SimulatorInterfaceProjection] {
        let transposed = CGSize(
            width: displayPointSize.height, height: displayPointSize.width)
        return SimulatorOrientation.allCases.map {
            SimulatorInterfaceProjection(
                interfaceSize: $0.isLandscape ? transposed : displayPointSize, turn: $0)
        }
    }
}

// MARK: - Runtime-only messaging surfaces

/// `+[AXPTranslator sharedInstance]`, messaged against the class object — the same trick
/// `SimServiceContext` uses, which keeps this a name lookup instead of a link-time class symbol.
@objc private protocol AXPTranslatorClassMessaging {
    @objc(sharedInstance) func sharedInstance() -> AnyObject?
}

@objc private protocol AXPTranslatorMessaging {
    @objc var bridgeTokenDelegate: AnyObject? { get set }

    @objc(frontmostApplicationWithDisplayId:bridgeDelegateToken:)
    func frontmostApplication(displayId: UInt32, bridgeDelegateToken: NSString) -> AnyObject?

    /// The three-argument hit test. The token is a *parameter*, so the dispatcher entry resolves
    /// on the very first sub-request — the token-less `objectAtPoint:` spelling needs the token
    /// stamped on a translation object it has not returned yet.
    @objc(objectAtPoint:displayId:bridgeDelegateToken:)
    func object(at point: CGPoint, displayId: UInt32, bridgeDelegateToken: NSString) -> AnyObject?

    @objc(macPlatformElementFromTranslation:)
    func macPlatformElement(fromTranslation translation: AnyObject) -> AnyObject?
}

/// `-[AXPMacPlatformElement accessibilityFrame]`. A `CGRect`-returning getter cannot ride through
/// KVC's type-erased `id`, so this one property is messaged rather than read by key.
@objc private protocol AXPElementFrameMessaging {
    @objc var accessibilityFrame: CGRect { get }
}

@objc private protocol SimDeviceAccessibilityMessaging {
    @objc(sendAccessibilityRequestAsync:completionQueue:completionHandler:)
    func sendAccessibilityRequestAsync(
        _ request: AnyObject,
        completionQueue: DispatchQueue,
        completionHandler: @escaping (AnyObject?) -> Void)
}

/// `+[AXPTranslatorResponse emptyResponse]`, messaged against the class object.
@objc private protocol AXPTranslatorResponseClassMessaging {
    @objc(emptyResponse) func emptyResponse() -> AnyObject?
}

// MARK: - The one process-wide bridge

/// `AXPTranslator`'s `bridgeTokenDelegate`. There is one slot per process, so there is one of
/// these, and a request finds its device by the token the caller registered — which is what lets
/// two panes on two devices describe at the same time without either one answering for the other.
///
/// The three methods are `AXPTranslationTokenDelegateHelper`'s, invoked by ObjC dispatch, so they
/// are `@objc dynamic` on an `NSObject` subclass with their selectors spelled out.
final class SimulatorAccessibilityBridge: NSObject {

    static let shared = SimulatorAccessibilityBridge()

    private struct Registration {
        var device: AnyObject
        var deadline: Date
    }

    private let lock = NSLock()
    private var registrations: [String: Registration] = [:]

    /// The protocol AXPTranslator declares its bridge-token delegate against. Absent means a
    /// future OS renamed it, which is information rather than failure — the selectors are what
    /// matter, and they are checked separately.
    private static let delegateProtocolName = "AXPTranslationTokenDelegateHelper"

    private static let requiredSelectors = [
        "accessibilityTranslationDelegateBridgeCallbackWithToken:",
        "accessibilityTranslationConvertPlatformFrameToSystem:withToken:",
        "accessibilityTranslationRootParentWithToken:",
    ]

    private override init() {
        super.init()
        // Claim formal conformance when the protocol is present, so a translator that gates on
        // `conformsToProtocol:` rather than `respondsToSelector:` still accepts us.
        if let proto = objc_getProtocol(Self.delegateProtocolName),
           !class_conformsToProtocol(Self.self, proto) {
            class_addProtocol(Self.self, proto)
        }
    }

    /// Which of the delegate protocol's required selectors this class does not implement. Empty is
    /// the only value that may be installed: a delegate missing one of them answers every request
    /// with nothing, which reads downstream as "the screen is empty".
    static func unimplementedDelegateSelectors() -> [String] {
        var missing = requiredSelectors.filter {
            !shared.responds(to: NSSelectorFromString($0))
        }
        guard let proto = objc_getProtocol(delegateProtocolName) else { return missing }
        var count: UInt32 = 0
        guard let descriptions = protocol_copyMethodDescriptionList(proto, true, true, &count)
        else { return missing }
        defer { free(descriptions) }
        for index in 0..<Int(count) {
            guard let selector = descriptions[index].name else { continue }
            let name = NSStringFromSelector(selector)
            if !shared.responds(to: selector), !missing.contains(name) { missing.append(name) }
        }
        return missing
    }

    func register(device: AnyObject, token: String, deadline: Date) {
        lock.lock()
        registrations[token] = Registration(device: device, deadline: deadline)
        lock.unlock()
    }

    func unregister(token: String) {
        lock.lock()
        registrations.removeValue(forKey: token)
        lock.unlock()
    }

    private func registration(for token: String) -> Registration? {
        lock.lock()
        defer { lock.unlock() }
        return registrations[token]
    }

    /// How many requests this bridge has actually forwarded. A tree that comes back empty with a
    /// zero here means the translator never called us at all, which is a different bug from a
    /// guest that answered with nothing.
    private(set) var forwardedRequests = 0

    // MARK: AXPTranslationTokenDelegateHelper

    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    dynamic func bridgeCallback(token: NSString) -> Any {
        let key = token as String
        // The block is what the translator actually calls, possibly many times and from its own
        // threads, for as long as the elements it vended are being read.
        let block: @convention(block) (AnyObject) -> AnyObject = { [weak self] request in
            guard let self, let registration = registration(for: key) else {
                return Self.emptyResponse()
            }
            let remaining = registration.deadline.timeIntervalSinceNow
            guard remaining > 0 else { return Self.emptyResponse() }
            lock.lock()
            forwardedRequests += 1
            lock.unlock()
            return send(request, to: registration.device, timeout: min(remaining, 10))
                ?? Self.emptyResponse()
        }
        return block
    }

    /// Identity. Inside Simulator.app this maps the guest's points into the display view's window;
    /// out here there is no window, so the frames arrive in the guest's own point space — which is
    /// the space we want, and re-projecting would only invent an offset.
    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    dynamic func convertPlatformFrameToSystem(_ frame: CGRect, withToken token: NSString) -> CGRect {
        frame
    }

    @objc(accessibilityTranslationRootParentWithToken:)
    dynamic func rootParent(withToken token: NSString) -> AnyObject? { nil }

    // MARK: XPC

    /// One request over the device's accessibility channel, waited out synchronously because that
    /// is the contract the translator's callback block has: it returns a response, not a promise.
    private func send(_ request: AnyObject, to device: AnyObject, timeout: TimeInterval) -> AnyObject? {
        let selector = "sendAccessibilityRequestAsync:completionQueue:completionHandler:"
        guard device.responds(to: NSSelectorFromString(selector)) else { return nil }

        final class Box: @unchecked Sendable { var response: AnyObject? }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        unsafeBitCast(device, to: SimDeviceAccessibilityMessaging.self)
            .sendAccessibilityRequestAsync(request, completionQueue: Self.replyQueue) { response in
                box.response = response
                group.leave()
            }
        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.response
    }

    /// Where the guest's replies land. Never the queue a describe runs on: that one is blocked
    /// waiting for this reply, and delivering onto it would deadlock.
    private static let replyQueue = DispatchQueue(
        label: "com.synth.simulator.accessibility.xpc", attributes: .concurrent)

    /// The framework's own empty response. Handing back `NSNull` instead makes the translator
    /// re-issue the request, so this matters for more than tidiness.
    private static func emptyResponse() -> AnyObject {
        guard let responseClass = SimulatorPrivateRuntime.lookUpClass(["AXPTranslatorResponse"])
        else { return NSNull() }
        let classObject = responseClass as AnyObject
        guard classObject.responds(to: NSSelectorFromString("emptyResponse")),
              let empty = unsafeBitCast(
                classObject, to: AXPTranslatorResponseClassMessaging.self).emptyResponse()
        else { return NSNull() }
        return empty
    }
}

// MARK: - Reader

/// One device's accessibility tree. Cheap to make — it resolves the framework, the translator and
/// the device handle and nothing else — and the first read pays a one-off ~1.2s while the guest's
/// accessibility server comes up.
final class SimulatorAccessibility: SimulatorAccessibilityReader {

    let udid: String
    private let device: AnyObject
    private let translator: AnyObject
    /// The device's own portrait profile. Never the AX root's frame: normalising a tree against a
    /// number the same tree reported hides exactly the bug worth catching.
    private let portraitPointSize: CGSize
    /// Set by the source when it rotates the device. There is no read-back from the guest, so this is
    /// "what Synth last asked for", which may be a lie: an app is free to refuse. It is used only to
    /// order the projection candidates so the usual case is confirmed on the first round trip, never
    /// as an input to any coordinate.
    var orientation: SimulatorOrientation = .portrait

    /// The display's point size — always the portrait profile, because the framebuffer never rotates,
    /// and the space every reported centre is a fraction of. It deliberately does not transpose with
    /// `orientation`: the interface's extent transposing is what a *projection* expresses, and which
    /// projection is real is confirmed against the device rather than assumed from a request.
    private var pointSize: CGSize { portraitPointSize }

    /// How long any one XPC round trip may take. A hung guest must not pin the caller: every verb
    /// here runs on a control connection's thread, and the pane's own describe runs off main.
    var requestTimeout: TimeInterval = 8
    /// Defensive bound on the walk. Real screens are 20–30 levels deep; this stops a cycle.
    private let depthLimit = 60
    /// How far a hit test walks below what it hit. A point on empty space resolves to the enclosing
    /// container, and walking that to full depth would answer a question about one point with most
    /// of the screen — while stopping at the container itself would answer with nothing at all.
    private let hitTestDepthLimit = 4
    /// Lines are the product, so the cap is on lines. A screen with more than this is a list that
    /// scrolls, and the answer to that is to scroll it, not to print all of it.
    private let elementLimit = 300
    /// How many hit tests one read may spend establishing which space its frames are in. A screen with
    /// one space costs one; only a mixed one — the keyboard up in landscape — costs more than a handful,
    /// and this is the ceiling that keeps a pathological tree from turning a 100 ms read into seconds.
    private let projectionRoundTripLimit = 48

    /// AXPTranslator is a singleton with per-token caches, and the element walk keeps issuing
    /// sub-requests after the entry point has returned. One describe at a time, process-wide,
    /// keeps two devices from interleaving inside those caches — a describe costs ~0.1s, so
    /// serialising them costs nothing worth having.
    private static let gate = DispatchQueue(label: "com.synth.simulator.accessibility")

    // MARK: Resolution

    /// The framework, loaded once. `RTLD_GLOBAL` deliberately: AXPTranslator's own lazy class
    /// lookups have to find its symbols.
    private static let framework: Result<Void, SimulatorAccessibilityFailure> = {
        // No `fileExists` guard, deliberately: this framework's binary lives only in the dyld
        // shared cache, so the path never exists on disk and dlopen is the only test there is.
        let path = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework"
            + "/AccessibilityPlatformTranslation"
        // SimulatorKit links this framework, so loading it from a plain third-party process is
        // exactly what Library Validation already admits (ADR-0015). Best-effort, and reported
        // rather than fatal if a future OS re-homes it.
        _ = try? SimulatorPrivateRuntime.loadSimulatorKit()
        guard dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil else {
            let error = dlerror().map { String(cString: $0) } ?? "dlopen failed"
            return .failure(.frameworkUnavailable(error))
        }
        return .success(())
    }()

    /// The shared translator, with our dispatcher in its one delegate slot. Resolved once because
    /// the slot is process-wide; re-asserted per call in case anything else claimed it.
    private static let sharedTranslator: Result<AnyObject, SimulatorAccessibilityFailure> = {
        if case let .failure(failure) = framework { return .failure(failure) }
        guard let translatorClass = SimulatorPrivateRuntime.lookUpClass(["AXPTranslator"]) else {
            return .failure(.translatorUnavailable("the AXPTranslator class is not registered"))
        }
        let classObject = translatorClass as AnyObject
        guard classObject.responds(to: NSSelectorFromString("sharedInstance")) else {
            return .failure(.selectorUnavailable(
                className: "AXPTranslator", selector: "sharedInstance"))
        }
        guard let translator = unsafeBitCast(classObject, to: AXPTranslatorClassMessaging.self)
            .sharedInstance()
        else {
            return .failure(.translatorUnavailable("+sharedInstance returned nil"))
        }
        for selector in ["setBridgeTokenDelegate:",
                         "frontmostApplicationWithDisplayId:bridgeDelegateToken:",
                         "macPlatformElementFromTranslation:"] {
            guard translator.responds(to: NSSelectorFromString(selector)) else {
                return .failure(.selectorUnavailable(
                    className: "AXPTranslator", selector: selector))
            }
        }
        let missing = SimulatorAccessibilityBridge.unimplementedDelegateSelectors()
        guard missing.isEmpty else { return .failure(.delegateUnsupported(missing: missing)) }
        return .success(translator)
    }()

    /// Whether the whole path resolves, without reading anything off a device.
    static var isAvailable: Bool {
        if case .success = sharedTranslator { return true }
        return false
    }

    init(device: AnyObject, udid: String) throws {
        // The same seam `SimulatorFrameSource` honours: a degraded simulator session is part of the
        // design, so it has to be reachable on a machine where the private path works — otherwise
        // the only thing that ever exercises it is the OS release that breaks it.
        if ProcessInfo.processInfo.environment["SYNTH_SIM_FORCE_DEGRADED"] != nil {
            throw ForcedDegradation()
        }
        self.translator = try Self.sharedTranslator.get()
        self.device = device
        self.udid = udid
        // The device type's profile is the cheap answer; `simctl` is the fallback, paid only when
        // CoreSimulator has moved the property. Never the AX root's own frame: normalising a tree
        // against a number the same tree reported hides exactly the bug worth catching.
        self.portraitPointSize = Self.pointSize(of: device)
            ?? (try? SimulatorDeviceCatalog.device(udid: udid))?.screenPointSize
            ?? .zero
    }

    convenience init(udid: String) throws {
        try self.init(device: try SimulatorPrivateRuntime.bootedDevice(udid: udid), udid: udid)
    }

    /// The display's point size, from the device type's own profile rather than from the guest.
    ///
    /// Read by key, not by a typed message send, and that is not a style choice: `mainScreenScale`
    /// is not a `double` here despite reading like one, so messaging it as one returns whatever was
    /// in the floating-point register — a NaN that then poisons every coordinate in the tree. KVC
    /// boxes by the method's real type encoding, which is the only way to be right about a property
    /// whose type is not ours to know.
    private static func pointSize(of device: AnyObject) -> CGSize? {
        guard let object = device as? NSObject,
              object.responds(to: NSSelectorFromString("deviceType")),
              let deviceType = object.value(forKey: "deviceType") as? NSObject,
              deviceType.responds(to: NSSelectorFromString("mainScreenSize")),
              deviceType.responds(to: NSSelectorFromString("mainScreenScale")),
              let pixels = (deviceType.value(forKey: "mainScreenSize") as? NSValue)?.sizeValue,
              let scale = (deviceType.value(forKey: "mainScreenScale") as? NSNumber)?.doubleValue,
              scale > 0, pixels.width >= 1, pixels.height >= 1
        else { return nil }
        return CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    // MARK: Reading

    func describeFrontmostApplication() throws -> SimulatorAccessibilityTree {
        try describe(hitTest: nil)
    }

    /// The element under a point given in the same normalised 0..1 coordinates `tap` takes.
    ///
    /// This is the server-side hit test, not a search of the tree we already walked, and that is
    /// the point: it reaches elements the recursive walk cannot. SwiftUI tab bars, nav bars and
    /// toolbars routinely enumerate as childless containers (idb#767), and their buttons only
    /// surface by hit-testing at them.
    func describe(at point: CGPoint) throws -> SimulatorAccessibilityTree {
        try describe(hitTest: point)
    }

    private func describe(hitTest: CGPoint?) throws -> SimulatorAccessibilityTree {
        try Self.gate.sync {
            do {
                return try attempt(hitTest: hitTest)
            } catch let failure as SimulatorAccessibilityFailure {
                // The one recoverable failure: SpringBoard died and took the guest's accessibility
                // server with it. Restarting the bridge brings both back. Exactly once — a second
                // failure is a real failure, and retrying forever would hide it.
                guard case .springBoardDead = failure else { throw failure }
                try restartBridge()
                return try attempt(hitTest: hitTest)
            }
        }
    }

    private func attempt(hitTest: CGPoint?) throws -> SimulatorAccessibilityTree {
        let bridge = SimulatorAccessibilityBridge.shared
        // One slot, and nothing stops another framework in this process from taking it. Cheaper to
        // re-assert than to debug the empty tree that follows if it was taken.
        let messaging = unsafeBitCast(translator, to: AXPTranslatorMessaging.self)
        let installed = translator.responds(to: NSSelectorFromString("bridgeTokenDelegate"))
            ? messaging.bridgeTokenDelegate : nil
        if installed !== bridge { messaging.bridgeTokenDelegate = bridge }

        let token = UUID().uuidString
        let deadline = Date().addingTimeInterval(requestTimeout)
        bridge.register(device: device, token: token, deadline: deadline)
        defer { bridge.unregister(token: token) }

        guard let translation = messaging.frontmostApplication(
            displayId: 0, bridgeDelegateToken: token as NSString)
        else { throw SimulatorAccessibilityFailure.noFrontmostApplication(udid: udid) }
        stamp(token, onTranslation: translation)

        guard let root = messaging.macPlatformElement(fromTranslation: translation) else {
            throw SimulatorAccessibilityFailure.noFrontmostApplication(udid: udid)
        }
        stamp(token, onElement: root)

        // The crashed-SpringBoard signature: the tree has no extent AND the process that would own
        // it is gone. Either alone is normal — the root's presenter pid reads 0 on a healthy tree,
        // and a launching app briefly has no frame.
        let rootFrame = Self.frame(of: root)
        if rootFrame.width < 1 || rootFrame.height < 1, !Self.isProcessAlive(Self.presenterPID(of: root)) {
            throw SimulatorAccessibilityFailure.springBoardDead(
                udid: udid,
                detail: "the frontmost application has a zero accessibility frame and no live "
                    + "process, which is what a crashed SpringBoard looks like")
        }

        let hitTestAvailable = translator.responds(
            to: NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:"))

        /// One hit test, addressed in the display's own points.
        ///
        /// Display points, not interface points, and that asymmetry is what this whole file turns on:
        /// `objectAtPoint:` asks "what is at this place on the screen", and the screen never rotates,
        /// while every frame it reports back is in the interface's space. Measured — feeding it
        /// interface coordinates in landscape resolved to nothing, feeding it display coordinates
        /// resolved to the element that owns the place. It is also the only question the guest will
        /// answer that *distinguishes* the four ways the interface could be sitting on the display.
        func elementAt(displayPoints point: CGPoint) -> HitOutcome {
            guard hitTestAvailable else { return .nothingThere }
            guard let translation = messaging.object(
                at: point, displayId: 0, bridgeDelegateToken: token as NSString)
            else { return .nothingThere }
            stamp(token, onTranslation: translation)
            guard let element = messaging.macPlatformElement(fromTranslation: translation)
            else { return .untranslatable }
            stamp(token, onElement: element)
            return .element(element)
        }

        let application = Self.string(root, "accessibilityLabel")
        var rows: [Row] = []
        var visited = 0
        var truncation: String?

        func note(_ reason: String) {
            if truncation == nil { truncation = reason }
        }

        /// An answer the guest has already given, for free: the caller's own point, and the frame of
        /// the element that turned out to be there. Only the point hit-test path has one, and it is
        /// what lets that path resolve a rotated screen at all — see `confirmedProjection`.
        var hitAnchor: (asked: CGPoint, frame: CGRect)?

        if let hitTest {
            guard hitTestAvailable else {
                throw SimulatorAccessibilityFailure.selectorUnavailable(
                    className: "AXPTranslator", selector: "objectAtPoint:displayId:bridgeDelegateToken:")
            }
            let inPoints = CGPoint(
                x: hitTest.x * portraitPointSize.width,
                y: hitTest.y * portraitPointSize.height)
            let hitElement: AnyObject
            switch elementAt(displayPoints: inPoints) {
            case let .element(element):
                hitElement = element
            case .nothingThere:
                return SimulatorAccessibilityTree(
                    application: application, pointSize: pointSize, elements: [], visitedCount: 0,
                    truncation: "nothing accessible under \(format(hitTest))")
            case .untranslatable:
                return SimulatorAccessibilityTree(
                    application: application, pointSize: pointSize, elements: [], visitedCount: 0,
                    truncation: "the element under \(format(hitTest)) could not be translated")
            }
            hitAnchor = (hitTest, Self.frame(of: hitElement))
            var stamped = 0
            var seen: Set<ObjectIdentifier> = []
            stampSubtree(hitElement, token: token, depth: 0, depthCap: hitTestDepthLimit,
                         deadline: deadline, stamped: &stamped, seen: &seen)
            walk(hitElement, depth: 0, depthCap: hitTestDepthLimit, deadline: deadline,
                 into: &rows, visited: &visited, note: note)
        } else {
            var stamped = 0
            var seen: Set<ObjectIdentifier> = []
            stampSubtree(root, token: token, depth: 0, depthCap: depthLimit,
                         deadline: deadline, stamped: &stamped, seen: &seen)
            walk(root, depth: 0, depthCap: depthLimit, deadline: deadline,
                 into: &rows, visited: &visited, note: note)
        }

        // Only now, with the frames in hand, is there anything to ask the device about. Every centre
        // below goes through a space the device has confirmed.
        var roundTrips = 0
        var caveats: [String] = []
        let (projection, caveat) = try confirmedProjection(
            rows: rows, rootFrame: rootFrame, hitAnchor: hitAnchor,
            hitTest: { elementAt(displayPoints: $0) }, roundTrips: &roundTrips)
        if let caveat { caveats.append(caveat) }
        let elements = projected(
            rows: rows, primary: projection, hitTest: { elementAt(displayPoints: $0) },
            roundTrips: &roundTrips, note: { caveats.append($0) })

        return SimulatorAccessibilityTree(
            application: application, pointSize: pointSize,
            elements: Self.deduplicated(elements),
            visitedCount: visited, truncation: truncation,
            geometryCaveat: caveats.isEmpty ? nil : caveats.joined(separator: "; "))
    }

    /// What `objectAtPoint:` came back with. Nothing there and there-but-untranslatable are different
    /// links in the chain breaking, and a caller told "nothing is there" about the second one would
    /// go looking in the wrong place.
    private enum HitOutcome {
        case element(AnyObject)
        case nothingThere
        case untranslatable
    }

    /// One question the device will answer about a space: predict where `row`'s centre lands on the
    /// display if `space` is the space it is in, ask what is at that place, and require the answer to
    /// **be** `row` — the row's own frame, or something inside it, which is what a hit test at the
    /// centre of the right element returns. A wrong space names a point belonging to some other part
    /// of the screen, and the answer's frame says so.
    ///
    /// Merely *containing* the row's centre is not evidence, and this was measured rather than
    /// reasoned: asked in the wrong space, Safari's address field — three times the area of the
    /// keyboard's dictate key and spanning it — came back containing the dictate key's centre, and an
    /// area bound loose enough to admit a container admitted that too.
    private func confirms(
        _ space: SimulatorInterfaceProjection, at row: Row,
        hitTest: (CGPoint) -> HitOutcome, roundTrips: inout Int
    ) -> Bool {
        let predicted = space.displayPoint(row.centre)
        // A prediction off the display cannot be tested and says nothing either way: an element
        // genuinely scrolled off the edge — a tab in Safari's tab bar — produces one under the right
        // space too.
        guard (0.002...0.998).contains(predicted.x), (0.002...0.998).contains(predicted.y)
        else { return false }
        roundTrips += 1
        guard case let .element(element) = hitTest(CGPoint(
            x: predicted.x * portraitPointSize.width,
            y: predicted.y * portraitPointSize.height)) else { return false }
        return row.frame.insetBy(dx: -3, dy: -3).contains(Self.frame(of: element))
    }

    /// The first candidate any anchor confirms.
    private func confirmedSpace(
        among candidates: [SimulatorInterfaceProjection], anchors: [Row],
        hitTest: (CGPoint) -> HitOutcome, roundTrips: inout Int
    ) -> SimulatorInterfaceProjection? {
        for candidate in candidates {
            for anchor in anchors {
                if confirms(candidate, at: anchor, hitTest: hitTest, roundTrips: &roundTrips) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// The space the app itself laid its interface out in, plus the caveat to print if it could only be
    /// assumed.
    ///
    /// Nothing on this platform will say which way up an app has laid itself out. The guest publishes
    /// no orientation read-back (`SimScreenProperties.uiOrientation` answers 0 in every orientation),
    /// and an app is free to ignore a rotation — Settings is portrait-locked — so what Synth last
    /// *asked for* is write-only state that may be a lie, and the root frame's own shape says
    /// landscape without saying which landscape. A hit test is the one question left, and it is
    /// answerable precisely because the two halves of this API disagree about space: frames come back
    /// in the interface's, hit tests go in in the display's.
    private func confirmedProjection(
        rows: [Row], rootFrame: CGRect, hitAnchor: (asked: CGPoint, frame: CGRect)?,
        hitTest: (CGPoint) -> HitOutcome, roundTrips: inout Int
    ) throws -> (SimulatorInterfaceProjection, String?) {
        let ranked = orderedCandidates(rootFrame: rootFrame, hitAnchor: hitAnchor)

        // A hit test the caller already paid for is a confirmation in its own right, and a free one.
        // The element at display point P has frame F in whatever space *it* is in, so that space has to
        // put P's preimage inside F — the true space is therefore always among the consistent ones, and
        // a consistent set of exactly one is the answer. This is what lets the point hit-test verb work
        // on a rotated screen at all: it walks four levels of a single element, which is often too
        // little to find an anchor of its own. Weighed against all four candidates rather than the ones
        // the app's shape allows, because the element the caller hit may not be in the app's space —
        // which is exactly what a keyboard key is.
        if let hitAnchor {
            let consistent = ranked.filter {
                hitAnchor.frame.contains($0.interfacePoint(fromDisplay: hitAnchor.asked))
            }
            if consistent.count == 1 { return (consistent[0], nil) }
        }

        // The app element's own frame is in the app's own space, so a shape it cannot fit into is not a
        // candidate for the walk at all — which is what stops a foreign-space anchor confirming a
        // portrait reading of a landscape screen.
        let shaped = ranked.filter { Self.fits(rootFrame, $0.interfaceSize) }
        let candidates = shaped.isEmpty ? ranked : shaped

        // Anchors from inside the app's own frame, and — where the shapes differ at all — ones the
        // *other* shape could not contain. Without that second rule a tree with two spaces in it can
        // confirm the wrong answer for the whole screen off one of the foreign elements.
        let anchors = Self.anchors(
            in: rows, bounds: rootFrame,
            ambiguousWith: candidates.first.map { transposed($0.interfaceSize) })
        if let confirmed = confirmedSpace(
            among: candidates, anchors: anchors, hitTest: hitTest, roundTrips: &roundTrips) {
            return (confirmed, nil)
        }

        // Nothing confirmed. A portrait-shaped interface the size of the display has exactly one
        // sensible reading left, and taking it is better than refusing every screen too bare to hit
        // test against — a launching app, an alert over a blank root. Say so rather than implying it
        // was proved.
        if abs(rootFrame.width - portraitPointSize.width) < 1,
           abs(rootFrame.height - portraitPointSize.height) < 1 {
            return (SimulatorInterfaceProjection(
                interfaceSize: portraitPointSize, turn: .portrait),
                anchors.isEmpty
                    ? "no element on this screen could be hit tested, so the centres below assume the "
                        + "interface is upright — which matches its \(Int(rootFrame.width))×"
                        + "\(Int(rootFrame.height))pt extent, but was not confirmed against the device"
                    : "the interface's orientation could not be confirmed against the device in "
                        + "\(roundTrips) hit tests; the centres below assume it is upright")
        }
        throw SimulatorAccessibilityFailure.unconfirmedProjection(
            interface: rootFrame.size, display: portraitPointSize, roundTrips: roundTrips)
    }

    /// Every row, projected — each by the space it is actually in.
    ///
    /// Almost always there is one space and this is arithmetic. But a tree can genuinely mix them: with
    /// the keyboard up in landscape, Safari's own elements come back in the interface's space while
    /// every key comes back in the **display's**, unrotated, as flat siblings of them — and there is
    /// nothing structural to tell them apart, because `accessibilityWindow`, `accessibilityParent` and
    /// `accessibilityTopLevelUIElement` are all absent on `AXPMacPlatformElement` here and the
    /// presenter pid reads 0 on every element. Measured: a hit test at a key's raw centre returns that
    /// key, and at its projected centre returns nothing.
    ///
    /// So rows the app's own space cannot contain but a transposed one exactly can are the evidence that
    /// a second space exists, and once it does, the rows that *both* spaces could contain are settled the
    /// only way they can be — by asking the device about each one. That cost is paid only on a screen
    /// that really is mixed. Anything the device will not settle is reported in the app's own space with
    /// the tree saying so, because a caveat a caller can read beats an element that silently vanished.
    private func projected(
        rows: [Row], primary: SimulatorInterfaceProjection, hitTest: (CGPoint) -> HitOutcome,
        roundTrips: inout Int, note: (String) -> Void
    ) -> [SimulatorAccessibilityElement] {
        let foreignSize = transposed(primary.interfaceSize)
        func fitsPrimary(_ row: Row) -> Bool { Self.fits(row.frame, primary.interfaceSize) }
        func fitsForeign(_ row: Row) -> Bool { Self.fits(row.frame, foreignSize) }

        // The signature of a second space is an element the app's own extent cannot hold but the
        // transposed one exactly can. Merely overflowing is not that signature and must not be read as
        // it: a horizontal carousel's content view is wider than the screen in any orientation, and it
        // is still the app's own element in the app's own space.
        let outside = rows.filter { !fitsPrimary($0) && fitsForeign($0) }
        guard !outside.isEmpty else { return rows.map { $0.projected(by: primary) } }

        // A second space, confirmed exactly as the first was, least turned first: an unrotated window
        // is what this has turned out to be every time it has appeared.
        let foreignCandidates = SimulatorInterfaceProjection
            .candidates(displayPointSize: portraitPointSize)
            .filter { $0.interfaceSize == foreignSize }
            .sorted { $0.turn.clockwiseQuarterTurns < $1.turn.clockwiseQuarterTurns }
        let foreignBounds = CGRect(origin: .zero, size: foreignSize)
        guard let foreign = confirmedSpace(
            among: foreignCandidates,
            anchors: Self.anchors(in: outside, bounds: foreignBounds,
                                  ambiguousWith: primary.interfaceSize),
            hitTest: hitTest, roundTrips: &roundTrips)
        else {
            note("\(outside.count) elements do not fit the space the rest of this screen is in, and "
                 + "which space they are in could not be confirmed against the device — every centre "
                 + "below is the app's own space, which may be wrong for those")
            return rows.map { $0.projected(by: primary) }
        }

        // Where the foreign space has been seen. Only an ordering: a row inside it is asked about the
        // foreign space first, which is one round trip instead of two for most of a keyboard.
        let foreignRegion = outside.reduce(CGRect.null) { $0.union($1.frame) }
            .insetBy(dx: -Self.boundsTolerance, dy: -Self.boundsTolerance)

        var elements: [SimulatorAccessibilityElement] = []
        var unsettled = 0
        for row in rows {
            // Only the overlap is a question. An element too big for either space overflows the screen
            // rather than living somewhere else, and it is the app's own.
            guard fitsPrimary(row), fitsForeign(row) else {
                elements.append(row.projected(by: fitsForeign(row) ? foreign : primary))
                continue
            }
            let order = foreignRegion.contains(row.frame) ? [foreign, primary] : [primary, foreign]
            if roundTrips < projectionRoundTripLimit, let space = order.first(where: {
                confirms($0, at: row, hitTest: hitTest, roundTrips: &roundTrips)
            }) {
                elements.append(row.projected(by: space))
            } else {
                unsettled += 1
                elements.append(row.projected(by: primary))
            }
        }
        if unsettled > 0 {
            note("\(unsettled) of \(elements.count) elements sit where this screen's two coordinate "
                 + "spaces overlap and the device would not say which they are in; theirs is the app's "
                 + "own space here, which may be wrong for them")
        }
        return elements
    }

    private func transposed(_ size: CGSize) -> CGSize {
        CGSize(width: size.height, height: size.width)
    }

    /// Whether a frame belongs to a space of this extent. Tolerant by a few points on purpose: frames
    /// can overhang their own space's bounds — the keyboard's emoji and dictate keys stick 3pt past the
    /// display's right edge — and reading that overhang as proof of a *different* space is how a
    /// correct classification turns into a wrong one.
    private static func fits(_ frame: CGRect, _ size: CGSize) -> Bool {
        CGRect(origin: .zero, size: size).insetBy(dx: -boundsTolerance, dy: -boundsTolerance)
            .contains(frame)
    }

    private static let boundsTolerance: CGFloat = 8

    /// The candidates, most likely first. Ordering only — every one of them still has to be confirmed
    /// — but it is what keeps the usual read down to a single extra round trip: the interface's shape
    /// rules out half of them, and the orientation Synth last asked for usually picks correctly
    /// between the remaining two.
    private func orderedCandidates(
        rootFrame: CGRect, hitAnchor: (asked: CGPoint, frame: CGRect)?
    ) -> [SimulatorInterfaceProjection] {
        let rootIsLandscape = rootFrame.width > rootFrame.height
        return SimulatorInterfaceProjection.candidates(displayPointSize: portraitPointSize)
            .enumerated()
            .sorted { left, right in
                let (a, b) = (rank(left.element), rank(right.element))
                return a == b ? left.offset < right.offset : a < b
            }
            .map(\.element)

        func rank(_ candidate: SimulatorInterfaceProjection) -> Int {
            var rank = 0
            if candidate.turn.isLandscape != rootIsLandscape { rank += 8 }
            if let hitAnchor, !hitAnchor.frame.contains(
                candidate.interfacePoint(fromDisplay: hitAnchor.asked)) { rank += 4 }
            if candidate.turn != orientation { rank += 2 }
            if candidate.turn == .portraitUpsideDown { rank += 1 }
            return rank
        }
    }

    /// Elements a space can be tested against. Four properties matter and each one rules out a way of
    /// confirming the wrong answer:
    ///
    ///   * a **leaf**, so the hit test comes back with this element rather than something nested inside
    ///     it, which is what makes the frames comparable at all;
    ///   * **small**, so an answer that is some enclosing container is visibly not a confirmation;
    ///   * **off both of the space's mid-lines**, because an element centred on one has two candidate
    ///     projections predicting the *same* display point — which would confirm whichever of them was
    ///     tried first. This is the trap: it is exactly the elements a designer centres that make a
    ///     wrong projection look right;
    ///   * not one the **other** extent could equally contain, where that is knowable, because a tree
    ///     with two spaces in it must not have the whole screen decided off one of the foreign ones.
    private static func anchors(
        in rows: [Row], bounds: CGRect, ambiguousWith otherSize: CGSize?, limit: Int = 4
    ) -> [Row] {
        let usable = rows.filter { row in
            row.isLeaf && row.frame.width >= 20 && row.frame.height >= 20
                && row.area <= bounds.width * bounds.height * 0.1
                && bounds.insetBy(dx: -boundsTolerance, dy: -boundsTolerance).contains(row.frame)
                && abs((row.frame.midX - bounds.minX) / bounds.width - 0.5) > 0.08
                && abs((row.frame.midY - bounds.minY) / bounds.height - 0.5) > 0.08
        }
        // Unambiguous first, then smallest: the tighter the anchor, the less room a wrong answer has to
        // look like a right one. Spread out, so a second attempt is not the same question again.
        var chosen: [Row] = []
        let ordered = usable.sorted { left, right in
            func ambiguous(_ row: Row) -> Bool { otherSize.map { fits(row.frame, $0) } ?? false }
            if ambiguous(left) != ambiguous(right) { return !ambiguous(left) }
            return left.area < right.area
        }
        for row in ordered {
            let far = chosen.allSatisfy {
                hypot($0.frame.midX - row.frame.midX, $0.frame.midY - row.frame.midY)
                    > bounds.width * 0.1
            }
            if far { chosen.append(row) }
            if chosen.count >= limit { break }
        }
        return chosen
    }

    private func format(_ point: CGPoint) -> String {
        String(format: "(%.3f, %.3f)", point.x, point.y)
    }

    /// Kicks `com.apple.CoreSimulator.bridge` on the device, which is what brings SpringBoard and
    /// the guest's accessibility server back. `system/` is the spelling launchd still accepts (with
    /// a deprecation warning); `user/<uid>/` is the one it asks for.
    private func restartBridge() throws {
        let service = "com.apple.CoreSimulator.bridge"
        for domain in ["system/\(service)", "user/\(getuid())/\(service)"] {
            let output = try? SimulatorShell.run(
                "/usr/bin/xcrun",
                ["simctl", "spawn", udid, "launchctl", "kickstart", "-k", domain], timeout: 30)
            if output?.status == 0 {
                // The bridge re-registers its XPC service; describing before it does just fails again.
                Thread.sleep(forTimeInterval: 2)
                return
            }
        }
        throw SimulatorAccessibilityFailure.springBoardDead(
            udid: udid,
            detail: "its accessibility server is not answering and restarting "
                + "\(service) on the device did not work either. Reboot the device.")
    }

    // MARK: Token stamping

    /// The translator re-reads `bridgeDelegateToken` off every translation object it touches, so
    /// an unstamped child's own sub-request routes nowhere and silently reads as empty.
    private func stamp(_ token: String, onTranslation translation: AnyObject) {
        guard translation.responds(to: NSSelectorFromString("setBridgeDelegateToken:")) else { return }
        (translation as? NSObject)?.setValue(token, forKey: "bridgeDelegateToken")
    }

    private func stamp(_ token: String, onElement element: AnyObject) {
        guard element.responds(to: NSSelectorFromString("translation")),
              let object = element as? NSObject,
              let translation = object.value(forKey: "translation") as? NSObject
        else { return }
        stamp(token, onTranslation: translation)
    }

    /// Stamps the subtree before anything is read. Done as its own pass rather than inline with the
    /// walk because reading a child's properties is already a sub-request, and a sub-request from
    /// an unstamped object is the failure this prevents.
    /// Bounded exactly as the walk is. Unbounded this was the one pass that could park the
    /// process-wide translator gate and the caller's thread indefinitely: it recurses before anything
    /// is read and makes an XPC sub-request per node, so a deep or wide screen paid for every node
    /// with no deadline and no cap. Identity is tracked as well as depth, because depth alone does
    /// not terminate a graph that contains a cycle.
    private func stampSubtree(
        _ element: AnyObject, token: String, depth: Int, depthCap: Int,
        deadline: Date, stamped: inout Int, seen: inout Set<ObjectIdentifier>
    ) {
        guard depth < depthCap, stamped < elementLimit, Date() < deadline else { return }
        guard seen.insert(ObjectIdentifier(element)).inserted else { return }
        for child in Self.children(of: element) {
            guard stamped < elementLimit, Date() < deadline else { return }
            stamp(token, onElement: child)
            stamped += 1
            stampSubtree(child, token: token, depth: depth + 1, depthCap: depthCap,
                         deadline: deadline, stamped: &stamped, seen: &seen)
        }
    }

    // MARK: Walk

    /// One element as the guest reported it: the fields, and the frame in the **interface's** own
    /// points. Separate from `SimulatorAccessibilityElement` because that type's centre is already in
    /// the display's space, and which space that is cannot be known until the walk has finished —
    /// deciding it needs a frame to ask the device about.
    private struct Row {
        var role: String
        var subrole: String?
        var label: String?
        var identifier: String?
        var value: String?
        var isEnabled: Bool
        var isFocused: Bool
        var frame: CGRect
        /// Whether the accessibility tree ends here. Only anchors care, and for them it is the
        /// difference between a hit test that can confirm a projection and one that cannot.
        var isLeaf: Bool

        var centre: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
        var area: CGFloat { frame.width * frame.height }

        var carriesInformation: Bool {
            label?.isEmpty == false || identifier?.isEmpty == false || value?.isEmpty == false
        }

        func projected(by projection: SimulatorInterfaceProjection) -> SimulatorAccessibilityElement {
            SimulatorAccessibilityElement(
                role: role, subrole: subrole, label: label, identifier: identifier, value: value,
                centre: projection.displayPoint(centre),
                isEnabled: isEnabled, isFocused: isFocused)
        }
    }

    private func walk(
        _ element: AnyObject, depth: Int, depthCap: Int, deadline: Date,
        into rows: inout [Row], visited: inout Int, note: (String) -> Void
    ) {
        guard rows.count < elementLimit else {
            note("\(elementLimit)-element cap reached — scroll and describe again")
            return
        }
        guard Date() < deadline else {
            note("the device stopped answering partway through; this is what arrived")
            return
        }
        visited += 1

        let frame = Self.frame(of: element)
        let children = Self.children(of: element)
        let isHidden = Self.bool(element, "isAccessibilityHidden", default: false)
        if !isHidden, frame.width >= 1, frame.height >= 1 {
            let row = Row(
                role: Self.shortRole(Self.string(element, "accessibilityRole") ?? "AXUnknown"),
                subrole: Self.string(element, "accessibilitySubrole").map(Self.shortRole),
                label: Self.string(element, "accessibilityLabel"),
                identifier: Self.string(element, "accessibilityIdentifier"),
                value: Self.stringOrNumber(element, "accessibilityValue"),
                isEnabled: Self.bool(element, "isAccessibilityEnabled", default: true),
                isFocused: Self.bool(element, "isAccessibilityFocused", default: false),
                frame: frame, isLeaf: children.isEmpty)
            // The application element's own name is the header, not a row.
            if row.carriesInformation, depth > 0 || row.role != "application" {
                rows.append(row)
            }
        }

        guard depth < depthCap else {
            note("\(depthCap) levels deep and still nesting — the rest was not walked")
            return
        }
        for child in children {
            walk(child, depth: depth + 1, depthCap: depthCap, deadline: deadline,
                 into: &rows, visited: &visited, note: note)
        }
    }

    /// Two elements with the same role, label and centre are the same thing seen twice — AXP
    /// re-vends elements through container wrappers. The outermost wins, which is the one whose
    /// centre a tap should aim at.
    private static func deduplicated(
        _ elements: [SimulatorAccessibilityElement]
    ) -> [SimulatorAccessibilityElement] {
        var seen = Set<String>()
        return elements.filter { seen.insert($0.line).inserted }
    }

    /// `AXButton` → `button`. The prefix is on every role and says nothing; a line per element is
    /// only cheap if every field earns its characters.
    private static func shortRole(_ role: String) -> String {
        guard role.hasPrefix("AX"), role.count > 2 else { return role }
        let stripped = role.dropFirst(2)
        return stripped.prefix(1).lowercased() + stripped.dropFirst()
    }

    // MARK: Element reads

    /// Every read goes through `respondsToSelector:` first, and not only for the usual reason:
    /// `AXPMacPlatformElement` inherits most of these from AppKit's `NSObject (NSAccessibility)`
    /// category but implements neither `accessibilityEnabled` nor `accessibilityTraits`, and
    /// `valueForKey:` on an absent key raises an ObjC exception a Swift caller cannot catch.
    private static func value(_ element: AnyObject, _ key: String) -> Any? {
        guard element.responds(to: NSSelectorFromString(key)) else { return nil }
        return (element as? NSObject)?.value(forKey: key)
    }

    private static func string(_ element: AnyObject, _ key: String) -> String? {
        guard let text = value(element, key) as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Sliders, page controls and progress views answer `accessibilityValue` with an `NSNumber`.
    private static func stringOrNumber(_ element: AnyObject, _ key: String) -> String? {
        switch value(element, key) {
        case let text as String: return text.isEmpty ? nil : text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func bool(_ element: AnyObject, _ key: String, default fallback: Bool) -> Bool {
        (value(element, key) as? NSNumber)?.boolValue ?? fallback
    }

    private static func frame(of element: AnyObject) -> CGRect {
        guard element.responds(to: NSSelectorFromString("accessibilityFrame")) else { return .zero }
        return unsafeBitCast(element, to: AXPElementFrameMessaging.self).accessibilityFrame
    }

    private static func children(of element: AnyObject) -> [AnyObject] {
        (value(element, "accessibilityChildren") as? [AnyObject]) ?? []
    }

    private static func presenterPID(of element: AnyObject) -> pid_t {
        guard let number = value(element, "accessibilityPresenterProcessIdentifier") as? NSNumber
        else { return 0 }
        return pid_t(number.int32Value)
    }

    /// `kill(pid, 0)` is the liveness test; EPERM means alive and not ours, which still counts.
    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - Degraded mode

/// Accessibility with no engine behind it. Unlike the screen, there is nothing to fall back to:
/// `simctl` has no accessibility verb at any version, so every call is a refusal carrying the
/// reason. Answering with an empty tree instead would read as "the screen has nothing on it".
final class SimulatorUnavailableAccessibility: SimulatorAccessibilityReader {
    /// Accepted and ignored: there is no tree to normalise, so orientation cannot change an answer
    /// that is always a refusal.
    var orientation: SimulatorOrientation = .portrait

    let detail: String

    init(detail: String) {
        self.detail = detail
    }

    func describeFrontmostApplication() throws -> SimulatorAccessibilityTree {
        throw SimulatorAccessibilityFailure.unavailable(detail)
    }

    func describe(at point: CGPoint) throws -> SimulatorAccessibilityTree {
        throw SimulatorAccessibilityFailure.unavailable(detail)
    }
}

// MARK: - Pre-boot preferences

extension SimulatorAccessibility {

    /// The first runtime version that ignores post-boot accessibility preferences.
    private static let cachedPreferencesFrom = (major: 26, minor: 5)

    /// iOS 26.5 and later read the guest's accessibility preferences once, early, and cache them:
    /// SpringBoard never sees a write that lands after boot. So the keys that let an out-of-process
    /// client talk to the accessibility server have to be in the file *before* `simctl boot`.
    ///
    /// Merged into whatever is already there rather than written over it — this is the user's own
    /// device, and the file also holds settings they chose.
    ///
    /// Older runtimes need none of this and are left alone. Called from `SimulatorDeviceCatalog`'s
    /// boot path, which is the only moment it can work.
    @discardableResult
    static func prepareForBoot(udid: String, runtimeVersion: String) -> Bool {
        guard needsCachedPreferences(runtimeVersion: runtimeVersion) else { return false }
        let path = preferencesPath(udid: udid)
        var preferences: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] {
            preferences = existing
        }
        for key in ["IgnoreAXServerEntitlements", "AutomationEnabled",
                    "AccessibilityEnabled", "ApplicationAccessibilityEnabled"] {
            preferences[key] = true
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: preferences, format: .binary, options: 0) else { return false }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        return FileManager.default.createFile(atPath: path, contents: data)
    }

    /// "18.4" → false, "26.5" and up → true. A version string that will not parse is treated as
    /// new rather than old: a needless write to an old runtime is harmless, and a missing write to
    /// a new one silently disables the whole capability.
    static func needsCachedPreferences(runtimeVersion: String) -> Bool {
        let parts = runtimeVersion.split(separator: ".").map { Int($0) }
        guard let major = parts.first ?? nil else { return true }
        let minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        if major != cachedPreferencesFrom.major { return major > cachedPreferencesFrom.major }
        return minor >= cachedPreferencesFrom.minor
    }

    /// The guest's `com.apple.Accessibility.plist`. The device set can be moved with
    /// `CORE_SIMULATOR_DEVICE_SET_PATH`, which `simctl` honours, so this does too.
    private static func preferencesPath(udid: String) -> String {
        let deviceSet = ProcessInfo.processInfo.environment["CORE_SIMULATOR_DEVICE_SET_PATH"]
            ?? NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices"
        return deviceSet + "/" + udid + "/data/Library/Preferences/com.apple.Accessibility.plist"
    }
}
