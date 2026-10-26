import AMDBCore
import AMDBKit
import SwiftUI

struct HeroCarousel: View {
    let items: [CatalogItem]
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var index = 0

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                HeroPage(item: item, rank: offset + 1).tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: sizeClass == .compact ? 520 : 640)
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { dot in
                    Capsule().fill(.white.opacity(dot == index ? 1 : 0.35)).frame(width: dot == index ? 14 : 5, height: 4)
                }
            }
            .padding(.trailing, Metrics.gutter(sizeClass)).padding(.bottom, 18)
            .animation(.snappy, value: index)
        }
        .onChange(of: index, initial: true) { _, current in
            if items.indices.contains(current) { ambient.focus(items[current]) }
        }
        .task(id: items.count) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, !items.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
            }
        }
    }
}

private struct HeroPage: View {
    let item: CatalogItem
    let rank: Int
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var ratings: Ratings?

    var body: some View {
        let regular = sizeClass != .compact
        ZStack(alignment: .bottomLeading) {
            ZStack {
                RemoteImage(path: item.backdropPath, size: "w1280", seed: item.title)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                LinearGradient(colors: [Theme.background.opacity(regular ? 0.8 : 0.35), .clear], startPoint: .leading, endPoint: .trailing)
                // Scrim behind the text block so titles stay readable over bright artwork.
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Theme.background.opacity(0.85), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 10) {
                Text("#\(rank) TRENDING · \(item.mediaType == .tv ? "SERIES" : "FILM")")
                    .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.white.opacity(0.7))
                Text(item.title.uppercased())
                    .font(.system(size: regular ? 58 : 34, weight: .ultraLight))
                    .tracking(regular ? 5 : 2)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .frame(maxWidth: regular ? 820 : 360, alignment: .leading)
                MetaLine(item: item, detail: nil, ratings: ratings)
                if !item.overview.isEmpty {
                    Text(item.overview).font(.callout).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
                        .frame(maxWidth: 520, alignment: .leading)
                }
                HStack(spacing: 10) {
                    primaryButton
                    Button { router.open(item) } label: { Label("More Info", systemImage: "info.circle") }
                        .buttonStyle(.glassPill)
                    MyListButton(item: item, iconOnly: sizeClass == .compact)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, 44)
        }
        .task(id: item.id) {
            guard app.canFetchRatings, let catalog = app.catalog else { return }
            let imdbID = (try? await catalog.detail(item.mediaType, id: item.tmdbID))?.imdbID
            ratings = await app.ratings(imdbID: imdbID, tmdbID: item.tmdbID, kind: item.mediaType)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if item.mediaType == .movie, let entry = app.library.matching(tmdbID: item.tmdbID).first {
            let resume = app.library.resumeSeconds(for: entry)
            Button { router.play(entry, resumeFrom: resume) } label: {
                Label(resume >= 30 ? "Resume \(Format.clock(resume))" : "Play", systemImage: "play.fill")
            }
            .buttonStyle(.primaryPill)
        } else {
            Button { router.open(item) } label: { Label("Get & Watch", systemImage: "play.fill") }
                .buttonStyle(.primaryPill)
        }
    }
}

struct MetaLine: View {
    let item: CatalogItem
    let detail: TitleDetail?
    var ratings: Ratings?

    var body: some View {
        let tmdb = detail?.item.voteAverage ?? item.voteAverage
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let year = item.year { Text(String(year)) }
                if let runtime = Format.runtime(detail?.runtimeMinutes) { Text("·"); Text(runtime) }
                if app.library.matching(tmdbID: item.tmdbID).isEmpty == false {
                    if item.year != nil || detail?.runtimeMinutes != nil { Text("·") }
                    Label("In put.io", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                }
            }
            if RatingsBadges.hasAny(ratings, tmdb: tmdb) {
                RatingsBadges(ratings: ratings, tmdb: tmdb)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white.opacity(0.75))
    }

    @Environment(AppModel.self) private var app
}
