import AMDBCore
import AMDBKit
import SwiftUI

/// Continue Watching on Home: videos to resume, and each show's next episode after a watched one (Up Next).
struct ContinueWatchingRow: View {
    let cards: [WatchingCard]
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue Watching").font(.title3.weight(.semibold)).padding(.horizontal, Metrics.gutter(sizeClass))
            Shelf {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(cards) { card in
                        let remove = { withAnimation { app.library.removeFromContinueWatching(card) } }
                        switch card {
                        case let .resume(entry): EntryCard(entry: entry, width: Metrics.poster(sizeClass), remove: remove)
                        case let .upNext(next): UpNextCardView(card: next, width: Metrics.poster(sizeClass), remove: remove)
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("row.Continue Watching")
    }
}

/// The episode after the one just watched: tap plays it from the start (or opens the show on it when it isn't in
/// put.io); touch and hold opens the show (with `remove`: a menu with that and Remove from Continue Watching).
struct UpNextCardView: View {
    let card: UpNextCard
    let width: CGFloat
    var remove: (() -> Void)?
    @Environment(Router.self) private var router
    @State private var heldAt: Date?

    var body: some View {
        Button {
            if let heldAt, Date().timeIntervalSince(heldAt) < 3 {
                self.heldAt = nil
                return
            }
            router.open(card)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(path: card.posterPath, size: "w342", seed: card.showTitle)
                    .frame(width: width, height: width * 1.5)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            badge("Up Next · \(card.episodeLabel)", symbol: card.isInPutio ? "play.fill" : "forward.end.fill")
                            if !card.isInPutio { badge("Not in put.io", symbol: nil) }
                        }
                        .padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                Text(card.name.map { "\(card.showTitle) · \($0)" } ?? card.showTitle)
                    .font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1).frame(width: width, alignment: .leading)
            }
            .hoverEffect(.lift)
        }
        .buttonStyle(.lift)
        .modifier(HoldMenu(remove: remove, details: ("Go to Show", { router.showTitle(card.titleItem) }), holdAction: openShow))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([card.showTitle, card.label, card.name].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(card.isInPutio ? "Plays it. Touch and hold for the show" : "Opens the show on this episode")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show details") { openShow() }
        .onDisappear { heldAt = nil }
    }

    private func badge(_ text: String, symbol: String?) -> some View {
        Group {
            if let symbol { Label(text, systemImage: symbol) } else { Text(text) }
        }
        .font(.caption2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.black.opacity(0.6), in: Capsule())
    }

    private func openShow() {
        heldAt = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        router.showTitle(card.titleItem)
    }
}
