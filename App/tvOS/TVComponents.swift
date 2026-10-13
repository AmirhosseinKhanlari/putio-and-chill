import AMDBCore
import AMDBKit
import SwiftUI

enum TVMetrics {
    static let poster = CGSize(width: 250, height: 375)
    static let wide = CGSize(width: 480, height: 270)
    static let edge: CGFloat = 80
}

/// Poster that lifts when focused (tvOS card style); its backdrop tints the screen while focused.
struct TVPosterButton: View {
    let item: CatalogItem
    var size = TVMetrics.poster
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RemoteImage(path: item.posterPath ?? item.backdropPath, size: "w342", seed: item.title)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .bottomLeading) {
                    if item.posterPath == nil {
                        Text(item.title).font(.headline).padding(14).lineLimit(3)
                    }
                }
                .background(FocusTint(item: item))
        }
        .buttonStyle(.card)
        .accessibilityLabel(item.title)
    }
}

/// Wide 16:9 card for things being watched: still, title, and how far along.
struct TVWideCard: View {
    let title: String
    let subtitle: String?
    let imagePath: String?
    let progress: Double?
    let tintItem: CatalogItem?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(path: imagePath, size: "w780", seed: title)
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.8)) }
                    if let progress {
                        ProgressView(value: progress).tint(.white).frame(height: 6)
                    }
                }
                .padding(20)
            }
            .frame(width: TVMetrics.wide.width, height: TVMetrics.wide.height)
            .background { if let tintItem { FocusTint(item: tintItem) } }
        }
        .buttonStyle(.card)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Tints the ambient background with the focused title's artwork.
private struct FocusTint: View {
    let item: CatalogItem
    @Environment(\.isFocused) private var focused
    @Environment(AmbientController.self) private var ambient

    var body: some View {
        Color.clear.onChange(of: focused) { _, isFocused in if isFocused { ambient.focus(item) } }
    }
}

/// A titled horizontal row.
struct TVShelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, TVMetrics.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) { content() }
                    .padding(.horizontal, TVMetrics.edge)
                    .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// Catalog row of posters.
struct TVCatalogShelf: View {
    let row: CatalogRow
    @Environment(TVRouter.self) private var router

    var body: some View {
        TVShelf(title: row.title) {
            ForEach(row.items) { item in TVPosterButton(item: item) { router.open(item) } }
        }
    }
}

/// Library entries (Continue Watching, Recently Added) as wide cards that play straight away.
struct TVEntryShelf: View {
    let title: String
    let entries: [LibraryEntry]
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router

    var body: some View {
        TVShelf(title: title) {
            ForEach(entries) { entry in
                let resume = app.library.resumeSeconds(for: entry)
                TVWideCard(title: entry.match?.title ?? entry.displayTitle, subtitle: Self.caption(entry, resume: resume),
                           imagePath: entry.match?.backdropPath ?? entry.match?.posterPath,
                           progress: nil, tintItem: entry.match.map(Self.item)) {
                    router.play(entry, from: resume)
                }
            }
        }
    }

    static func caption(_ entry: LibraryEntry, resume: Int) -> String? {
        let episode = entry.match.flatMap { match in match.season.map { "S\($0)" + (match.episode.map { " E\($0)" } ?? "") } }
        let time = resume >= 30 ? "Resume \(Format.clock(resume))" : nil
        let parts = [episode, time].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func item(_ match: LibraryMatch) -> CatalogItem {
        CatalogItem(tmdbID: match.tmdbID, mediaType: match.mediaType, title: match.title, posterPath: match.posterPath,
                    backdropPath: match.backdropPath, year: match.year)
    }
}
