import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The `simulator.*` control verbs: what the synth-simulator MCP server (mcp/simulator-server.mjs)
// calls, and why ADR-0015 routes EVERY simulator verb through here rather than giving the agent a
// channel of its own. The app already holds the warm Indigo session and the framebuffer, so a tool
// call taps the same device through the same source the user's pointer does — one surface, not two.
// Where a verb is genuinely `simctl` work (launch, openurl, install) the app shells out, for the
// same reason: the agent and the user are always talking about the same device.
//
// These run on the control connection's own thread, never on main (ControlServer routes them here
// before its main hop). That is not a micro-optimisation: a swipe paces itself in real time, a
// screenshot copies and encodes megabytes, and the `simctl` verbs spawn a process — each would park
// the UI for exactly as long as it took. Store access happens in short hops back to main.
enum SimulatorControl {

    static func handles(_ verb: String) -> Bool { verb.hasPrefix("simulator.") }

    static func handle(_ request: [String: Any], store: AppStore?) -> [String: Any] {
        // The Experimental toggle, enforced and not merely advertised. It used to gate only what a
        // user could start and which MCP servers were *registered*, which is discoverability: this
        // socket is reachable by any local process, and an agent session that was already running
        // when the toggle flipped keeps the tool list it was given. So `simulator.create` booted a
        // device with the experiment off. Refusing here, by name, is also the answer that lets such
        // an agent find out rather than silently succeeding at something the user disabled.
        if let refusal = gateRefusal(store) { return fail(refusal) }
        let verb = request["verb"] as? String ?? ""
        switch verb {
        case "simulator.devices": return devices()
        case "simulator.list":    return list(request, store)
        case "simulator.create":  return create(request, store)
        case "simulator.close":   return close(request, store)
        default: break
        }
        switch attachment(request, store) {
        case let .refused(error): return fail(error)
        case let .attached(target): return act(verb, request, target)
        }
    }

    /// Nil when simulator verbs are allowed; otherwise why not, in terms the caller can act on.
    private static func gateRefusal(_ store: AppStore?) -> String? {
        onMain {
            guard let store else { return "store gone" }
            guard !store.simulatorsAvailable else { return nil }
            guard store.simulatorSessionsEnabled else {
                return "simulator sessions are off: they are behind Synth's Experimental toggle "
                    + "(Settings → Experimental → Simulator sessions), which is off by default. Ask "
                    + "the user to turn it on — your tool list may predate them turning it off. "
                    + "Nothing was started."
            }
            return "no full Xcode is installed (or xcode-select / DEVELOPER_DIR points at the "
                + "Command Line Tools), so Synth cannot run simulators at all. Nothing was started."
        }
    }

    // MARK: - Discovery

    private static func devices() -> [String: Any] {
        let fleet = fleetDevices()
        return ["ok": true,
                "xcode": SimulatorDeviceCatalog.isXcodeAvailable,
                "devices": fleet.map {
                    ["udid": $0.udid, "name": $0.name, "runtime": $0.runtime, "booted": $0.isBooted]
                }]
    }

    private static func list(_ request: [String: Any], _ store: AppStore?) -> [String: Any] {
        let fleet = Dictionary(fleetDevices().map { ($0.udid.lowercased(), $0) },
                               uniquingKeysWith: { first, _ in first })
        return onMain {
            guard let store else { return fail("store gone") }
            guard let branch = branch(request, store) else { return noBranch(request) }
            let sessions = branch.sessions.filter { $0.kind == .simulator }.map { session -> [String: Any] in
                var entry: [String: Any] = ["sessionId": session.id.uuidString,
                                            "title": session.title,
                                            "branch": branch.name]
                guard let udid = session.simulatorUDID else {
                    // A device-less simulator row is a real state, not a broken one (ADR-0015).
                    entry["note"] = "no device yet — the user picks one in the pane"
                    return entry
                }
                entry["udid"] = udid
                // Recorded by the claim, which is the only place that knows: `simctl boot` failing
                // is otherwise invisible to everything downstream, which just sees "no display".
                if let failure = SimulatorClaims.bootFailure(for: udid) { entry["bootError"] = failure }
                if let device = fleet[udid.lowercased()] {
                    entry["device"] = device.name
                    entry["runtime"] = device.runtime
                    entry["booted"] = device.isBooted
                } else {
                    entry["note"] = "this UDID is not in the installed fleet — the device was deleted"
                }
                if let controller = SimulatorManager.shared.existing(session.id) {
                    entry["attached"] = controller.startFailure == nil
                    if controller.isAwaitingBoot { entry["booting"] = true }
                    if let failure = controller.startFailure { entry["error"] = failure }
                    if let degradation = controller.degradation { entry["degraded"] = degradation.summary }
                    let size = controller.source.displaySize
                    if size.width >= 1, size.height >= 1 {
                        entry["screen"] = ["width": safeInt(size.width), "height": safeInt(size.height)]
                    }
                    // What Synth last set, not what the device says — it says nothing (ADR-0015).
                    entry["orientation"] = controller.source.orientation.rawValue
                } else {
                    entry["attached"] = false
                }
                return entry
            }
            return ["ok": true, "xcode": SimulatorDeviceCatalog.isXcodeAvailable, "sessions": sessions]
        }
    }

    // MARK: - Lifecycle

    private static func create(_ request: [String: Any], _ store: AppStore?) -> [String: Any] {
        let fleet = fleetDevices()
        let requested = (request["device"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let device = pick(requested, from: fleet) else {
            guard !fleet.isEmpty else {
                return fail(SimulatorDeviceCatalog.isXcodeAvailable
                    ? "no simulator devices are installed — add one in Xcode's Devices & Simulators"
                    : "no full Xcode is installed (or xcode-select / DEVELOPER_DIR points at the "
                        + "Command Line Tools), so Synth cannot run simulators at all")
            }
            return fail("no installed device matches \(requested.map { "'\($0)'" } ?? "the request") "
                + "— simulator_devices lists what is installed")
        }
        return onMain {
            guard let store else { return fail("store gone") }
            guard let branch = branch(request, store) else { return noBranch(request) }
            // focus:false, like browser.create: an agent-created row announces itself with the
            // unread bullet instead of yanking the pane the user is working in.
            guard let session = store.newSimulator(in: branch, device: device, focus: false) else {
                return fail("session creation failed")
            }
            return ["ok": true,
                    "sessionId": session.id.uuidString,
                    "udid": device.udid,
                    "device": device.name,
                    "runtime": device.runtime,
                    "booted": device.isBooted]
        }
    }

    private static func close(_ request: [String: Any], _ store: AppStore?) -> [String: Any] {
        onMain {
            guard let store else { return fail("store gone") }
            guard let branch = branch(request, store) else { return noBranch(request) }
            guard let session = session(request, in: branch) else {
                return fail("no simulator session for sessionId — see simulator_list")
            }
            // No ownership gate, deliberately (ADR-0015): simulator sessions carry no
            // ownerSessionID because a device is machine-global state the user drives by hand, not
            // an agent's property. Closing a row is therefore always allowed, and safe — teardown
            // shuts the device down only if another row is not still holding it AND Synth is the one
            // that booted it. A device the user had running when this row attached outlives it.
            let udid = session.simulatorUDID
            let shared = udid.map { held in
                store.allSessions.contains { $0.id != session.id && $0.simulatorUDID == held }
            } ?? false
            let synthBooted = udid.map(SimulatorClaims.synthBooted) ?? false
            store.closeSession(session)
            var response: [String: Any] = ["ok": true, "deviceStaysBooted": shared || !synthBooted]
            if !shared, !synthBooted {
                response["note"] = "the device stays booted: Synth did not start it, so it is not "
                    + "Synth's to stop."
            }
            return response
        }
    }

    // MARK: - Acting on a device

    /// One session's device, and the live engine behind it. The engine is the pane's own controller
    /// rather than a second source: one framebuffer registration and one Indigo session per row, so
    /// the agent's tap and the pointer's tap are the same message on the same device.
    private enum Resolution {
        case attached(Attachment)
        case refused(String)
    }

    private struct Attachment {
        var udid: String
        var source: SimulatorDeviceSource?
        var startFailure: String?
        /// The device is still on its way up, so "not attached" is a stage and not a fault.
        var awaitingBoot: Bool
        var degradation: String?
    }

    private static func attachment(_ request: [String: Any],
                                   _ store: AppStore?) -> Resolution {
        onMain {
            guard let store else { return .refused("store gone") }
            guard let path = request["worktreePath"] as? String,
                  let branch = store.branch(forWorktreePath: path) else {
                return .refused(noBranchMessage(request))
            }
            guard let session = session(request, in: branch) else {
                return .refused("no simulator session for sessionId — see simulator_list")
            }
            guard let udid = session.simulatorUDID else {
                return .refused(
                    "simulator session \(session.id.uuidString) has no device yet: it was spawned "
                    + "from the worktree's session template, or restored before one was picked. The "
                    + "user picks a device in the pane — or make your own with simulator_create.")
            }
            var controller = SimulatorManager.shared.controller(for: session)
            // The manager tombstones a source that failed to start with the device already booted,
            // so a re-render doesn't retry in a tight loop. An agent call minutes later is not that
            // loop — give the verb one fresh attempt rather than answering "dead" forever.
            if controller == nil {
                SimulatorManager.shared.reset(session.id)
                controller = SimulatorManager.shared.controller(for: session)
            }
            return .attached(Attachment(udid: udid,
                                       source: controller?.source,
                                       startFailure: controller?.startFailure,
                                       awaitingBoot: controller?.isAwaitingBoot ?? false,
                                       degradation: controller?.degradation?.summary))
        }
    }

    private static func act(_ verb: String, _ request: [String: Any],
                            _ target: Attachment) -> [String: Any] {
        // `simctl` work first: installing or launching on a booted device has nothing to do with
        // whether we can see its screen, so these answer even when the framebuffer path is down.
        switch verb {
        case "simulator.launch":
            guard let bundleID = request["bundleId"] as? String, !bundleID.isEmpty else {
                return fail("need bundleId")
            }
            do {
                let output = try SimulatorDeviceCatalog.launch(
                    udid: target.udid, bundleIdentifier: bundleID,
                    arguments: request["args"] as? [String] ?? [])
                return ["ok": true, "output": output]
            } catch { return fail(describe(error)) }

        // Launching an app that is already running foregrounds it as-is, so an agent that wants a
        // known starting state needs a way to stop it first. Kept as its own verb rather than a
        // `relaunch` flag on launch, because "stop this app" is independently useful and because
        // terminate/launch is the pairing the converged tool vocabulary already uses.
        case "simulator.terminate":
            guard let bundleID = request["bundleId"] as? String, !bundleID.isEmpty else {
                return fail("need bundleId")
            }
            do {
                try SimulatorDeviceCatalog.terminate(udid: target.udid, bundleIdentifier: bundleID)
                return ["ok": true]
            } catch { return fail(describe(error)) }

        case "simulator.openUrl":
            guard let url = request["url"] as? String, !url.isEmpty else { return fail("need url") }
            do { try SimulatorDeviceCatalog.open(udid: target.udid, url: url) }
            catch { return fail(describe(error)) }
            return ["ok": true]

        case "simulator.install":
            guard let path = request["path"] as? String, !path.isEmpty else { return fail("need path") }
            guard FileManager.default.fileExists(atPath: path) else {
                return fail("nothing at \(path) — pass the built .app bundle's path")
            }
            do { try SimulatorDeviceCatalog.install(udid: target.udid, appPath: path) }
            catch { return fail(describe(error)) }
            return ["ok": true]

        default: break
        }

        guard let source = target.source, target.startFailure == nil else {
            guard !target.awaitingBoot else {
                // A device that will never boot is otherwise indistinguishable from a slow one for
                // the ninety seconds the pane keeps retrying.
                if let failure = SimulatorClaims.bootFailure(for: target.udid) {
                    return fail("device \(target.udid) did not boot: \(failure) Synth is still "
                        + "retrying the attach, but this will not fix itself — check the device in "
                        + "Xcode's Devices & Simulators, or pick another with simulator_create.")
                }
                return fail("device \(target.udid) is still booting — Synth is retrying the attach "
                    + "every second and a cold boot takes tens of seconds. Wait, then retry; "
                    + "simulator_list reports when it is attached.")
            }
            return fail("Synth is not attached to device \(target.udid): "
                + (target.startFailure ?? "its device is unavailable") + ".")
        }

        switch verb {
        case "simulator.tap":
            guard let point = point(request["x"], request["y"]) else { return fail(coordinateHelp) }
            // Reported, not assumed: an input verb that answers ok for a tap which never reached the
            // device sends an agent into a loop of re-reading an unchanged screen.
            do { try source.tap(at: point) } catch { return fail(describe(error)) }
            return ["ok": true]

        case "simulator.swipe":
            guard let from = point(request["fromX"], request["fromY"]),
                  let to = point(request["toX"], request["toY"]) else { return fail(coordinateHelp) }
            do {
                try swipe(source, from: from, to: to,
                          duration: safeDuration(number(request["durationMs"]) ?? 300,
                                                 default: 300, range: 16...10_000) / 1000)
            } catch { return fail(describe(error)) }
            return ["ok": true]

        case "simulator.type":
            guard let text = request["text"] as? String else { return fail("need text") }
            guard !text.isEmpty else { return fail("text is empty — nothing to type") }
            guard text.count <= maxTypeLength else {
                return fail("text is \(text.count) characters; \(maxTypeLength) is the limit for one "
                    + "simulator_type. Every character is two HID messages built on the main queue, "
                    + "so a long string stalls Synth's whole window — the request line alone can "
                    + "carry a quarter of a megabyte. Split it, or paste through the device instead.")
            }
            do { try type(text, into: source) } catch { return fail(describe(error)) }
            return ["ok": true, "characters": text.count]

        case "simulator.pressButton":
            guard let name = request["button"] as? String,
                  let button = SimulatorHardwareButton(lenient: name) else {
                return fail("button must be one of: "
                    + SimulatorHardwareButton.allCases.map(\.rawValue).joined(separator: ", ")
                    + ". Volume is absent because the legacy Indigo path cannot deliver it.")
            }
            do { try source.press(button) } catch { return fail(describe(error)) }
            return ["ok": true]

        // Rotation is a GSEvent through PurpleWorkspacePort, not an Indigo message — a different
        // mechanism from every other verb here (SimulatorOrientation). The orientation arrives as a
        // name and never as a number: this seam is reachable by any local process, and an unbounded
        // numeric argument crossing into a private call has already been a crash vector once.
        case "simulator.rotate":
            guard let name = request["orientation"] as? String,
                  let orientation = SimulatorOrientation(lenient: name) else {
                return fail("orientation must be one of: "
                    + SimulatorOrientation.allCases.map(\.rawValue).joined(separator: ", "))
            }
            do { try source.setOrientation(orientation) } catch { return fail(describe(error)) }
            return ["ok": true,
                    "orientation": orientation.rawValue,
                    "landscape": orientation.isLandscape,
                    // What this verb cannot prove, said rather than left to be discovered.
                    "note": "the device was told; whether the app turns is the app's decision — one "
                        + "that declares portrait-only stays portrait, and nothing outside it can "
                        + "tell. The screen's pixel size does not change either: iOS draws its "
                        + "rotated interface into the same framebuffer, so a screenshot comes back "
                        + "sideways at the portrait size and Synth's pane turns the picture upright."
                        + (orientation.isLandscape ? " " + landscapeCoordinateWarning : "")]

        case "simulator.shake":
            do { try source.shake() } catch { return fail(describe(error)) }
            return ["ok": true]

        case "simulator.screenshot":
            // Before copying pixels out: the surface survives the device, so a screenshot of a
            // shut-down simulator would otherwise come back ok with its last screen on it.
            do { try source.verifyDeviceAlive() } catch { return fail(describe(error)) }
            return screenshot(request, source, target)

        // The accessibility tree, via SimDevice's sendAccessibilityRequestAsync + AXPTranslator.
        // Beside the screenshot because it is the same "observe" rung on the same live device — and
        // it is the one an agent should reach for first, being three orders of magnitude cheaper.
        case "simulator.describe":
            return describe(request, source, target)

        default:
            return fail("unknown verb \(verb)")
        }
    }

    /// How much text one call may type. The bound is a main-queue budget, not a taste: each
    /// character is a keydown and a keyup, each built on the main queue (the Indigo builders read
    /// NSEvent thread-local state), and 20,000 characters was measured at a 0.3 s stall of the whole
    /// window — the user's terminals and agent panes with it. The socket's own 256 KB line cap put
    /// several seconds of that within reach of a single call.
    private static let maxTypeLength = 1_000
    /// Characters per batch. Bounded work handed to main, then a breath, so a long-but-legal string
    /// never queues more than a few hundred blocks at once. The wait is on the control connection's
    /// own thread, where blocking is free.
    private static let typeBatchLength = 50

    /// Types in paced batches. `SimulatorHID.type` throws on the first character with no HID usage
    /// before sending anything, so a batch either goes whole or is refused whole.
    private static func type(_ text: String, into source: SimulatorDeviceSource) throws {
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let batch = remaining.prefix(typeBatchLength)
            remaining = remaining.dropFirst(batch.count)
            try source.type(text: String(batch))
            if !remaining.isEmpty { usleep(20_000) }
        }
    }

    /// Paced in real time and interpolated, because the guest's own recogniser is what decides
    /// whether a stream of moving contacts was a swipe: iOS reads velocity off the gaps, so a
    /// down/up pair with a teleport between them is not a swipe at any distance. 60 positions a
    /// second is what a finger dragged across the pane produces.
    private static func swipe(_ source: SimulatorDeviceSource,
                              from: CGPoint, to: CGPoint, duration: Double) throws {
        let steps = max(2, safeInt(duration * 60, fallback: 2))
        let interval = useconds_t(max(0, safeInt(duration / Double(steps) * 1_000_000)))
        try source.touchDown(at: from)
        for step in 1...steps {
            usleep(interval)
            let progress = Double(step) / Double(steps)
            try source.touchMove(to: CGPoint(x: from.x + (to.x - from.x) * progress,
                                             y: from.y + (to.y - from.y) * progress))
        }
        try source.touchUp(at: to)
    }

    /// The accessibility tree, rendered flat. Text travels on the control socket where the
    /// screenshot travels via a file, and that difference IS the argument for this verb: a whole
    /// screen is a few hundred bytes here.
    ///
    /// `x`/`y` present means hit-test that one point instead of walking the tree, which is the
    /// answer for an element the walk cannot reach — SwiftUI tab bars and toolbars enumerate as
    /// childless containers, and their buttons only surface by being hit.
    private static func describe(_ request: [String: Any], _ source: SimulatorDeviceSource,
                                _ target: Attachment) -> [String: Any] {
        let hasPoint = request["x"] != nil || request["y"] != nil
        let hit = point(request["x"], request["y"])
        if hasPoint, hit == nil { return fail(coordinateHelp) }
        do {
            let tree = try hit.map { try source.describeAccessibility(at: $0) }
                ?? source.describeAccessibility()
            let text = tree.render()
            var response: [String: Any] = ["ok": true,
                                           "tree": text,
                                           "elements": tree.elements.count,
                                           "visited": tree.visitedCount,
                                           "bytes": text.utf8.count]
            if let degradation = target.degradation { response["degraded"] = degradation }
            if source.orientation.isLandscape {
                response["orientation"] = source.orientation.rawValue
                response["note"] = landscapeCoordinateWarning
            }
            return response
        } catch { return fail(describe(error)) }
    }

    /// The screen as a PNG on disk, which is how it reaches the MCP server — a megabyte of base64
    /// inside a JSON line on the control socket is the same bytes with a worse failure mode.
    private static func screenshot(_ request: [String: Any], _ source: SimulatorDeviceSource,
                                   _ target: Attachment) -> [String: Any] {
        guard let path = request["path"] as? String else { return fail("need path") }
        // Verified: the surface outlives the device, so an unverified capture returns the last screen
        // a dead device was showing and the reply calls it current.
        guard let frame = (try? source.captureVerifiedFrame()) ?? nil else {
            return fail("the device produced no frame to capture"
                + (target.degradation.map { " (\($0))" } ?? ""))
        }
        // Copy at capture, encode from the copy (ADR-0015). A SimulatorFrame *wraps* the device's
        // live IOSurface: retain it and encode later and the PNG shows whatever the guest has drawn
        // since, and two retained frames always compare byte-identical. `simctl io screenshot` is
        // the fallback for a pixel format we cannot read, not a preference — it costs a process
        // spawn and hundreds of milliseconds.
        var fallback: String?
        var png = frame.pngByCopyingPixels()
        if png == nil {
            fallback = "the framebuffer's pixel format is unreadable here, so this came from "
                + "`simctl io screenshot` instead"
            png = try? SimulatorDeviceCatalog.screenshotPNG(udid: target.udid)
        }
        guard let png else { return fail("the frame could not be encoded as a PNG") }
        do { try png.write(to: URL(fileURLWithPath: path)) }
        catch { return fail("could not write the screenshot to \(path): \(describe(error))") }
        var response: [String: Any] = ["ok": true, "path": path,
                                       "width": safeInt(frame.pixelSize.width),
                                       "height": safeInt(frame.pixelSize.height),
                                       "torn": frame.isTorn]
        if let degradation = target.degradation { response["degraded"] = degradation }
        if let fallback { response["fallback"] = fallback }
        if source.orientation.isLandscape {
            response["orientation"] = source.orientation.rawValue
            response["note"] = "the device is landscape, so this image is the framebuffer as iOS "
                + "drew it: the interface is turned a quarter within a portrait picture. "
                + landscapeCoordinateWarning
        }
        return response
    }

    // MARK: - Helpers

    private static func onMain<Value>(_ body: @MainActor () -> Value) -> Value {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    private static func fail(_ error: String) -> [String: Any] { ["ok": false, "error": error] }

    @MainActor private static func branch(_ request: [String: Any], _ store: AppStore) -> Branch? {
        guard let path = request["worktreePath"] as? String else { return nil }
        return store.branch(forWorktreePath: path)
    }

    private static func noBranch(_ request: [String: Any]) -> [String: Any] {
        fail(noBranchMessage(request))
    }

    private static func noBranchMessage(_ request: [String: Any]) -> String {
        "no Synth branch manages worktree \(request["worktreePath"] ?? "<missing>")"
    }

    @MainActor private static func session(_ request: [String: Any], in branch: Branch) -> Session? {
        guard let id = (request["sessionId"] as? String).flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        return branch.sessions.first { $0.id == id && $0.kind == .simulator }
    }

    /// The installed fleet. `Simulators.fleet` is a cache refreshed in the background because the
    /// device picker reads it while drawing, so early in a launch it reads empty — and telling an
    /// agent "no devices are installed" because we asked too soon is a lie it cannot see through.
    /// The catalog is asked directly in that case, on this thread, where the three `simctl` calls
    /// it costs are affordable.
    private static func fleetDevices() -> [SimulatorDevice] {
        let cached = onMain { Simulators.fleet.devices() }
        guard cached.isEmpty, SimulatorDeviceCatalog.isXcodeAvailable else { return cached }
        return ((try? SimulatorDeviceCatalog.devices()) ?? []).filter(\.isAvailable).map {
            SimulatorDevice(udid: $0.udid, name: $0.name, runtime: $0.runtimeName,
                            isBooted: $0.isBooted)
        }
    }

    /// UDID, then exact name, then prefix, then substring: an agent says "iPhone 16" and means
    /// whichever installed device is called that. Naming nothing takes a device that is already
    /// booted — joining the device the user is looking at is both free and the shared-surface
    /// answer — and otherwise the first iPhone, which is what "a simulator" means to most callers.
    private static func pick(_ requested: String?, from devices: [SimulatorDevice]) -> SimulatorDevice? {
        guard let requested, !requested.isEmpty else {
            return devices.first { $0.isBooted }
                ?? devices.first { $0.name.hasPrefix("iPhone") }
                ?? devices.first
        }
        let wanted = requested.lowercased()
        return devices.first { $0.udid.lowercased() == wanted }
            ?? devices.first { $0.name.lowercased() == wanted }
            ?? devices.first { $0.name.lowercased().hasPrefix(wanted) }
            ?? devices.first { $0.name.lowercased().contains(wanted) }
    }

    /// Coordinates are the display's own, and the display does not rotate. Said out loud on every
    /// answer that carries coordinates while a device is landscape, because the two halves of
    /// discovery → action disagree there: the accessibility tree reports the *interface's* geometry
    /// (which did turn) normalised against the device type's *portrait* point size (which did not),
    /// so on a 393×852pt iPhone a landscape element centre comes back as cx ≈ 1.93 — outside the
    /// 0..1 a tap accepts, which is at least a refusal rather than a tap 90° away.
    private static let landscapeCoordinateWarning =
        "While landscape, coordinates are NOT rotated for you: simulator_tap addresses the display, "
        + "which stays portrait, and simulator_describe reports the turned interface's own geometry "
        + "against the portrait point size — so its cx can exceed 1 and will be refused. Rotate back "
        + "to portrait before aiming taps from a described tree."

    private static let coordinateHelp =
        "coordinates are fractions of the screen from the TOP-LEFT, 0..1 — (0.5, 0.5) is the "
        + "centre. They are not pixels or points: divide a pixel position by the width and height "
        + "simulator_screenshot reported."

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    private static func point(_ x: Any?, _ y: Any?) -> CGPoint? {
        guard let x = number(x), let y = number(y),
              (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The engine's own failures say what moved and where through `CustomStringConvertible`, where
    /// their `localizedDescription` reads "The operation couldn't be completed."
    private static func describe(_ error: Error) -> String { String(describing: error) }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension SimulatorHardwareButton {
    /// An agent writes "side-button", "side_button" or "SIDE BUTTON" for what the enum spells
    /// `sideButton`, and being strict about that only costs it a round trip to find out.
    init?(lenient name: String) {
        let key = name.lowercased().filter(\.isLetter)
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == key })
        else { return nil }
        self = match
    }
}

extension SimulatorFrame {
    /// A PNG of this frame, encoded from pixels copied out of the surface *now*.
    ///
    /// The copy is the whole point (ADR-0015): the frame wraps the device's live IOSurface, so
    /// encoding a retained frame later renders whatever the guest has drawn since. Nil when the
    /// surface is in a pixel format we have no reader for, which is a real possibility worth
    /// answering honestly — formats and selectors have moved between Xcodes before.
    func pngByCopyingPixels() -> Data? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer)
        else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stride = width * 4
        var pixels = Data(count: stride * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let out = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(out.advanced(by: row * stride),
                       base.advanced(by: row * sourceStride), stride)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        let bitmapInfo: CGBitmapInfo = format == kCVPixelFormatType_32BGRA
            ? [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
            : [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}
