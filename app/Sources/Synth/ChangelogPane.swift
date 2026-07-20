import SwiftUI

// MARK: - Changelog (Synth → Changelog)

/// One shipped release, decoded from the bundled `Resources/CHANGELOG.json`. The ledger
/// (FEATURES.md) is dated, not versioned; the JSON is the curated, version-grouped,
/// user-facing view of it, regenerated per release (see the release skill).
private struct Release: Codable, Identifiable {
    let version: String
    let date: String
    let changes: [String]
    var id: String { version }
}

/// The whole changelog, decoded once from the bundle. Looked up by hand rather than
/// `Bundle.module` (which fatalErrors when the dev bundle misses the copy), mirroring
/// CommentMode's overlay lookup — the shipped `.app` and the dev bundle both carry the
/// resource inside `Synth_Synth.bundle`.
private let changelog: [Release] = {
    var bundles: [URL] = []
    if let r = Bundle.main.resourceURL { bundles.append(r.appendingPathComponent("Synth_Synth.bundle")) }
    if let e = Bundle.main.executableURL?.deletingLastPathComponent() {
        bundles.append(e.appendingPathComponent("Synth_Synth.bundle"))
    }
    for url in bundles {
        if let bundle = Bundle(url: url),
           let res = bundle.url(forResource: "CHANGELOG", withExtension: "json"),
           let data = try? Data(contentsOf: res),
           let decoded = try? JSONDecoder().decode([Release].self, from: data) {
            return decoded
        }
    }
    NSLog("Synth: CHANGELOG.json resource missing — changelog is empty")
    return []
}()

/// The in-app changelog: a read-only modal that reads like the ⌘? shortcuts sheet — a
/// keyboard-navigable version rail (↑/↓ or j/k) beside a detail pane, so releases stay
/// glanceable as they pile up and the whole thing is driven without the mouse.
/// Opened from the Mac menu bar (Synth → Changelog); Esc / backdrop click dismiss.
struct ChangelogSheet: View {
    @Environment(AppStore.self) private var store

    static var releaseCount: Int { changelog.count }

    private var selected: Int { min(max(0, store.changelogVersion), max(0, changelog.count - 1)) }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Theme.border).frame(width: 0.5)
            detail
        }
        .frame(width: 600, height: 428)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    // The version rail — each release with its date, the selected one wearing the copper accent
    // pill; it scrolls the active row into view as the keyboard walks down a long history.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RELEASES")
                .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                .foregroundStyle(Theme.navLabel)
                .padding(.leading, 10).padding(.top, 4).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(changelog.enumerated()), id: \.offset) { i, release in
                            ReleaseRow(version: release.version, date: release.date,
                                       latest: i == 0, selected: i == selected) {
                                store.changelogVersion = i
                            }
                            .id(i)
                        }
                    }
                }
                .onChange(of: store.changelogVersion) { _, i in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i, anchor: nil) }
                }
            }
            // Keyboard-first affordance — this sheet is driven by the keyboard.
            HStack(spacing: 6) {
                KeyCaps(keys: ["↑", "↓"])
                Text("navigate").font(.system(size: 10.5)).foregroundStyle(Theme.inkMeta)
                Spacer(minLength: 0)
                KeyCap(text: "esc")
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
        }
        .padding(.vertical, 14).padding(.horizontal, 8)
        .frame(width: 194)
        .background(Theme.sidebar)
    }

    private var detail: some View {
        let release = changelog.indices.contains(selected) ? changelog[selected] : nil
        return VStack(alignment: .leading, spacing: 0) {
            if let release {
                HStack(spacing: 9) {
                    Text(release.version)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced)).kerning(-0.1)
                        .foregroundStyle(Theme.copper)
                    Text(release.date)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.inkMeta)
                }
                .padding(.bottom, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(release.changes.enumerated()), id: \.offset) { _, change in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(Theme.copper.opacity(0.6))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 6)
                                Text(change)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row in the version rail — the sidebar-row idiom (version + date, selected wearing the
/// copper accent tint, hover deepening it), mirroring the shortcuts sheet's category rows.
private struct ReleaseRow: View {
    let version: String
    let date: String
    let latest: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(version)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium, design: .monospaced))
                        .foregroundStyle(selected ? Theme.inkOpen : Theme.sessionName)
                    Text(date)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.inkMeta)
                }
                Spacer(minLength: 0)
                if latest {
                    Text("Latest")
                        .font(.system(size: 9, weight: .semibold)).kerning(0.3)
                        .foregroundStyle(Theme.copper)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.copper.opacity(0.12)))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Theme.accent.opacity(selected ? (hovering ? 0.16 : 0.11) : (hovering ? 0.06 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
