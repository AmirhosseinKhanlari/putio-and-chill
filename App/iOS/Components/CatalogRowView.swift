import AMDBCore
import AMDBKit
import SwiftUI

struct CatalogRowView: View {
    let row: CatalogRow
    /// Shows "See all" next to the title when set.
    var seeAll: (() -> Void)?
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(row.title).font(.title3.weight(.semibold))
                Spacer()
                if let seeAll {
                    Button("See all", action: seeAll)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityLabel("See all \(row.title)")
                }
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            Shelf {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items) { item in
                        Button { router.open(item) } label: { PosterCard(item: item, width: Metrics.poster(sizeClass)) }
                            .buttonStyle(.lift)
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}

struct EntryRowView: View {
    let title: String
    let entries: [LibraryEntry]
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, Metrics.gutter(sizeClass))
            Shelf {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(entries) { entry in EntryCard(entry: entry, width: Metrics.poster(sizeClass)) }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}

/// A file in put.io (Continue Watching, Recently Added): tap plays it, touch and hold opens its movie or show page.
struct EntryCard: View {
    let entry: LibraryEntry
    let width: CGFloat
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    /// When the hold opened the title page: the button's own tap (on lifting the finger) is then ignored.
    @State private var heldAt: Date?

    var body: some View {
        let resume = app.library.resumeSeconds(for: entry)
        Button {
            if let heldAt, Date().timeIntervalSince(heldAt) < 3 {
                self.heldAt = nil
                return
            }
            router.play(entry, resumeFrom: resume)
        } label: {
            LibraryPoster(entry: entry, width: width, resumeSeconds: resume,
                          watched: app.library.watchedFraction(for: entry), left: app.library.remainingSeconds(for: entry))
        }
        .buttonStyle(.lift)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in openDetails() })
        .accessibilityHint(entry.titleItem == nil ? "Plays it" : "Plays it. Touch and hold for details")
        .accessibilityAction(named: entry.match?.mediaType == .tv ? "Show details" : "Movie details") { openDetails() }
        .onDisappear { heldAt = nil }
    }

    private func openDetails() {
        guard let item = entry.titleItem else { return }
        heldAt = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        router.showTitle(item)
    }
}
