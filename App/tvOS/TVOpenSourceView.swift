import SwiftUI

/// Settings → About on Apple TV: the open-source code in the built-in player, with its licenses. Shown as text
/// (tvOS can't open web pages); each piece takes focus so the remote scrolls through it.
struct TVOpenSourceView: View {
    var versionLine: String?

    var body: some View {
        Form {
            if let versionLine {
                Section { TVTextRow(title: "Putio & Chill", detail: versionLine) }
            }
            Section {
                ForEach(OpenSourceNotices.all) { notice in
                    NavigationLink {
                        TVLicenseView(notice: notice).modifier(TVBackGoesUp())
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(notice.name)
                            Text(notice.license).font(.system(size: 22)).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Open Source")
            } footer: {
                Text("The built-in player, which plays videos Apple's player can't, is made with these. Their source is public; "
                     + "FFmpeg is a separate part of the app that can be swapped for a modified build.")
            }
        }
    }
}

/// Plain information that can still take focus, so the remote moves through the page.
private struct TVTextRow: View {
    let title: String
    let detail: String

    var body: some View {
        Button {} label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 29, weight: .semibold))
                Text(detail).font(.system(size: 24)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One component's notice and its license text, paragraph by paragraph.
private struct TVLicenseView: View {
    let notice: OpenSourceNotices.Notice

    private var paragraphs: [String] {
        [notice.detail, "License: \(notice.license)", "Source: \(notice.source)"]
            + notice.texts.flatMap { name in
                OpenSourceNotices.text(name).components(separatedBy: "\n\n")
                    .map { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
                    .filter { !$0.isEmpty }
            }
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(notice.name).font(.system(size: 48, weight: .bold)).padding(.horizontal, 24)
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, text in TVLicenseParagraph(text: text) }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .tvPageBackground()
    }
}

/// A paragraph that lights up while focused, so it's clear where the remote is.
private struct TVLicenseParagraph: View {
    let text: String
    @FocusState private var focused: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 23))
            .foregroundStyle(.white.opacity(0.88))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(focused ? 0.12 : 0)))
            .focusable()
            .focused($focused)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
