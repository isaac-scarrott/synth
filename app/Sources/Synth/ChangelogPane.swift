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

/// The in-app changelog: a read-only, scrollable modal modelled on `ShortcutsSheet`.
/// Opened from the Mac menu bar (Synth → Changelog); Esc / backdrop click dismiss.
struct ChangelogSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's new")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(changelog) { release in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(release.version)
                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.accent)
                                Text(release.date)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.inkMeta)
                            }
                            ForEach(Array(release.changes.enumerated()), id: \.offset) { _, change in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("·")
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(Theme.inkMeta)
                                    Text(change)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Theme.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .frame(width: 460, height: 520)
        .background(Theme.panel)
    }
}
