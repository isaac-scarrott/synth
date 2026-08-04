import CoreGraphics
import Foundation
import ObjectiveC

// Indigo HID injection: touches, keys and hardware buttons sent to the same device whose
// framebuffer the pane is showing (ADR-0015). There is no XCUITest runner, no injected bundle and
// no app-side agent, so this drives any app including ones we did not build — and a tap from the
// agent is byte-identical to a tap from the mouse.
//
// The wire format is reached through SimulatorKit's own `IndigoHIDMessageFor*` C builders rather
// than hand-rolled structs, because the builders are what Simulator.app itself uses and they carry
// the digitizer fields nobody has fully reverse-engineered. Two measured constraints shape the
// code below:
//
//   * There is no single-touch builder. `IndigoHIDMessageForMouseNSEvent` always emits a
//     three-payload multi-touch message, so a valid digitizer contact is sourced from it and then
//     re-enveloped as a two-payload single-touch message.
//   * SimulatorKit lays multi-payload messages at a wire stride of 0xA0 while the payload struct
//     is 0x90 wide. Every offset here is therefore an explicit wire offset written unaligned —
//     the format is `#pragma pack(4)`, so `xRatio` sits at 0x3C and no Swift struct can express it.

// MARK: - Vocabulary

/// A press direction. Values are Indigo's own (`NSEventTypeKeyDown/Up` minus 10).
enum SimulatorInputDirection: Int32, Sendable {
    case down = 1
    case up = 2
}

/// A hardware button, limited to what the legacy Indigo path can actually deliver. Volume up and
/// down are deliberately absent: they are Consumer-page usages with no Indigo event source, so
/// offering them here would mean offering something that silently does nothing.
enum SimulatorHardwareButton: String, CaseIterable, Sendable {
    case home
    case lock
    case sideButton
    case siri
    case applePay

    /// Indigo's `IndigoButton.eventSource`.
    var indigoEventSource: Int32 {
        switch self {
        case .home: return 0x0
        case .lock: return 0x1
        case .sideButton: return 0xBB8
        case .siri: return 0x400002
        case .applePay: return 0x1F4
        }
    }
}

enum SimulatorHIDFailure: Error, CustomStringConvertible {
    case builderUnavailable(String)
    case clientUnavailable(String)
    case sessionFailed(String)
    case unrepresentableText(String)

    var description: String {
        switch self {
        case let .builderUnavailable(name):
            return "SimulatorKit does not export \(name) in this Xcode."
        case let .clientUnavailable(detail):
            return "No Indigo HID client: \(detail)"
        case let .sessionFailed(detail):
            return "The Indigo HID session could not be opened: \(detail)"
        case let .unrepresentableText(text):
            return "No HID keyboard usage for \(text.debugDescription)."
        }
    }
}

// MARK: - Runtime-only messaging surface

/// `SimDeviceLegacyHIDClient`, messaged by name. The class has moved framework between Xcodes, so
/// it is never referenced as a Swift type — that would emit a link-time class symbol pinned to one
/// bundle. Allocated with `class_createInstance` and messaged through `unsafeBitCast` to this.
@objc private protocol SimDeviceLegacyHIDClientMessaging {
    @objc(initWithDevice:error:)
    func initWithDevice(_ device: AnyObject, error: NSErrorPointer) -> AnyObject?

    @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
    func send(
        withMessage message: UnsafeMutableRawPointer,
        freeWhenDone: Bool,
        completionQueue: DispatchQueue,
        completion: @escaping (Error?) -> Void)

    @objc(resetHIDSession)
    func resetHIDSession()
}

// MARK: - Wire format

/// Explicit wire offsets into an Indigo message. Deliberately raw offsets and not a Swift struct:
/// the format is `#pragma pack(4)`, so doubles sit on 4-byte boundaries that no Swift layout can
/// reproduce, and SimulatorKit's own multi-payload stride is wider than the struct anyway.
private enum IndigoWire {
    /// `mach_msg_header_t` + `innerSize` + `eventType` + pad.
    static let innerSizeOffset = 0x18
    static let eventTypeOffset = 0x1C
    static let firstPayloadOffset = 0x20

    /// Within an `IndigoPayload`.
    static let payloadEventKindOffset = 0x00
    static let payloadTimestampOffset = 0x04
    static let payloadEventOffset = 0x10

    /// `sizeof(IndigoPayload)` as a packed struct — the stride a hand-built message uses.
    static let payloadStride = 0x90
    /// What SimulatorKit's own multi-payload messages use. Larger than the struct; getting this
    /// wrong sends garbage to the guest.
    static let simulatorKitPayloadStride = 0xA0
    /// Where SimulatorKit puts the second payload of a multi-payload message.
    static let simulatorKitSecondPayloadOffset = 0xC0

    /// Within an `IndigoTouch` event.
    static let touchField1Offset = 0x00
    static let touchField2Offset = 0x04
    static let touchXRatioOffset = 0x0C
    static let touchYRatioOffset = 0x14
    static let touchSize = 0x70

    static let touchEventKind: UInt32 = 0x0B
    static let singleTouchEventType: UInt8 = 0x02
    /// The `IndigoHIDMessageForMouseNSEvent` target for the main-screen digitizer.
    static let mouseTarget: Int32 = 0x32
    /// `ButtonEventTargetHardware`.
    static let hardwareButtonTarget: Int32 = 0x33

    /// A single-touch message: header + two payloads.
    static let singleTouchMessageSize = firstPayloadOffset + payloadStride * 2
}

private func writeUnaligned<Value>(_ value: Value, to base: UnsafeMutableRawPointer, offset: Int) {
    withUnsafeBytes(of: value) { bytes in
        guard let source = bytes.baseAddress else { return }
        memcpy(base.advanced(by: offset), source, bytes.count)
    }
}

// MARK: - HID

/// The one long-lived Indigo HID session for a device. Spawning a session costs ~1.2s plus a
/// warm-up, so exactly one is kept per device and reused for every gesture — building one per tap
/// would put a second and a half in front of every touch.
///
/// Raw `touch down / move / up` verbs are sent rather than synthesised gestures: the guest already
/// interprets a short press as a tap and a drag as a swipe, so re-deriving that here would only be
/// a worse copy of iOS's own recogniser.
final class SimulatorHID {

    // MARK: Builders

    private typealias MessageForButton =
        @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer?
    private typealias MessageForKeyboardArbitrary =
        @convention(c) (Int32, Int32) -> UnsafeMutableRawPointer?
    private typealias MessageForMouseNSEvent =
        @convention(c) (
            UnsafeMutablePointer<CGPoint>?, UnsafeMutablePointer<CGPoint>?, Int32, Int32, ObjCBool
        ) -> UnsafeMutableRawPointer?

    /// Which Indigo builders this Xcode exports. Reported rather than assumed: the set has changed
    /// across Xcodes and a missing builder is the difference between "input works" and a no-op.
    static let builderAvailability: [String: Bool] = {
        let names = [
            "IndigoHIDMessageForButton",
            "IndigoHIDMessageForKeyboardArbitrary",
            "IndigoHIDMessageForKeyboardNSEvent",
            "IndigoHIDMessageForMouseNSEvent",
            "IndigoHIDMessageForModifierKeyBit",
            "IndigoHIDMessageForScrollEvent",
            "IndigoHIDMessageForTrackpadMoveEvent",
            "IndigoHIDTargetForScreen",
            "IndigoHIDMessageToCreatePointerService",
        ]
        guard let handle = try? SimulatorPrivateRuntime.loadSimulatorKit() else {
            return Dictionary(uniqueKeysWithValues: names.map { ($0, false) })
        }
        return Dictionary(uniqueKeysWithValues: names.map {
            ($0, SimulatorPrivateRuntime.hasSymbol($0, in: handle))
        })
    }()

    private let messageForButton: MessageForButton
    private let messageForKeyboardArbitrary: MessageForKeyboardArbitrary
    private let messageForMouseNSEvent: MessageForMouseNSEvent

    // MARK: State

    private let device: AnyObject
    private let sendQueue = DispatchQueue(label: "com.synth.simulator.hid.send")
    /// `client` is written by `prepare()` off the main actor (the spawn costs ~1.2 s, so it cannot
    /// run on main), read by `deliver` on `sendQueue`, and cleared by `invalidate()` from whoever
    /// tears the pane down. Three threads on one strong reference is a double-release, and this
    /// process hosts the user's terminals — so every access goes through the lock.
    private let lock = NSLock()
    private var lockedClient: AnyObject?
    /// The last reason a send could not be made. Input is asynchronous — build on main, deliver on
    /// `sendQueue` — so a failure cannot be thrown from the call that caused it. It is recorded here
    /// and reported by the next caller, because "tapped" for a tap that never left the process is
    /// the one answer an agent cannot recover from: it re-reads the screen, sees no change, and taps
    /// again forever.
    private var lockedFailure: String?

    private var client: AnyObject? {
        get { lock.lock(); defer { lock.unlock() }; return lockedClient }
        set { lock.lock(); lockedClient = newValue; lock.unlock() }
    }

    /// The last send failure, cleared by reading it.
    func takeFailure() -> String? {
        lock.lock(); defer { lock.unlock() }
        let failure = lockedFailure
        lockedFailure = nil
        return failure
    }

    private func record(_ failure: String) {
        lock.lock(); lockedFailure = failure; lock.unlock()
    }

    /// Throws if input demonstrably is not reaching the device: no session, or a recorded failure
    /// from a send already in flight. Callers ask before claiming an action happened.
    func checkReady() throws {
        // PEEK, do not take. `takeFailure()` cleared the latch on the way out, so the very next verb
        // saw a clean slate and reported success — measured as three honest answers out of eight
        // against a device that had been shut down. A latched failure means input is not arriving
        // until something demonstrably fixes it, so it stays latched until a session is reopened.
        lock.lock()
        let failure = lockedFailure
        let have = lockedClient != nil
        lock.unlock()
        if let failure { throw SimulatorHIDFailure.sessionFailed(failure) }
        if have { return }
        _ = try openSession()
    }
    /// How long a `tap` holds the contact down. Long enough that UIKit sees a press rather than a
    /// same-frame down/up pair, short enough never to read as a long press.
    var tapDuration: TimeInterval = 0.03

    /// Resolves the builders and takes the device handle. The session itself is opened by
    /// `prepare()` so the ~1.2s spawn can be paid off the path that opens a pane.
    init(device: AnyObject) throws {
        let handle = try SimulatorPrivateRuntime.loadSimulatorKit()
        func resolve<Function>(_ name: String, as type: Function.Type) throws -> Function {
            do {
                return try SimulatorPrivateRuntime.symbol(
                    name, in: handle, framework: "SimulatorKit", as: type)
            } catch { throw SimulatorHIDFailure.builderUnavailable(name) }
        }
        self.device = device
        messageForButton = try resolve("IndigoHIDMessageForButton", as: MessageForButton.self)
        messageForKeyboardArbitrary = try resolve(
            "IndigoHIDMessageForKeyboardArbitrary", as: MessageForKeyboardArbitrary.self)
        messageForMouseNSEvent = try resolve(
            "IndigoHIDMessageForMouseNSEvent", as: MessageForMouseNSEvent.self)
    }

    convenience init(udid: String) throws {
        try self.init(device: try SimulatorPrivateRuntime.bootedDevice(udid: udid))
    }

    // MARK: Session

    /// Opens the HID session, or returns the one already open. Costs ~1.2s the first time.
    @discardableResult
    func openSession() throws -> AnyObject {
        if let client { return client }
        // The same testability seam the framebuffer and accessibility paths honour. It covers all
        // three deliberately: the failure this fallback exists for is an Xcode release moving the
        // private frameworks, which takes every one of them out at once — so a seam that only
        // disabled the screen would rehearse a scenario that does not happen.
        if ProcessInfo.processInfo.environment["SYNTH_SIM_FORCE_DEGRADED"] != nil {
            throw ForcedDegradation()
        }
        let candidates = [
            "SimulatorKit.SimDeviceLegacyHIDClient",  // SimulatorKit is Swift: the registered
            "SimDeviceLegacyHIDClient",               // name is mangled with its module.
            "CoreSimDeviceIO.SimDeviceLegacyHIDClient",
        ]
        guard let clientClass = SimulatorPrivateRuntime.lookUpClass(candidates) else {
            throw SimulatorHIDFailure.clientUnavailable(
                "none of \(candidates.joined(separator: ", ")) is registered")
        }
        guard let allocated = class_createInstance(clientClass, 0) as AnyObject? else {
            throw SimulatorHIDFailure.clientUnavailable("could not allocate \(clientClass)")
        }
        let selector = "initWithDevice:error:"
        guard allocated.responds(to: NSSelectorFromString(selector)) else {
            throw SimulatorHIDFailure.clientUnavailable("\(clientClass) has no -\(selector)")
        }
        var error: NSError?
        guard let initialised = unsafeBitCast(allocated, to: SimDeviceLegacyHIDClientMessaging.self)
            .initWithDevice(device, error: &error)
        else {
            throw SimulatorHIDFailure.sessionFailed(
                error?.localizedDescription ?? "-\(selector) returned nil")
        }
        client = initialised
        // A fresh session is the only evidence that whatever failed before has been fixed.
        lock.lock(); lockedFailure = nil; lock.unlock()
        return initialised
    }

    /// Drops the session. The next verb opens a fresh one.
    func invalidate() {
        client = nil
    }

    /// Asks the guest to reset its HID state — the recovery for a session that has gone deaf
    /// after the device was rebooted underneath us.
    func resetSession() {
        guard let client, client.responds(to: NSSelectorFromString("resetHIDSession")) else { return }
        unsafeBitCast(client, to: SimDeviceLegacyHIDClientMessaging.self).resetHIDSession()
    }

    // MARK: Touch

    /// A touch-down at a point normalised 0..1 from the top-left of the display.
    func touchDownNow(at point: CGPoint) { sendTouch(at: point, direction: .down) }

    /// A drag. Callers should coalesce these to one per frame; the guest reads a stream of
    /// touch-downs at moving positions as a drag on its own.
    func touchMoveNow(to point: CGPoint) { sendTouch(at: point, direction: .down) }

    func touchUpNow(at point: CGPoint) { sendTouch(at: point, direction: .up) }

    /// A tap: a contact held for `tapDuration` and released at the same point.
    func tapNow(at point: CGPoint) {
        touchDownNow(at: point)
        DispatchQueue.main.asyncAfter(deadline: .now() + tapDuration) { [weak self] in
            self?.touchUpNow(at: point)
        }
    }

    private func sendTouch(at point: CGPoint, direction: SimulatorInputDirection) {
        build("a touch \(direction == .down ? "down" : "up")") { [self] in
            touchMessage(at: point, direction: direction)
        }
    }

    // MARK: Buttons and keys

    func pressNow(_ button: SimulatorHardwareButton) {
        hold(button, duration: 0.05)
    }

    func hold(_ button: SimulatorHardwareButton, duration: TimeInterval) {
        send(button, direction: .down)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.send(button, direction: .up)
        }
    }

    func send(_ button: SimulatorHardwareButton, direction: SimulatorInputDirection) {
        build("the \(button.rawValue) button") { [self] in
            messageForButton(
                button.indigoEventSource, direction.rawValue, IndigoWire.hardwareButtonTarget)
                .map(Self.data(takingOwnershipOf:))
        }
    }

    /// A raw USB HID keyboard usage (page 7), which is the vocabulary the guest's keyboard service
    /// speaks — 0x04 is "a", 0x28 is Return, 0xE1 is left shift.
    func key(usage: UInt32, direction: SimulatorInputDirection) {
        build(String(format: "HID key usage 0x%02X", usage)) { [self] in
            messageForKeyboardArbitrary(Int32(bitPattern: usage), direction.rawValue)
                .map(Self.data(takingOwnershipOf:))
        }
    }

    /// Types text as keyboard usages, holding shift around the characters that need it. Throws for
    /// any character with no HID usage rather than silently dropping it — a half-typed string is a
    /// worse outcome than a refusal the caller can report.
    func typeNow(text: String) throws {
        var strokes: [(usage: UInt32, shifted: Bool)] = []
        for character in text {
            guard let stroke = SimulatorKeyboardUsage.stroke(for: character) else {
                throw SimulatorHIDFailure.unrepresentableText(String(character))
            }
            strokes.append(stroke)
        }
        for stroke in strokes {
            if stroke.shifted { key(usage: SimulatorKeyboardUsage.leftShift, direction: .down) }
            key(usage: stroke.usage, direction: .down)
            key(usage: stroke.usage, direction: .up)
            if stroke.shifted { key(usage: SimulatorKeyboardUsage.leftShift, direction: .up) }
        }
    }

    // MARK: Message construction

    /// SimulatorKit has no single-touch builder: `IndigoHIDMessageForMouseNSEvent` always emits a
    /// three-payload multi-touch message. So a valid digitizer contact is sourced from it and
    /// re-enveloped as a two-payload single-touch message, which is what the guest's digitizer
    /// service expects for one finger.
    private func touchMessage(at point: CGPoint, direction: SimulatorInputDirection) -> Data? {
        var ratio = point
        guard let source = messageForMouseNSEvent(
            &ratio, nil, IndigoWire.mouseTarget, direction.rawValue, ObjCBool(false))
        else { return nil }
        defer { free(source) }

        // The builder does not store the caller's coordinates; patch them into the contact.
        let sourceTouch = source.advanced(
            by: IndigoWire.firstPayloadOffset + IndigoWire.payloadEventOffset)
        writeUnaligned(Double(ratio.x), to: sourceTouch, offset: IndigoWire.touchXRatioOffset)
        writeUnaligned(Double(ratio.y), to: sourceTouch, offset: IndigoWire.touchYRatioOffset)

        guard let destination = calloc(1, IndigoWire.singleTouchMessageSize) else { return nil }
        writeUnaligned(
            UInt32(IndigoWire.payloadStride), to: destination, offset: IndigoWire.innerSizeOffset)
        writeUnaligned(
            IndigoWire.singleTouchEventType, to: destination, offset: IndigoWire.eventTypeOffset)
        writeUnaligned(
            IndigoWire.touchEventKind, to: destination,
            offset: IndigoWire.firstPayloadOffset + IndigoWire.payloadEventKindOffset)
        writeUnaligned(
            mach_absolute_time(), to: destination,
            offset: IndigoWire.firstPayloadOffset + IndigoWire.payloadTimestampOffset)

        // The digitizer contact itself, copied whole out of the builder's message.
        memcpy(
            destination.advanced(by: IndigoWire.firstPayloadOffset + IndigoWire.payloadEventOffset),
            sourceTouch, IndigoWire.touchSize)

        // Single-touch messages repeat the payload; the copy is marked (field1 = 1, field2 = 2).
        // This message is ours, so the second payload sits at the packed struct stride (0xB0), not
        // at SimulatorKit's wider 0xC0 wire offset.
        let secondPayloadOffset = IndigoWire.firstPayloadOffset + IndigoWire.payloadStride
        memcpy(
            destination.advanced(by: secondPayloadOffset),
            destination.advanced(by: IndigoWire.firstPayloadOffset), IndigoWire.payloadStride)
        let secondTouch = destination.advanced(
            by: secondPayloadOffset + IndigoWire.payloadEventOffset)
        writeUnaligned(UInt32(1), to: secondTouch, offset: IndigoWire.touchField1Offset)
        writeUnaligned(UInt32(2), to: secondTouch, offset: IndigoWire.touchField2Offset)

        return Data(
            bytesNoCopy: destination, count: IndigoWire.singleTouchMessageSize, deallocator: .free)
    }

    private static func data(takingOwnershipOf message: UnsafeMutableRawPointer) -> Data {
        Data(bytesNoCopy: message, count: malloc_size(message), deallocator: .free)
    }

    // MARK: Delivery

    /// Builds on the main thread and sends on the send queue. The Indigo builders read AppKit /
    /// NSEvent thread-local state, so they are built on the main thread; going through
    /// `DispatchQueue.main.async` unconditionally also keeps ordering FIFO no matter which thread
    /// a verb was called from, which matters because down / move / up only mean anything in order.
    private func build(_ what: String, _ make: @escaping () -> Data?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let data = make() else {
                // A builder that returns nil is a send that never happened, and dropping it silently
                // is the one answer an agent cannot recover from: the verb it called reported
                // success, so it re-reads an unchanged screen and tries again forever. Recorded like
                // any other send failure, so the next verb refuses and says this.
                record("SimulatorKit's Indigo builder produced no message for \(what) on this Xcode")
                return
            }
            sendQueue.async { self.deliver(data) }
        }
    }

    private func deliver(_ data: Data) {
        let client: AnyObject
        do { client = try openSession() } catch {
            record("\(error)")
            return
        }
        let selector = "sendWithMessage:freeWhenDone:completionQueue:completion:"
        guard client.responds(to: NSSelectorFromString(selector)) else {
            record("SimDeviceLegacyHIDClient has no -\(selector) in this Xcode")
            return
        }

        // The send is asynchronous and the client frees the buffer, so hand it a malloc'd copy
        // rather than the Data's own storage.
        let size = data.count
        guard let raw = malloc(size) else {
            record("could not allocate \(size) bytes for an Indigo message")
            return
        }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            raw.copyMemory(from: base, byteCount: size)
        }
        unsafeBitCast(client, to: SimDeviceLegacyHIDClientMessaging.self)
            .send(withMessage: raw, freeWhenDone: true, completionQueue: sendQueue) { [weak self] error in
                // The device can be shut down underneath a live session; the send is where we find
                // out. Recorded so the next verb refuses rather than reporting another success.
                if let error { self?.record("\(error)") }
            }
    }
}

// MARK: - Keyboard usages

/// USB HID keyboard usages (page 7) for printable ASCII, which is what
/// `IndigoHIDMessageForKeyboardArbitrary` takes.
enum SimulatorKeyboardUsage {
    static let leftShift: UInt32 = 0xE1
    static let returnKey: UInt32 = 0x28
    static let tab: UInt32 = 0x2B
    static let space: UInt32 = 0x2C
    static let deleteBackward: UInt32 = 0x2A
    static let escape: UInt32 = 0x29

    /// Unshifted punctuation, keyed by character.
    private static let punctuation: [Character: UInt32] = [
        "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31,
        ";": 0x33, "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38,
    ]

    /// Characters reached by holding shift, mapped to the key that produces them.
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
        "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
        ":": ";", "\"": "'", "~": "`", "<": ",", ">": ".", "?": "/",
    ]

    static let leftArrow: UInt32 = 0x50
    static let rightArrow: UInt32 = 0x4F
    static let upArrow: UInt32 = 0x52
    static let downArrow: UInt32 = 0x51

    static func stroke(for character: Character) -> (usage: UInt32, shifted: Bool)? {
        switch character {
        case "\n", "\r": return (returnKey, false)
        case "\t": return (tab, false)
        case " ": return (space, false)
        // Editing and navigation keys. AppKit hands these to us in `NSEvent.characters` the same
        // way it hands over letters, so a pane that forwards characters verbatim needs them here
        // or backspace silently does nothing — which is most of what typing on a device is.
        case "\u{7F}", "\u{8}": return (deleteBackward, false)
        case "\u{1B}": return (escape, false)
        case "\u{F700}": return (upArrow, false)
        case "\u{F701}": return (downArrow, false)
        case "\u{F702}": return (leftArrow, false)
        case "\u{F703}": return (rightArrow, false)
        default: break
        }
        if let ascii = character.asciiValue {
            switch ascii {
            case UInt8(ascii: "a")...UInt8(ascii: "z"):
                return (UInt32(0x04 + ascii - UInt8(ascii: "a")), false)
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                return (UInt32(0x04 + ascii - UInt8(ascii: "A")), true)
            case UInt8(ascii: "1")...UInt8(ascii: "9"):
                return (UInt32(0x1E + ascii - UInt8(ascii: "1")), false)
            case UInt8(ascii: "0"):
                return (0x27, false)
            default: break
            }
        }
        if let usage = punctuation[character] { return (usage, false) }
        if let base = shifted[character], let stroke = stroke(for: base) {
            return (stroke.usage, true)
        }
        return nil
    }
}
