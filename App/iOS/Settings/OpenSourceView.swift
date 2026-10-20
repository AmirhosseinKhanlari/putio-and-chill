import SwiftUI

/// Settings → About: the open-source code in the built-in player, each with its license, where its source is, and
/// the full license text (which the LGPL asks the app to carry).
struct OpenSourceView: View {
    /// "Putio & Chill 1.0 (28)" at the top, when this is the whole About page.
    var versionLine: String?

    var body: some View {
        Form {
            if let versionLine {
                Section { Text(versionLine).font(.subheadline) }
            }
            Section {
                ForEach(OpenSourceNotices.all) { notice in
                    NavigationLink {
                        LicenseTextView(notice: notice)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(notice.name)
                            Text(notice.license).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Open Source")
            } footer: {
                Text(BuiltInPlayer.isAvailable
                     ? "The built-in player, which plays videos Apple's player can't, is made with these. Their source is public; "
                       + "FFmpeg is a separate part of the app that can be swapped for a modified build."
                     : "These are part of the iPhone, iPad and Apple TV apps' built-in player. The Mac app uses Apple's player.")
            }
        }
    }
}

/// One component's notice, source link and full license text.
private struct LicenseTextView: View {
    let notice: OpenSourceNotices.Notice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(notice.detail).font(.subheadline)
                Text("License: \(notice.license)").font(.subheadline.weight(.semibold))
                Text("Source: \(notice.source)").font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(notice.texts, id: \.self) { name in
                    Divider()
                    Text(OpenSourceNotices.text(name))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .navigationTitle(notice.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
