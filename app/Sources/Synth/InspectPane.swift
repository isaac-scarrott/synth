import SwiftUI

/// The inspect session's surface (features 2026-09-01): Chromium's real DevTools for the
/// browser this session belongs to, filling the pane — the working.html mock draws skeleton
/// chrome here, but natively the tool itself renders, tabs and all, so the pane adds no
/// chrome of its own. The tie to the browser lives in the sidebar (ownerSessionID + mark).
///
/// The surface is the DevTools *frontend* Chromium serves off the instance's CDP endpoint,
/// loaded in an engine of the inspect session's own (`ShowDevTools` with a parented
/// CefWindowInfo is a hard CHECK in CEF 144's Chrome bootstrap, so the frontend-over-CDP
/// route is the supported one — and it reuses the whole browser-session lifecycle:
/// BrowserManager owns the engine, teardownSession's terminate closes it). The pane
/// resolves the owner's page target, stamps the frontend URL on the session (`browserURL`
/// — this run's plumbing only, deliberately not persisted: port and target id are minted
/// per run, so a restored inspect resolves a fresh one), and hosts the engine view.
///
/// Engine discipline is BrowserPane's: render reads `paneEngine` (non-creating, so a
/// resolve can't freeze the open frame inside CEF's runloop-pumping bootstrap) and
/// creation is triggered a runloop turn later; `generation` re-renders us when it lands.
///
/// Known limitation: the stamped URL names one page target, and Chromium can replace a
/// target mid-run (a renderer crash; anything that swaps the WebContents). The frontend
/// then shows its own disconnected banner until the inspect is closed and reopened —
/// there is no signal Synth observes to re-resolve on. Clear-browsing-data, the one
/// Synth-initiated engine swap, does re-resolve (clearBrowsingData nils the URL).
struct InspectPane: View {
    @Environment(AppStore.self) private var store
    let session: Session

    /// Bounded resolve loop: `attempt` re-arms the task; past `maxAttempts` (or on a
    /// recorded engine failure) the placeholder turns into the refusal.
    @State private var attempt = 0
    @State private var stalled: String?
    private static let maxAttempts = 25   // × 400ms ≈ 10s of "Waiting for the page…"

    private var ownerBrowser: Session? {
        store.owner(of: session).flatMap { $0.kind == .browser ? $0 : nil }
    }

    var body: some View {
        Group {
            if session.browserURL != nil,
               let ctrl = BrowserManager.shared.paneEngine(for: session) {
                InspectHost(devToolsView: ctrl.engine.view)
                    // A live surface pays the resolve budget back: a later re-resolve
                    // (clear-browsing-data nils the URL and recycles both engines) starts fresh.
                    .onAppear { attempt = 0; stalled = nil }
            } else if let reason = BrowserManager.shared.failure(session.id) ?? stalled {
                refusal(reason)
            } else if !BrowserManager.shared.isDead(session.id) {
                placeholder
                    .task(id: attempt) { await advance() }
            }
        }
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderStrong, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 14))
    }

    /// One step toward a live surface, off the render pass: boot whichever engine is
    /// missing (deferred a turn, the focus:false create's proven beat), resolve the
    /// frontend URL once the owner's page is up, and retry on a short clock until the
    /// cap. Each step re-checks from the session's current state, so a step that lost a
    /// race (owner closed, engine refused) lands in the refusal on the next render.
    private func advance() async {
        guard let browser = ownerBrowser else {
            stalled = "This DevTools session's browser is gone."
            return
        }
        if let reason = BrowserManager.shared.failure(browser.id) {
            stalled = reason   // the owner can never have a page to inspect
            return
        }
        if let ctrl = BrowserManager.shared.existing(browser.id) {
            if session.browserURL == nil,
               let url = try? await CDPClient.devToolsFrontendURL(port: ctrl.engine.cdpPort,
                                                                  synthSessionID: browser.id,
                                                                  urlHint: browser.browserURL) {
                session.browserURL = url
            }
            if session.browserURL != nil, BrowserManager.shared.existing(session.id) == nil {
                DispatchQueue.main.async { _ = BrowserManager.shared.controller(for: session) }
            }
        } else {
            // A restored inspect can render before its browser's pane ever did — the owner
            // engine boots here, the same deferred way its own pane would boot it.
            DispatchQueue.main.async { _ = BrowserManager.shared.controller(for: browser) }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        if attempt >= Self.maxAttempts {
            stalled = "DevTools couldn’t reach the page — reopen this session to retry."
        } else {
            attempt += 1
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Phos(path: Phosphor.devtools, size: 22)
                .foregroundStyle(Theme.inkMuted)
            Text("Waiting for the page…")
                .font(.sans(12, 500))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// No DevTools, and retrying won't change that — the browser is gone, its engine
    /// refused, or the page never answered. The refusal card, in BrowserPane's register.
    private func refusal(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Phos(path: Phosphor.devtools, size: 34).foregroundStyle(Theme.inkFaint)
            Text("No DevTools")
                .font(.sans(13, 600)).foregroundStyle(Theme.ink)
            Text(reason)
                .font(.sans(12)).foregroundStyle(Theme.inkFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hosts the engine-owned view — the EngineHost pattern: the view is created and owned
/// elsewhere (BrowserManager); this only pins it to the pane.
private struct InspectHost: NSViewRepresentable {
    let devToolsView: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        devToolsView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(devToolsView)
        NSLayoutConstraint.activate([
            devToolsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            devToolsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            devToolsView.topAnchor.constraint(equalTo: container.topAnchor),
            devToolsView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
