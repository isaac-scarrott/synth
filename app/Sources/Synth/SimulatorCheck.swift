import AppKit
import CoreGraphics
import CoreVideo

/// `Synth --simulator-check`: proves the simulator engine against a real device, the twin of
/// `BrowserCheck`. Compiling proves almost nothing here — every private selector either resolves
/// at runtime or silently returns nil — so this boots a device, asserts frames arrive off the
/// framebuffer, injects an Indigo tap, and asserts the screen actually responded.
///
/// The device comes from `SYNTH_SIM_CHECK_UDID` when set, so the check can be pointed at a device
/// nobody else is using; otherwise it takes the first available iPhone. It shuts down only a device
/// it booted itself, because simulator devices are global machine state someone else may be using.
@MainActor
enum SimulatorCheck {

    static func run() -> Never {
        var failures = 0
        func report(_ ok: Bool, _ name: String, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failures += 1 }
        }
        func finish() -> Never {
            print("SIMULATOR-CHECK RESULT: \(failures == 0 ? "PASS" : "FAIL")")
            exit(failures == 0 ? 0 : 1)
        }

        NSApplication.shared.setActivationPolicy(.accessory)

        report(SimulatorDeviceCatalog.isXcodeAvailable, "xcode-available")

        // `SYNTH_SIM_FORCE_DEGRADED` inverts what this check is proving: not that the live paths
        // work, but that losing them fails *well*. The fallback is part of the design (ADR-0015)
        // rather than a later rescue, and a fallback nobody exercises is a fallback that only gets
        // tested by the Xcode release which breaks the live path.
        let forced = ProcessInfo.processInfo.environment["SYNTH_SIM_FORCE_DEGRADED"] != nil
        if forced { print("INFO mode: forced degradation — asserting the fallback, not the live path") }

        // MARK: persistence, before anything touches a device
        //
        // `SessionKind.init?(rawValue:)` maps anything it does not recognise to an agent id, so a
        // missing case does not fail loudly — it decodes every persisted simulator as a bogus agent
        // on the next launch. Cheap to assert, and the single most fragile line in the feature.
        report(SessionKind(rawValue: "simulator") == .simulator, "kind-rawvalue-roundtrip")
        report(SessionKind.simulator.rawValue == "simulator", "kind-rawvalue-stable")
        do {
            let session = PersistedSession(
                id: UUID(), kind: SessionKind.simulator.rawValue, title: "iPhone 16",
                titleIsCustom: false, agentSessionID: nil, claudeSessionID: nil, browserURL: nil,
                ownerSessionID: nil, simulatorUDID: "ABC-123")
            let coded = try JSONEncoder().encode(session)
            let back = try JSONDecoder().decode(PersistedSession.self, from: coded)
            report(back.simulatorUDID == "ABC-123" && back.kind == "simulator",
                   "persist-roundtrip", "udid survives a snapshot")
            // A snapshot written before simulators existed must still decode: the field is additive,
            // which is why `schemaVersion` stays 1 rather than throwing the whole snapshot away.
            let legacy = Data(#"{"id":"\#(UUID().uuidString)","kind":"browser","title":"x","titleIsCustom":false}"#.utf8)
            let old = try JSONDecoder().decode(PersistedSession.self, from: legacy)
            report(old.simulatorUDID == nil, "persist-legacy-decodes",
                   "a pre-simulator snapshot still loads")
        } catch {
            report(false, "persist-roundtrip", "\(error)")
        }

        // MARK: claim bookkeeping, on a UDID no device has
        //
        // The rules that decide whether Synth may ever shut a device down, asserted without a
        // device: a claim survives while any row is interested, is given up exactly once when
        // none is, and the quit path sees every claim — including one with no pane behind it.
        do {
            let fake = "synth-check-claim-\(UUID().uuidString.lowercased())"
            SimulatorClaims.noteInterest(in: fake)
            SimulatorClaims.record(fake)
            report(SimulatorClaims.synthBooted(fake), "claim-recorded")
            report(SimulatorClaims.allBooted().contains(fake), "claim-listed-for-quit",
                   "as the caller's string, not the canonical key")
            report(!SimulatorClaims.abandonIfUnwanted(fake) && SimulatorClaims.synthBooted(fake),
                   "claim-kept-while-wanted")
            SimulatorClaims.dropInterest(in: fake)
            report(SimulatorClaims.abandonIfUnwanted(fake) && !SimulatorClaims.synthBooted(fake),
                   "claim-abandoned-when-unwanted")
            report(!SimulatorClaims.abandonIfUnwanted(fake) && !SimulatorClaims.forget(fake),
                   "claim-given-up-once")
            SimulatorClaims.markBootPending(fake)
            report(SimulatorClaims.isBootPending(fake), "boot-pending-marked")
            SimulatorClaims.clearBootPending(fake)
            report(!SimulatorClaims.isBootPending(fake), "boot-pending-cleared")
        }

        // MARK: pick a device

        let udid: String
        var bootedByUs = false
        do {
            let devices = try SimulatorDeviceCatalog.devices()
            report(!devices.isEmpty, "devices-listed", "\(devices.count) available")
            var picked: SimulatorDeviceInfo?
            if let id = ProcessInfo.processInfo.environment["SYNTH_SIM_CHECK_UDID"] {
                // Case-insensitively, and a miss is fatal. It used to fall through to "first iPhone
                // by newest runtime" — so a typo'd UDID silently retargeted the check at somebody
                // else's device and then shut it down.
                picked = devices.first(where: { $0.udid.caseInsensitiveCompare(id) == .orderedSame })
                if picked == nil {
                    report(false, "device-chosen",
                           "SYNTH_SIM_CHECK_UDID=\(id) matches no installed device — refusing to "
                           + "pick a different one, which could shut down a device you are using")
                    finish()
                }
            }
            if picked == nil { picked = devices.first(where: { $0.name.hasPrefix("iPhone") }) }
            if picked == nil { picked = devices.first }
            guard let chosen = picked else {
                report(false, "device-chosen", "no simulator devices installed")
                finish()
            }
            udid = chosen.udid
            report(true, "device-chosen", "\(chosen.name) \(chosen.udid)")

            if chosen.state != .booted {
                // From the boot's own outcome, never from the state read before it. `.alreadyRunning`
                // comes back for a device that was `.booting` or that won a concurrent boot race —
                // so trusting the read meant the check could shut down a device somebody else had
                // just started. That is the finding an earlier round fixed in the app and this file
                // then reintroduced; `SimulatorBootOutcome` exists for exactly this.
                bootedByUs = try SimulatorDeviceCatalog.boot(udid: udid) == .booted
                try SimulatorDeviceCatalog.waitUntilBooted(udid: udid)
            }
            report(true, "device-booted", bootedByUs ? "booted by check" : "already booted")
        } catch {
            report(false, "device-booted", "\(error)")
            finish()
        }

        func cleanUp() {
            if bootedByUs { try? SimulatorDeviceCatalog.shutdown(udid: udid) }
        }

        // MARK: start the source

        let source = SimulatorDeviceSource(udid: udid)
        var frames: [SimulatorFrame] = []
        let framesLock = NSLock()
        source.callbackQueue = .main
        source.onFrame = { frame in
            framesLock.lock(); frames.append(frame); framesLock.unlock()
        }
        do {
            try source.start()
        } catch {
            report(false, "source-started", "\(error)")
            cleanUp()
            finish()
        }
        report(true, "source-started")

        // Opening the Indigo session costs over a second, so it happens asynchronously and
        // `degradation` immediately after `start()` is not yet the whole picture — a lost input path
        // reads as healthy for a moment. The pane copes by watching `onDegradationChange`; a
        // synchronous reader has to wait, or it asserts against a half-built answer.
        let settleBy = Date().addingTimeInterval(3)
        while Date() < settleBy, source.degradation?.affectsInput != true {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        // A degraded source is not a failure of the check — it is the designed fallback — but it
        // IS a failure of the live path, which is the thing being proven here. Under forced
        // degradation the expectation flips: it must degrade, and say what it lost and what it
        // fell back to, because a pane quietly showing a stale screenshot at 2fps is worse than
        // one that admits it.
        if forced {
            guard let degradation = source.degradation else {
                report(false, "degraded-reported", "forced, but the source reports full fidelity")
                source.stop(); cleanUp(); finish()
            }
            report(degradation.affectsScreen, "degraded-screen-declared")
            report(degradation.affectsInput, "degraded-input-declared")
            report(degradation.affectsAccessibility, "degraded-accessibility-declared")
            report(degradation.affectsOrientation, "degraded-orientation-declared")
            let stated = degradation.reasons.allSatisfy {
                !$0.detail.isEmpty && !$0.fallback.isEmpty
            }
            report(stated, "degraded-explains-itself", degradation.summary)
        } else if let degradation = source.degradation {
            report(!degradation.affectsScreen, "screen-path-resolved", degradation.summary)
            report(!degradation.affectsInput, "input-path-resolved", degradation.summary)
            report(!degradation.affectsAccessibility, "accessibility-path-resolved", degradation.summary)
            report(!degradation.affectsOrientation, "orientation-path-resolved", degradation.summary)
        } else {
            // Renamed from `*-live`: all four are the `else` branch of "the source reported no
            // degradation", i.e. every private path RESOLVED at start. That is worth asserting and it
            // is not the same as working — frames arriving, a tap landing, a tree round-tripping and
            // a device turning are each asserted by name below. An independent review counted the
            // old names as evidence they were not.
            report(true, "screen-path-resolved")
            report(true, "input-path-resolved")
            report(true, "accessibility-path-resolved")
            report(true, "orientation-path-resolved")
        }

        let size = source.displaySize
        report(size.width > 1 && size.height > 1, "display-size",
               "\(safeInt(size.width))x\(safeInt(size.height))")

        // Informational, not a pass/fail. The source probes several spellings per capability
        // because they move between Xcodes — on 16.4 the live names are `framebufferSurface` and
        // `registerCallbackWithUUID:ioSurfacesChangeCallback:` (plural), so the singular variants
        // are *expected* to be absent. Whether the live path works is `screen-live`'s job; this
        // line only says which spelling answered, which is the first thing worth knowing when a
        // new Xcode moves something.
        let selectors = source.screenDiagnostics
        if !selectors.isEmpty {
            let resolved = selectors.filter { $0.value }.keys.sorted()
            let absent = selectors.filter { !$0.value }.keys.sorted()
            print("INFO display-selectors: resolved [\(resolved.joined(separator: ", "))]"
                + (absent.isEmpty ? "" : " absent [\(absent.joined(separator: ", "))]"))
        }

        // Drain the runloop for a bounded wall-clock window. The check is on the main actor and
        // frames are delivered to it, so it cannot simply sleep.
        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }

        func frameCount() -> Int { framesLock.lock(); defer { framesLock.unlock() }; return frames.count }
        func latestFrame() -> SimulatorFrame? {
            framesLock.lock(); defer { framesLock.unlock() }; return frames.last
        }

        report(source.captureCurrentFrame() != nil, "capture-on-demand")

        // MARK: frames arrive

        // Settings is a deterministic start state that also guarantees the screen changes — but
        // only from cold: `simctl launch` on an app that is already running foregrounds it without
        // resetting it, so a previous run's navigation would still be on screen.
        try? SimulatorDeviceCatalog.terminate(udid: udid, bundleIdentifier: "com.apple.Preferences")
        do { try source.launch(bundleIdentifier: "com.apple.Preferences") }
        catch { report(false, "launch-app", "\(error)") }
        pump(4)
        report(frameCount() > 0, "frames-delivered", "\(frameCount()) frames while launching Settings")

        // MARK: the fallback, when it is the thing under test
        //
        // Under forced degradation the live-path assertions below cannot pass and should not be
        // attempted: what matters is that the screen still shows *something* via `simctl` polling
        // (asserted above — the same `frames-delivered` and `capture-on-demand` lines), and that the
        // capabilities which have no fallback refuse out loud instead of returning empty successes.
        if forced {
            do {
                let tree = try source.describeAccessibility()
                report(false, "degraded-ax-refuses",
                       "returned \(tree.elements.count) elements instead of refusing — an empty or "
                       + "partial tree reads as 'the screen has nothing on it'")
            } catch {
                report(true, "degraded-ax-refuses", "\(error)")
            }
            do {
                try source.type(text: "x")
                report(false, "degraded-typing-refuses", "accepted text with no HID session")
            } catch {
                report(true, "degraded-typing-refuses", "\(error)")
            }
            // Rotation has no fallback either, and less than accessibility does: `simctl` has no
            // orientation verb at any version and `devicectl device orientation set` needs Xcode 27.
            // A silent no-op here would leave an agent rotating forever at a screen that never turns.
            do {
                try source.setOrientation(.landscapeRight)
                report(false, "degraded-rotate-refuses", "accepted a rotation with no GSEvent channel")
            } catch {
                report(true, "degraded-rotate-refuses", "\(error)")
            }
            report(source.orientation == .portrait, "degraded-rotate-leaves-orientation-alone",
                   "reports \(source.orientation.rawValue) after a refused rotation")
            report(true, "frame-stats", source.frameStatistics.summary)
            source.stop()
            report(true, "source-stopped")
            cleanUp()
            finish()
        }

        // MARK: the accessibility tree

        // Settings' root is the deterministic state for this: a known set of labelled rows at known
        // places. Everything after it re-launches Settings to put that state back, because the
        // coordinate round-trip below deliberately navigates away from it.
        do {
            let tree = try source.describeAccessibility()
            let bytes = tree.byteCount
            report(!tree.elements.isEmpty, "ax-tree-nonempty",
                   "\(tree.elements.count) of \(tree.visitedCount) elements, \(bytes) bytes, "
                   + "app \(tree.application ?? "?")")

            // The token argument, measured rather than asserted. Both are the same screen.
            if let frame = source.captureCurrentFrame(), let png = frame.pngByCopyingPixels() {
                report(true, "ax-vs-screenshot",
                       String(format: "tree %d B vs screenshot %d B — %.0f× cheaper",
                              bytes, png.count, Double(png.count) / Double(max(bytes, 1))))
            }
            print("INFO ax-tree:\n" + tree.render())

            if let row = tree.firstElement(labelContaining: "General") {
                report(true, "ax-expected-label", row.line)

                // The point hit test is a different request kind, not a search of the tree above,
                // and it is what reaches elements the walk cannot. Asked at the centre the walk
                // reported, it has to come back with the element that reported it.
                let hit = try source.describeAccessibility(at: row.centre)
                let hitLabel = hit.elements.first?.label
                report(hitLabel?.range(of: "General", options: .caseInsensitive) != nil,
                       "ax-hit-test",
                       "hit \(hitLabel ?? "nothing") at "
                       + String(format: "(%.3f, %.3f)", row.centre.x, row.centre.y))

                // The coordinates round-trip: tap where describe said the element's centre was, and
                // the screen the tree describes has to change. This is the whole contract between
                // the two verbs — a frame projected wrongly still produces a plausible tree.
                let before = Set(tree.elements.compactMap(\.label))
                try source.tap(at: row.centre)
                pump(2.5)
                let after = try source.describeAccessibility()
                let afterLabels = Set(after.elements.compactMap(\.label))
                let surviving = before.isEmpty ? 1.0
                    : Double(before.intersection(afterLabels).count) / Double(before.count)
                report(surviving < 0.5, "ax-tap-at-reported-centre",
                       String(format: "%.0f%% of the previous labels remain; now showing %@",
                              surviving * 100,
                              after.elements.prefix(3).compactMap(\.label).joined(separator: ", ")))
            } else {
                report(false, "ax-expected-label",
                       "no element labelled General in Settings' root — the tree read as: "
                       + tree.elements.prefix(6).map(\.line).joined(separator: " / "))
            }
        } catch {
            report(false, "ax-describe", "\(error)")
        }

        // Put Settings' root back for the input checks below, which aim at a fixed coordinate.
        try? SimulatorDeviceCatalog.terminate(udid: udid, bundleIdentifier: "com.apple.Preferences")
        try? source.launch(bundleIdentifier: "com.apple.Preferences")
        pump(3)

        // MARK: scrolling
        //
        // The pane turns trackpad scrolling into a touch drag, because the guest's own recogniser is
        // what decides whether moving contacts were a swipe. That translation — the began/changed/
        // ended phase mapping and the sign of each delta — cannot be reached through the automation
        // seam, so it is exercised here against the real view: synthesise the events AppKit would
        // deliver and assert the guest actually scrolled. Getting the y sign backwards is invisible
        // in review and obvious in use.
        do {
            let view = SimulatorScreenView()
            view.source = source
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 800)

            /// The scroll event AppKit would hand the view. Phase has to be set on the CGEvent —
            /// `NSEvent.phase` is derived from it, and a phaseless event is a legacy wheel.
            func scroll(dy: Int64, phase: Int64) -> NSEvent? {
                guard let src = CGEventSource(stateID: .privateState),
                      let cg = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                                       wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)
                else { return nil }
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                // `hasPreciseScrollingDeltas` comes from this, and without it AppKit reports line
                // deltas instead of the pixel deltas the pane divides by its bounds.
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
                // Double, not Integer: this field is 16.16 fixed point, so writing the raw bits of
                // -60 asks for -0.0009 of a pixel.
                cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
                // `CGEvent.location` is top-left origin in screen points and `NSEvent` flips it by
                // the main screen's height, so setting 400 here landed the finger at y=717 in the
                // view — up in the navigation bar, where a drag correctly scrolls nothing.
                let flip = NSScreen.main?.frame.height ?? 1117
                cg.location = CGPoint(x: 200, y: flip - 400)
                return NSEvent(cgEvent: cg)
            }

            let firstRow = (try? source.describeAccessibility())
                .flatMap { $0.firstElement(labelContaining: "Privacy") }
            guard let events = [scroll(dy: 0, phase: 1)]      // began
                    + Array(repeating: scroll(dy: -60, phase: 2), count: 6)  // changed, finger up
                    + [scroll(dy: 0, phase: 4)] as [NSEvent?]?,             // ended
                  events.allSatisfy({ $0 != nil })
            else {
                report(false, "scroll-events-built", "could not synthesise a scroll event")
                throw ForcedDegradation()
            }
            report(true, "scroll-events-built")
            if let probe = scroll(dy: -60, phase: 2) {
                print(String(format:
                    "INFO scroll-event: phase=%lu momentum=%lu precise=%@ dy=%.2f loc=(%.0f,%.0f)",
                    probe.phase.rawValue, probe.momentumPhase.rawValue,
                    probe.hasPreciseScrollingDeltas ? "yes" : "no",
                    probe.scrollingDeltaY, probe.locationInWindow.x, probe.locationInWindow.y))
            }
            for event in events.compactMap({ $0 }) {
                view.scrollWheel(with: event)
                pump(0.05)
            }
            pump(2)

            // Scrolling a list moves its rows up: the same element's centre must sit higher than it
            // did. Comparing one known row rather than the label set, because a long list keeps most
            // of its labels through a short scroll.
            if let firstRow, let moved = (try? source.describeAccessibility())
                .flatMap({ $0.firstElement(labelContaining: "Privacy") }) {
                let delta = firstRow.centre.y - moved.centre.y
                report(delta > 0.02, "scroll-moved-content",
                       String(format: "Privacy & Security moved %.3f up the screen (%.3f → %.3f)",
                              delta, firstRow.centre.y, moved.centre.y))
            } else {
                report(false, "scroll-moved-content", "could not find a row to measure before/after")
            }
        } catch {
            // ForcedDegradation is only thrown above to skip the rest of this block.
        }

        // MARK: input reaches the device, and how fast

        // Settings' root goes back again, for the reason it went back before the scroll: the check
        // below aims at a FIXED coordinate, and a scrolled list makes that coordinate mean whatever
        // the guest's deceleration happened to settle on. Measured, that is the difference between
        // tapping the Apple Account row — a sheet that starts drawing in 59 ms — and tapping into
        // Settings > Search, whose pane takes about four seconds to first paint on this runtime, and
        // then the latency assertion is reporting the pane's cold start rather than input latency.
        try? SimulatorDeviceCatalog.terminate(udid: udid, bundleIdentifier: "com.apple.Preferences")
        try? source.launch(bundleIdentifier: "com.apple.Preferences")
        pump(3)  // and settle, so the next change on screen is ours
        guard let before = source.captureCurrentFrame() else {
            report(false, "frame-before-tap")
            source.stop(); cleanUp(); finish()
        }
        let baselineSeed = before.seed
        // Sample NOW, not later. A `SimulatorFrame` wraps the device's live IOSurface rather than
        // copying it, so two frames captured at different times share one buffer and always
        // compare equal. Anything that needs a still — this check, and the MCP server's
        // screenshot verb — has to take its own copy at capture time.
        let beforeSample = sample(before)
        framesLock.lock(); frames.removeAll(); framesLock.unlock()

        // Mid-upper list area: the first row of Settings' root, which pushes a detail view.
        let sentAt = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        try? source.tap(at: CGPoint(x: 0.5, y: 0.28))

        var changedAt: UInt64?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, changedAt == nil {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
            if let frame = latestFrame(), frame.seed != baselineSeed { changedAt = frame.producedAt }
        }
        report(changedAt != nil, "tap-produced-a-new-frame",
               changedAt == nil ? "no new frame within 5s of the tap" : "")
        if let changedAt {
            let ms = Double(changedAt - sentAt) / 1_000_000
            report(ms < 500, "input-latency", String(format: "%.1f ms tap -> first changed frame", ms))
        }

        // The tap should have navigated, not just ticked the clock: a detail view differs over a
        // large share of the screen, where a clock tick differs over a sliver of the status bar.
        pump(1.5)
        if let after = source.captureCurrentFrame() {
            let changed = changedFraction(beforeSample, sample(after))
            report(changed > 0.05, "tap-navigated",
                   String(format: "%.1f%% of the screen differs", changed * 100))
        } else {
            report(false, "tap-navigated", "no frame after tap")
        }

        /// The contract between `describe` and `tap`, asserted the only two ways it can be.
        ///
        ///   * The accessibility server's own hit test at the centre `describe` reported has to come
        ///     back with the element that reported it.
        ///   * A **tap** at that centre has to produce the consequence that element, and only that
        ///     element, has. The tap is the half that matters: it travels through Indigo and the
        ///     digitizer, which know nothing about the accessibility tree and so cannot agree with a
        ///     wrong projection by construction.
        ///
        /// "The screen changed" is deliberately not the assertion. A tap a quarter turn out changes
        /// the screen too — by hitting something else — which is how the first attempt at this shipped
        /// a silent miss. So what is asserted is a *named* consequence, absent before and present
        /// after: an element whose label or identifier only that tap can put on screen.
        @discardableResult
        func assertRoundTrip(
            _ name: String, aimingAt wanted: String, expecting consequence: String
        ) -> SimulatorAccessibilityElement? {
            func onScreen(_ tree: SimulatorAccessibilityTree) -> Bool {
                tree.elements.contains { $0.label == consequence || $0.identifier == consequence }
            }
            do {
                let tree = try source.describeAccessibility()
                if let caveat = tree.geometryCaveat { print("INFO \(name)-caveat: \(caveat)") }
                guard let target = tree.firstElement(labelContaining: wanted) else {
                    report(false, "\(name)-target", "nothing labelled \(wanted) on screen — "
                           + tree.elements.prefix(8).map(\.line).joined(separator: " / "))
                    return nil
                }
                report(true, "\(name)-target", "\(tree.application ?? "?") · \(target.line)")
                report(!onScreen(tree), "\(name)-consequence-absent-first",
                       "\(consequence) must not already be on screen, or the tap below proves nothing")

                let hit = try source.describeAccessibility(at: target.centre)
                let back = hit.elements.first { $0.label == target.label }
                let drift = back.map {
                    hypot($0.centre.x - target.centre.x, $0.centre.y - target.centre.y)
                }
                report(drift ?? 1 < 0.02, "\(name)-hit-test-resolves-same-element",
                       back == nil
                           ? "a hit test at the reported centre came back with "
                               + (hit.elements.prefix(3).map(\.line).joined(separator: " / "))
                           : String(format: "%@ back at (%.3f, %.3f), %.4f off",
                                    back?.label ?? "?", back?.centre.x ?? 0, back?.centre.y ?? 0,
                                    drift ?? 1))

                let before = source.captureCurrentFrame().map(sample)
                try source.tap(at: target.centre)
                var landed = false
                let deadline = Date().addingTimeInterval(6)
                while Date() < deadline, !landed {
                    pump(0.5)
                    landed = (try? source.describeAccessibility()).map(onScreen) ?? false
                }
                report(landed, "\(name)-tap-at-reported-centre-lands",
                       String(format: "tapped %@ at (%.3f, %.3f) and %@",
                              target.label ?? "?", target.centre.x, target.centre.y,
                              landed ? "\(consequence) appeared"
                                  : "\(consequence) never did — the tap did not land on \(wanted)"))
                if let before, let after = source.captureCurrentFrame() {
                    let changed = changedFraction(before, sample(after))
                    report(changed > 0.02, "\(name)-tap-changed-screen",
                           String(format: "%.1f%% of the framebuffer differs", changed * 100))
                }
                return target
            } catch {
                report(false, name, "\(error)")
                return nil
            }
        }

        /// The mixed-space case, which is the one arithmetic alone gets wrong. With the keyboard up in
        /// landscape the app's own elements come back in the interface's coordinate space and every key
        /// comes back in the display's, unrotated, as flat siblings of them — so one projection over the
        /// whole tree is wrong for one group or the other whichever way it is chosen. Tapping a key at
        /// its reported centre types that character, and nothing else on this screen can put it in the
        /// address field, so this is the assertion that a per-element space was picked correctly.
        func assertLandscapeKeyboard() {
            do {
                let tree = try source.describeAccessibility()
                if let caveat = tree.geometryCaveat {
                    print("INFO landscape-keyboard-caveat: \(caveat)")
                }
                guard let key = tree.elements.first(where: { $0.label == "x" }) else {
                    // Not a failure: whether the software keyboard's keys reach the accessibility
                    // tree at all varies by device — measured present on iPhone 16, absent on
                    // iPhone 16 Pro on the same iOS. This assertion exists to cover the screen that
                    // mixes two coordinate spaces, so with no keyboard enumerated there is nothing
                    // to cover, and failing here would report a device difference as a defect. The
                    // projection's own proof is `rotate-ax-landscape-*`, which does not depend on it.
                    // A FAILURE, not an INFO. The two-coordinate-spaces-at-once path is the most
                    // intricate code in the feature, and a PASS that quietly meant "not run" is
                    // exactly the kind of assertion this check has already been caught writing.
                    // Whether the software keyboard reaches the accessibility tree varies by device —
                    // measured present on iPhone 16, absent on iPhone 16 Pro and Pro Max — so run the
                    // check on a device that can exercise it before believing this feature is covered.
                    report(false, "landscape-keyboard-key",
                           "no software keyboard in the tree, so the mixed-space case was NOT "
                           + "exercised. This is per-device state, not a model or runtime rule — "
                           + "measured present on one iPhone 16 / iOS 18.4 and absent on an iPhone 16 "
                           + "Pro on the same runtime AND on another iPhone 16 on 18.6, which points "
                           + "at whether that device presents a software keyboard at all (the "
                           + "hardware-keyboard setting is per-device and persisted). Run the check "
                           + "on a device whose keyboard shows, or this feature's most intricate path "
                           + "has no coverage. Frontmost shows: "
                           + tree.elements.prefix(4).map(\.line).joined(separator: " / "))
                    return
                }
                report(true, "landscape-keyboard-key", key.line)
                try source.tap(at: key.centre)
                var typed = false
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, !typed {
                    pump(0.5)
                    typed = (try? source.describeAccessibility())?
                        .elements.contains { $0.value == "x" } ?? false
                }
                report(typed, "landscape-keyboard-tap-types",
                       String(format: "tapped the x key at (%.3f, %.3f) and the field %@",
                              key.centre.x, key.centre.y,
                              typed ? "reads x" : "never read x — the tap missed the key"))
            } catch {
                report(false, "landscape-keyboard", "\(error)")
            }
        }

        // MARK: rotation
        //
        // The one verb whose effect is invisible in every number the framebuffer reports: rotating a
        // device does NOT change `displaySize` or the IOSurface — the guest draws its landscape
        // interface sideways into the same portrait surface, and turning the picture upright is the
        // host's job. So this proves the rotation the only way it can be proved from here: the whole
        // screen redraws when the device turns, and comes back to what it was when it turns back.
        //
        // Safari, not Settings. Settings on an iPhone declares portrait-only and stays portrait
        // however many orientation events it is sent — which is the guest's decision to make and the
        // one thing this verb cannot report — so checking rotation against it would assert that a
        // working mechanism is broken.
        do {
            try source.open(url: "https://example.com")
            pump(4)
            // Start from upright whatever the device was doing when the check found it. Devices are
            // machine-global state and a previous run — or the user — can leave one rotated, which
            // turns "rotating redrew the screen" into an assertion about a no-op.
            try source.setOrientation(.portrait)
            pump(3)
            guard let upright = source.captureCurrentFrame() else {
                report(false, "rotate-frame-before", "no frame to compare against")
                throw ForcedDegradation()
            }
            let uprightSample = sample(upright)

            try source.setOrientation(.landscapeRight)
            report(source.orientation == .landscapeRight, "rotate-orientation-recorded",
                   "source reports \(source.orientation.rawValue)")
            pump(3)

            guard let turned = source.captureCurrentFrame() else {
                report(false, "rotate-frame-after", "no frame after rotating")
                throw ForcedDegradation()
            }
            let turnedChanged = changedFraction(uprightSample, sample(turned))
            // A rotation re-lays out and re-draws essentially everything. A clock tick moves a sliver
            // of the status bar, and the 5% bar the tap check uses is far too generous for this.
            report(turnedChanged > 0.25, "rotate-redrew-screen",
                   String(format: "%.1f%% of the screen differs after rotating to landscape",
                          turnedChanged * 100))

            // The framebuffer's size is the thing everybody expects to swap, so say plainly that it
            // does not — a future Xcode where it DOES swap would show up here as this line changing.
            let turnedSize = source.displaySize
            report(turnedSize == size, "rotate-keeps-framebuffer-size",
                   "\(safeInt(turnedSize.width))x\(safeInt(turnedSize.height)), unchanged — iOS "
                   + "renders its rotated interface into the same surface")

            // What DID swap: the guest's own geometry. The accessibility tree reports element frames
            // in the *interface's* coordinates, so in landscape they spread across the long edge —
            // and this is the measurement that says the interface really turned rather than the
            // pixels merely changing. Informational: the pass/fail is the round trip below.
            if let landscapeSpread = spread(source) {
                print(String(format:
                    "INFO rotate-ax: %d elements, the device type calls this screen %.0fx%.0fpt, "
                    + "element centres reach %.0fpt across and %.0fpt down, app %@",
                    landscapeSpread.elements, landscapeSpread.pointSize.width,
                    landscapeSpread.pointSize.height, landscapeSpread.widest,
                    landscapeSpread.tallest, landscapeSpread.application))
            }

            // The contract, in landscape, against an app that really did turn. Safari's address
            // field is the target because tapping it has a consequence nothing else on this screen
            // has: the field activates and a Clear text button appears beside it. A tap a quarter
            // turn out lands in the page, changes the screen, and produces neither — which is
            // exactly the difference the old assertions could not see.
            //
            // The consequence is deliberately NOT a keyboard key. Tapping the field does raise the
            // keyboard, but whether its keys reach the accessibility tree varies by device: measured
            // present on iPhone 16 and absent on iPhone 16 Pro. Keying the projection's own proof to
            // that made a correct projection look broken on one model — the tap had landed, the field
            // was active, and only the keyboard's enumeration was missing.
            let sideways = assertRoundTrip(
                "rotate-ax-landscape", aimingAt: "Address", expecting: "Clear text")
            // The round trip above left the keyboard up, which is the screen that mixes two spaces.
            assertLandscapeKeyboard()

            try source.setOrientation(.portrait)
            report(source.orientation == .portrait, "rotate-back-orientation-recorded")

            // Rotating back, asserted on one element's reported place rather than on pixels: a page
            // that repainted, a clock that ticked or a scroll position Safari restored differently
            // all move pixels, and none of them is the device failing to come back. Safari's address
            // field crosses the whole display between the two orientations — sideways it sits in the
            // narrow strip along one edge, upright it sits across the middle — so its cx tells the
            // two apart and cannot be satisfied by both. The app takes a moment to lay out again, so
            // wait for it rather than calling a slow rotation a failure.
            var uprightAddress: SimulatorAccessibilityElement?
            let backBy = Date().addingTimeInterval(12)
            while Date() < backBy {
                pump(1)
                uprightAddress = (try? source.describeAccessibility())?
                    .firstElement(labelContaining: "Address")
                if let uprightAddress, uprightAddress.centre.x > 0.3 { break }
            }
            if let sideways, let uprightAddress {
                report(sideways.centre.x < 0.2 && uprightAddress.centre.x > 0.3,
                       "rotate-back-restores-geometry",
                       String(format: "the address field's centre came back from cx %.3f to cx %.3f",
                              sideways.centre.x, uprightAddress.centre.x))
            } else {
                report(false, "rotate-back-restores-geometry",
                       "no address field to compare 12s after rotating back to portrait")
            }
        } catch is ForcedDegradation {
            // Only thrown above to skip the rest of this block.
        } catch {
            report(false, "rotate", "\(error)")
        }

        // MARK: the app that refuses to rotate
        //
        // The other half of the contract, and the half the first attempt at this got wrong. Settings
        // on an iPhone declares portrait-only, so with the device asking for landscape its interface
        // stays upright — and Synth's own record says landscape, which is why that record must not
        // reach a coordinate. The bug this pins was exactly here: a tree divided by the transposed
        // axes because Synth had *asked* for landscape, reporting centres that tapped a different row.
        do {
            try source.setOrientation(.landscapeRight)
            pump(2)
            try? SimulatorDeviceCatalog.terminate(
                udid: udid, bundleIdentifier: "com.apple.Preferences")
            try source.launch(bundleIdentifier: "com.apple.Preferences")
            pump(4)
            report(source.orientation == .landscapeRight, "portrait-locked-device-asked-for-landscape",
                   "Synth's record says \(source.orientation.rawValue) while Settings stays upright")
            assertRoundTrip("portrait-locked-ax", aimingAt: "General", expecting: "About")
            try source.setOrientation(.portrait)
            pump(1)
        } catch {
            report(false, "portrait-locked-ax", "\(error)")
        }

        report(true, "frame-stats", source.frameStatistics.summary)

        // The pane's presentation path. Frames arriving is not the same as frames being displayable:
        // a sample buffer the layer rejects shows as a black screen that looks exactly like a device
        // which has not drawn yet. This asserts the buffers are well-formed and accepted, which is
        // the part a window screenshot cannot distinguish anyway.
        if let frame = source.captureCurrentFrame() {
            report(frame.makeSampleBuffer() != nil, "sample-buffer-built")
            let view = SimulatorScreenView()
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 800)
            // In a real (offscreen) window, so the layer actually enters a render cycle. Detached, its
            // status stays `.unknown` forever and "not failed" is unfalsifiable — which is what this
            // assertion was before.
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView?.addSubview(view)
            window.orderBack(nil)
            view.present(frame)
            pump(0.5)
            report(view.presentationFailure == nil && view.presentationStatus == "rendering",
                   "layer-accepts-frames",
                   view.presentationFailure ?? "status \(view.presentationStatus)")
            window.orderOut(nil)
        } else {
            report(false, "sample-buffer-built", "no frame to present")
        }

        source.stop()
        report(true, "source-stopped")
        cleanUp()
        finish()
    }

    /// How far the frontmost app's reported centres reach across the display, in points. Centres are
    /// already projected into the display's space, so a rotation shows up here as the spread turning
    /// with it: a portrait interface reaches further down than across, a landscape one the other way.
    private static func spread(_ source: SimulatorDeviceSource)
        -> (elements: Int, pointSize: CGSize, widest: CGFloat, tallest: CGFloat, application: String)? {
        guard let tree = try? source.describeAccessibility(), !tree.elements.isEmpty else { return nil }
        return (tree.elements.count, tree.pointSize,
                tree.elements.map { $0.centre.x * tree.pointSize.width }.max() ?? 0,
                tree.elements.map { $0.centre.y * tree.pointSize.height }.max() ?? 0,
                tree.application ?? "?")
    }

    /// A coarse grid of pixels copied out of the frame immediately. Sampled rather than exhaustive
    /// because this only has to tell a navigation from a clock tick.
    private static func sample(_ frame: SimulatorFrame) -> [UInt32] {
        guard CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(frame.pixelBuffer)
        else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(frame.pixelBuffer)
        var pixels: [UInt32] = []
        pixels.reserveCapacity((width / 16 + 1) * (height / 16 + 1))
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) {
                pixels.append(base.load(fromByteOffset: y * bytesPerRow + x * 4, as: UInt32.self))
            }
        }
        return pixels
    }

    private static func changedFraction(_ a: [UInt32], _ b: [UInt32]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        let differing = zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        return Double(differing) / Double(a.count)
    }
}
