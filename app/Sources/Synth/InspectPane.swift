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
/// resolves the owner's page target once, stamps the frontend URL on the session
/// (`browserURL`, persisted like any browser's), and hosts the engine view; a browser
/// still booting after a restore shows a quiet placeholder and retries.
struct InspectPane: View {
    @Environment(AppStore.self) private var store
    let session: Session

    @State private var retry = 0

    private var ownerBrowser: Session? {
        store.owner(of: session).flatMap { $0.kind == .browser ? $0 : nil }
    }

    private var engineView: NSView? {
        guard session.browserURL != nil else { return nil }
        return BrowserManager.shared.controller(for: session)?.engine.view
    }

    var body: some View {
        Group {
            if let view = engineView {
                InspectHost(devToolsView: view)
            } else {
                placeholder.task(id: retry) { await resolveFrontend() }
            }
        }
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderStrong, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 14))
    }

    /// Find the owner's page target on the instance's CDP endpoint and stamp the DevTools
    /// frontend URL on this session. Retries while the owner's engine is still booting (a
    /// restored branch re-creates engines lazily; asking for the controller boots one).
    private func resolveFrontend() async {
        guard session.browserURL == nil, let browser = ownerBrowser else { return }
        if let ctrl = BrowserManager.shared.controller(for: browser),
           let url = try? await CDPClient.devToolsFrontendURL(port: ctrl.engine.cdpPort,
                                                              synthSessionID: browser.id,
                                                              urlHint: browser.browserURL) {
            session.browserURL = url
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if !Task.isCancelled { retry += 1 }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Phos(path: Phosphor.devtools, size: 22)
                .foregroundStyle(Theme.inkMuted)
            Text(ownerBrowser == nil ? "This DevTools session's browser is gone."
                                     : "Waiting for the page…")
                .font(.sans(12, 500))
                .foregroundStyle(Theme.inkMuted)
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
