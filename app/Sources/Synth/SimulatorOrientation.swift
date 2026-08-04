import CoreGraphics
import Darwin.Mach
import Foundation
import ObjectiveC

// Rotation, and the two other verbs that travel the same way — the ones Indigo cannot carry.
//
// Orientation is NOT a HID event. Touches, keys and buttons are Indigo messages sent through
// SimulatorKit's HID client (SimulatorHID); a rotation is a **GSEvent**, a raw `mach_msg` addressed
// to the service the guest publishes as `PurpleWorkspacePort`, which lands in GraphicsServices and
// then in backboardd. Nothing about the two paths is shared, which is why this is its own file.
//
// The wire format below is not guesswork and not copied on trust: it was read out of Simulator.app's
// own `-[SimDevice(GSEvents) gsEventsSendOrientation:]` on this Xcode. That method zeroes a 112-byte
// buffer, writes a 24-byte header template, puts `50` at 0x18, `4` at 0x48 and the
// `UIDeviceOrientation` at 0x4C, then tail-calls `-[SimDevice(GSEventsPrivate) sendPurpleEvent:]`,
// which sets `msgh_size = (infoSize + 0x6B) & ~3` (= 108 for a 4-byte payload) and `mach_msg_send`s
// it. The header template in `__TEXT.__const` reads `bits 0x13, size 0x18, remote 0xFFFFFFFE,
// local 0, voucher 0, id 0x7B` — the `0xFFFFFFFE` being a sentinel that makes Apple's own sender
// look the port up. We look it up ourselves and write it in, which is the same message.
//
// Three facts that fell out of proving it on Xcode 16.4 / iOS 18.4, each of which changes the design:
//
//   * **The framebuffer does not rotate.** `displaySize` and the IOSurface stay 1179×2556 forever;
//     the guest draws its landscape interface *sideways into the portrait surface*. Presenting it
//     upright is the host's job — Simulator.app rotates its own `SimDisplayView` in exactly the same
//     breath as it sends this event. So does `SimulatorScreenView`.
//   * **There is no read-back.** `SimScreenProperties.uiOrientation` resolves and answers `0` whether
//     the guest is portrait or landscape, so the only thing anybody knows about a device's
//     orientation is what they last asked for. Write-only, and tracked as such.
//   * **Not every app rotates.** Settings on an iPhone stays portrait however many events it is sent;
//     Safari rotates immediately. A refusal by the app under test is invisible from here, which is
//     the one failure this verb cannot report.

// MARK: - Vocabulary

/// A device orientation, named and valued as `UIDeviceOrientation` — because the raw value is what
/// rides on the wire, and inventing a second numbering over the top of it would only mean one more
/// place to be wrong.
///
/// UIKit's landscape names are notoriously back-to-front (they name where the *home button* goes,
/// not where the picture's top goes), so each case says which physical edge ends up at the top.
enum SimulatorOrientation: String, CaseIterable, Sendable {
    case portrait
    case portraitUpsideDown
    /// Device turned anticlockwise: its right-hand edge is up.
    case landscapeLeft
    /// Device turned clockwise: its left-hand edge is up.
    case landscapeRight

    /// `UIDeviceOrientation`'s raw value, which is the 4 bytes at 0x4C of the GSEvent.
    var deviceOrientationValue: UInt32 {
        switch self {
        case .portrait: return 1
        case .portraitUpsideDown: return 2
        case .landscapeLeft: return 3
        case .landscapeRight: return 4
        }
    }

    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

    /// Quarter turns **clockwise** to apply to the framebuffer to present it upright. The guest
    /// renders its rotated interface into an unrotated surface, so this is the whole of what the
    /// pane has to do to the picture.
    var clockwiseQuarterTurns: Int {
        switch self {
        case .portrait: return 0
        case .landscapeRight: return 1
        case .portraitUpsideDown: return 2
        case .landscapeLeft: return 3
        }
    }

    /// Where one press of the pane's rotate control goes: landscape and back, never through upside
    /// down. Cycling all four would make "put it back" three clicks away from the state a developer
    /// is in nine times out of ten; upside down is reachable by name from the agent's verb.
    var toggled: SimulatorOrientation {
        isLandscape ? .portrait : .landscapeRight
    }

    /// A point in the upright picture (0..1 from its top-left — what the user clicked, what the app
    /// laid its interface out in, and what an agent means by a coordinate) mapped onto the display's
    /// own 0..1 space.
    ///
    /// The digitizer is bolted to the physical screen and never rotates, so Indigo always addresses
    /// the portrait surface. Getting this wrong does not look wrong — it taps a plausible place 90°
    /// away — which is why the self-check taps through it and asserts the screen answered.
    func displayPoint(fromUpright point: CGPoint) -> CGPoint {
        let (u, v) = (point.x, point.y)
        switch self {
        case .portrait: return CGPoint(x: u, y: v)
        case .portraitUpsideDown: return CGPoint(x: 1 - u, y: 1 - v)
        case .landscapeLeft: return CGPoint(x: 1 - v, y: u)
        case .landscapeRight: return CGPoint(x: v, y: 1 - u)
        }
    }

    /// The inverse of `displayPoint(fromUpright:)`: a point in the display's space back into the
    /// upright picture's. Used by `SimulatorInterfaceProjection` to ask which of the four ways an
    /// interface could be sitting on the display are even consistent with a hit test the guest has
    /// already answered — the display point is what was asked, and the interface frame is what came
    /// back.
    func uprightPoint(fromDisplay point: CGPoint) -> CGPoint {
        let (x, y) = (point.x, point.y)
        switch self {
        case .portrait: return CGPoint(x: x, y: y)
        case .portraitUpsideDown: return CGPoint(x: 1 - x, y: 1 - y)
        case .landscapeLeft: return CGPoint(x: y, y: 1 - x)
        case .landscapeRight: return CGPoint(x: 1 - y, y: x)
        }
    }

    /// An agent writes "landscape-left", "landscape_left" or "LANDSCAPE LEFT" for what the enum
    /// spells `landscapeLeft`, the same latitude `SimulatorHardwareButton` gives button names.
    init?(lenient name: String) {
        let key = name.lowercased().filter(\.isLetter)
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == key })
        else { return nil }
        self = match
    }
}

/// A Darwin notification the guest listens for. These are not HID and not GSEvents: they are
/// `notify_post` inside the simulator, delivered through `-[SimDevice postDarwinNotification:error:]`.
///
/// Only shake is here, and only because it was proved to arrive: `notifyutil -w` run inside the
/// guest saw it. The in-call status bar toggle (`com.apple.iphonesimulator.toggleincallstatusbar`)
/// posts just as successfully and changes nothing visible on a Dynamic Island device, so it is
/// deliberately not offered — a verb that reports success and does nothing is the one answer an
/// agent cannot recover from.
enum SimulatorDarwinNotification: String, Sendable {
    case shake = "com.apple.UIKit.SimulatorShake"
}

// MARK: - Failures

enum SimulatorOrientationFailure: Error, CustomStringConvertible {
    /// The whole capability is gone — no selector, or the degraded `simctl` path.
    case unavailable(String)
    case portUnavailable(udid: String, detail: String?)
    case sendTimedOut(port: UInt32, milliseconds: UInt32)
    case sendFailed(port: UInt32, code: Int32, detail: String)
    case notificationFailed(name: String, detail: String)

    var description: String {
        switch self {
        case let .unavailable(detail):
            return "Synth cannot rotate this device: \(detail)"
        case let .portUnavailable(udid, detail):
            return "Device \(udid) is not publishing a PurpleWorkspacePort, so there is nothing to "
                + "send a rotation to — it is usually still booting"
                + (detail.map { ": \($0)" } ?? ".")
        case let .sendTimedOut(port, milliseconds):
            return "The rotation was not accepted within \(milliseconds) ms — the guest's "
                + "PurpleWorkspacePort (\(port)) is not draining its queue. Nothing was sent."
        case let .sendFailed(port, code, detail):
            return "mach_msg to PurpleWorkspacePort \(port) failed (\(code)): \(detail)"
        case let .notificationFailed(name, detail):
            return "The device refused the Darwin notification \(name): \(detail)"
        }
    }
}

// MARK: - Runtime-only messaging surface

/// `SimDevice`'s bootstrap lookup and Darwin notification posting, messaged by name like everything
/// else that crosses this boundary.
///
/// `error:` is `NSErrorPointer` — that is `AutoreleasingUnsafeMutablePointer<NSError?>`, which is
/// the only shape matching ObjC's `NSError * __autoreleasing *`. A plain
/// `UnsafeMutablePointer<NSError?>` would have ARC release an error the autorelease pool also owns,
/// and the process would die at the next pool drain, far away from here.
@objc private protocol SimDeviceWorkspaceMessaging {
    @objc(lookup:error:)
    func lookup(_ name: String, error: NSErrorPointer) -> UInt32

    @objc(postDarwinNotification:error:)
    func postDarwinNotification(_ name: String, error: NSErrorPointer) -> Bool
}

// MARK: - Sender

/// The GSEvent / Darwin-notification channel for one device. Holds no session and no port: the
/// bootstrap lookup is a per-send XPC round trip because the port is only valid while the guest that
/// published it is alive, and a device rebooted underneath a cached port would take rotations that
/// silently went nowhere.
final class SimulatorPurpleEventSender {

    /// idb's convention, and the reason for it is worth keeping: a healthy send returns in single
    /// digit milliseconds, so this bound is not a latency budget — it is the ceiling on the wedge
    /// where the guest's receive queue is full. On `MACH_SEND_TIMED_OUT` the kernel guarantees the
    /// message was not enqueued, so a timeout is safe to report as "did not happen".
    static let sendTimeoutMilliseconds: mach_msg_timeout_t = 2000

    private static let lookupSelector = "lookup:error:"
    private static let notifySelector = "postDarwinNotification:error:"

    let udid: String
    private let device: AnyObject

    init(device: AnyObject, udid: String) throws {
        // The same testability seam the framebuffer, HID and accessibility paths honour: the failure
        // the `simctl` fallback exists for is an Xcode release moving the private frameworks, which
        // takes every one of them out at once.
        if ProcessInfo.processInfo.environment["SYNTH_SIM_FORCE_DEGRADED"] != nil {
            throw ForcedDegradation()
        }
        for selector in [Self.lookupSelector, Self.notifySelector] {
            guard device.responds(to: NSSelectorFromString(selector)) else {
                throw SimulatorRuntimeFailure.selectorUnavailable(
                    className: String(describing: type(of: device)), selector: selector)
            }
        }
        self.device = device
        self.udid = udid
    }

    convenience init(udid: String) throws {
        try self.init(device: try SimulatorPrivateRuntime.bootedDevice(udid: udid), udid: udid)
    }

    // MARK: Orientation

    /// Tells the guest its physical orientation changed. Throws when the message could not be
    /// delivered; it cannot tell whether the foreground app then honoured it, because iOS answers
    /// that only by drawing — an app declaring portrait-only stays portrait and says nothing.
    func setOrientation(_ orientation: SimulatorOrientation) throws {
        let port = try purpleWorkspacePort()
        var message = Self.machMessage(orientation: orientation, remotePort: port)
        let result: kern_return_t = message.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return KERN_FAILURE }
            let header = UnsafeMutableRawPointer(base)
                .assumingMemoryBound(to: mach_msg_header_t.self)
            return mach_msg(
                header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, header.pointee.msgh_size,
                0, mach_port_t(MACH_PORT_NULL), Self.sendTimeoutMilliseconds,
                mach_port_t(MACH_PORT_NULL))
        }
        switch result {
        case KERN_SUCCESS:
            return
        case MACH_SEND_TIMED_OUT:
            throw SimulatorOrientationFailure.sendTimedOut(
                port: port, milliseconds: Self.sendTimeoutMilliseconds)
        default:
            throw SimulatorOrientationFailure.sendFailed(
                port: port, code: result, detail: String(cString: mach_error_string(result)))
        }
    }

    /// The service the guest publishes for GSEvents. Looked up per send, never cached.
    private func purpleWorkspacePort() throws -> UInt32 {
        var error: NSError?
        let port = unsafeBitCast(device, to: SimDeviceWorkspaceMessaging.self)
            .lookup("PurpleWorkspacePort", error: &error)
        // 0 is "not published"; ~0 is `MACH_PORT_DEAD`. Apple's own sender rejects both, and sending
        // to either is how a rotation reports success and reaches nothing.
        guard port != 0, port != UInt32.max else {
            throw SimulatorOrientationFailure.portUnavailable(
                udid: udid, detail: error?.localizedDescription)
        }
        return port
    }

    /// The 112-byte GSEvent, built where it can be read. Deliberately a pure function over explicit
    /// wire offsets rather than a Swift struct: the record is packed, the header's own fields are
    /// 4-byte quantities in a struct Swift lays out differently, and `msgh_size` intentionally
    /// exceeds the meaningful bytes.
    static func machMessage(orientation: SimulatorOrientation, remotePort: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Wire.bufferSize)
        func write(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { source in
                for index in 0..<4 { bytes[offset + index] = source[index] }
            }
        }
        write(Wire.headerBits, at: Wire.bitsOffset)
        write(Wire.messageSize, at: Wire.sizeOffset)
        write(remotePort, at: Wire.remotePortOffset)
        write(Wire.gsEventMessageID, at: Wire.messageIDOffset)
        write(Wire.orientationChangedType | Wire.hostFlag, at: Wire.eventTypeOffset)
        write(4, at: Wire.recordInfoSizeOffset)
        write(orientation.deviceOrientationValue, at: Wire.recordInfoOffset)
        return bytes
    }

    /// Explicit wire offsets into a GSEvent mach message, as read out of
    /// `-[SimDevice(GSEvents) gsEventsSendOrientation:]`.
    private enum Wire {
        /// `mach_msg_header_t`.
        static let bitsOffset = 0x00
        static let sizeOffset = 0x04
        static let remotePortOffset = 0x08
        static let messageIDOffset = 0x14
        /// `GSEventRecord`.
        static let eventTypeOffset = 0x18
        static let recordInfoSizeOffset = 0x48
        static let recordInfoOffset = 0x4C

        /// `MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0)`.
        static let headerBits: UInt32 = 0x13
        static let gsEventMessageID: UInt32 = 0x7B
        /// `GSEventTypeDeviceOrientationChanged`.
        static let orientationChangedType: UInt32 = 50
        /// `GSEventHostFlag` — "this came from the host, not from hardware".
        static let hostFlag: UInt32 = 0x20000
        /// `(recordInfoSize + 0x6B) & ~3` for a 4-byte payload, which is what Apple's sender writes.
        /// Larger than the bytes anybody fills in; the receiver reads only the record.
        static let messageSize: UInt32 = 108
        /// Comfortably over `messageSize`. Apple's own sender hands `mach_msg` an 80-byte heap
        /// allocation and lets it read 108; a buffer that covers the whole declared size is the
        /// same message without the overread.
        static let bufferSize = 112
    }

    // MARK: Darwin notifications

    func post(_ notification: SimulatorDarwinNotification) throws {
        var error: NSError?
        let posted = unsafeBitCast(device, to: SimDeviceWorkspaceMessaging.self)
            .postDarwinNotification(notification.rawValue, error: &error)
        guard posted else {
            throw SimulatorOrientationFailure.notificationFailed(
                name: notification.rawValue,
                detail: error?.localizedDescription ?? "the device returned NO without an error")
        }
    }
}
