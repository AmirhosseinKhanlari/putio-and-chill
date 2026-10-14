import AMDBKit
import SwiftUI

/// While put.io is read for the first time: pulsing gray cards instead of raw file names.
struct LibraryLoadingRow: View {
    let title: String
    let cardSize: CGSize
    var gutter: CGFloat
    var titleFont: Font = .title3.weight(.semibold)
    @Environment(AppModel.self) private var app
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(titleFont)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(pulse ? 0.12 : 0.05))
                            .frame(width: cardSize.width, height: cardSize.height)
                    }
                }
                .padding(.horizontal, gutter)
            }
            .disabled(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), loading")
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }

    private var note: String {
        let pending = app.library.pendingMatches
        return pending > 0 ? "Matching \(pending) title\(pending == 1 ? "" : "s")…" : "Reading your put.io…"
    }

    /// First load: nothing to show yet and put.io hasn't been read (or is being read / matched right now).
    static func isShowing(_ library: LibraryIndex) -> Bool {
        guard library.entries.isEmpty else { return false }
        if library.isRefreshing || library.pendingMatches > 0 { return true }
        return library.lastUpdated == nil && library.lastError == nil
    }
}
