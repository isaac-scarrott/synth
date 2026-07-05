import AppKit

/// `Synth --browser-check`: headless-ish engine self-check, rerunnable by the verifier
/// (`./dev.sh --check`). Creates a CEF engine off-screen, navigates a data: URL, and
/// asserts (a) address/title callbacks fired, (b) the CDP endpoint serves
/// /json/version, (c) shutdown leaves zero CEF helper processes. Prints PASS/FAIL
/// lines and exits nonzero on any failure.
@MainActor
enum BrowserCheck {
    private final class Probe: NSObject, BrowserEngineDelegate {
        var addressFired = false
        var titleFired = false
        var navStateFired = false

        func engine(_ engine: BrowserEngine, addressDidChange url: URL) { addressFired = true }
        func engine(_ engine: BrowserEngine, titleDidChange title: String) { titleFired = true }
        func engine(_ engine: BrowserEngine, navigationStateDidChange canGoBack: Bool,
                    canGoForward: Bool) { navStateFired = true }
        func engine(_ engine: BrowserEngine, didRequestPopup url: URL) {}
    }

    static func run() -> Never {
        var failures = 0
        func report(_ ok: Bool, _ name: String, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failures += 1 }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        func dataURL(title: String) -> URL {
            let html = "<html><head><title>\(title)</title></head><body>ok</body></html>"
            return URL(string: "data:text/html;base64,"
                + Data(html.utf8).base64EncodedString())!
        }

        // Constructs CEFEngine directly, not via the factory — this check exists to prove
        // the CEF path, and the factory's WKWebView fallback would mask a broken one.
        let engine: BrowserEngine
        #if canImport(CEFShim)
        do {
            engine = try CEFEngine(initialURL: dataURL(title: "synth-boot"))
        } catch {
            report(false, "engine-created", error.localizedDescription)
            print("BROWSER-CHECK RESULT: FAIL")
            exit(1)
        }
        #else
        report(false, "engine-created", "CEF not built in — run app/vendor/fetch-cef.sh and rebuild")
        print("BROWSER-CHECK RESULT: FAIL")
        exit(1)
        #endif
        report(true, "engine-created", "cdp port \(engine.cdpPort)")

        let probe = Probe()
        engine.delegate = probe

        // Never ordered in: callbacks and the CDP server don't need pixels on screen.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        engine.view.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(engine.view)

        // Navigate AFTER wiring the probe — creation-time events land before any
        // delegate exists (real panes have the same contract).
        engine.navigate(to: dataURL(title: "synth-browser-check"))
        pump(until: { probe.addressFired && probe.titleFired && probe.navStateFired },
             timeout: 20)
        report(probe.addressFired, "address-callback",
               probe.addressFired ? (engine.currentURL?.absoluteString.prefix(48).description ?? "") : "none within 20s")
        report(probe.titleFired, "title-callback", engine.pageTitle ?? "none within 20s")
        report(probe.navStateFired, "nav-state-callback")

        report(fetchCDPVersion(port: engine.cdpPort) != nil, "cdp-endpoint",
               fetchCDPVersionCache ?? "no response from /json/version")

        engine.shutdown()
        pump(until: { false }, timeout: 0.5)   // let the async close land
        BrowserEngineFactory.globalShutdown()  // pumps until every browser is gone, then CefShutdown

        // Helper exit is async after CefShutdown; give them a grace window.
        var helpers = liveHelperCount()
        pump(until: { helpers = liveHelperCount(); return helpers == 0 }, timeout: 5)
        report(helpers == 0, "zero-cef-helpers", helpers == 0 ? "" : "\(helpers) still alive")

        print("BROWSER-CHECK RESULT: \(failures == 0 ? "PASS" : "FAIL")")
        exit(failures == 0 ? 0 : 1)
    }

    @discardableResult
    private static func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    private static var fetchCDPVersionCache: String?

    /// Polls /json/version until the DevTools server answers (it binds during
    /// CefInitialize, but give it a grace window under load).
    private static func fetchCDPVersion(port: UInt16) -> String? {
        let url = URL(string: "http://127.0.0.1:\(port)/json/version")!
        let deadline = Date(timeIntervalSinceNow: 15)
        while Date() < deadline {
            final class Box: @unchecked Sendable { var result: String??  }
            let box = Box()
            URLSession.shared.dataTask(with: url) { data, response, _ in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                let body = ok ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
                DispatchQueue.main.async { box.result = .some(body) }
            }.resume()
            pump(until: { box.result != nil }, timeout: 5)
            if let body = box.result ?? nil {
                // First line of evidence, e.g. the "Browser" field.
                let browser = body.split(separator: "\n")
                    .first(where: { $0.contains("\"Browser\"") })?
                    .trimmingCharacters(in: .whitespaces) ?? "HTTP 200"
                fetchCDPVersionCache = browser
                return body
            }
            pump(until: { false }, timeout: 0.5)
        }
        return nil
    }

    /// CEF helper processes spawned from THIS bundle (other Synth instances on the
    /// machine keep theirs).
    private static func liveHelperCount() -> Int {
        let helperPrefix = Bundle.main.bundlePath + "/Contents/Frameworks/Synth Helper"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", helperPrefix]
        let out = Pipe()
        task.standardOutput = out
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return -1 }
        return text.split(separator: "\n").count
    }
}
