import AMDBCore
import AMDBKit
import SwiftUI

struct TitleView: View {
    let item: CatalogItem
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: TitleModel?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                TitleHeader(item: item, model: model)
                if let collection = model?.detail?.collection { CollectionCard(collection: collection) }
                if item.mediaType == .tv, let model { EpisodeList(model: model) }
                if let detail = model?.detail, !(detail.cast.isEmpty && detail.crew.isEmpty) {
                    CastAndCrewRow(cast: detail.cast, crew: detail.crew)
                }
                if let recommendations = model?.detail?.recommendations, !recommendations.isEmpty {
                    CatalogRowView(row: CatalogRow(id: "more-\(item.id)", title: "More Like This", items: recommendations))
                }
            }
            .padding(.bottom, 120)
        }
        .ignoresSafeArea(edges: .top)
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
        .overlay {
            if let transfer = router.countdown, transfer.pending.tmdbID == item.tmdbID {
                CountdownOverlay(transfer: transfer)
            }
        }
        .onAppear {
            router.activeTitle = item.tmdbID
            ambient.focus(item)
        }
        .onDisappear { if router.activeTitle == item.tmdbID { router.activeTitle = nil } }
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let title = TitleModel(item: item, catalog: catalog, library: app.library, transfers: app.transfers,
                                   ratings: { [app] imdbID, kind in await app.ratings(imdbID: imdbID, kind: kind) },
                                   episodeRatings: { [app] imdbID, season in await app.episodeRatings(seriesIMDbID: imdbID, season: season) })
            model = title
            await title.load()
        }
    }
}

private struct TitleHeader: View {
    let item: CatalogItem
    let model: TitleModel?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppModel.self) private var app
    @State private var youtubeFallback: TrailerKey?
    @State private var loadingTrailer = false

    var body: some View {
        let regular = sizeClass != .compact
        let detail = model?.detail
        ZStack(alignment: .bottomLeading) {
            ZStack {
                RemoteImage(path: item.backdropPath, size: "w1280", seed: item.title)
                    .frame(height: regular ? 620 : 460)
                    .frame(maxWidth: .infinity)
                    .clipped()
                LinearGradient(colors: [Theme.background.opacity(regular ? 0.8 : 0.3), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Theme.background.opacity(0.85), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 12) {
                if let logo = detail?.logoPath {
                    RemoteImage(path: logo, size: "w500", seed: item.title, contentMode: .fit, alignment: .leading)
                        .frame(maxWidth: regular ? 420 : 260, maxHeight: regular ? 150 : 90, alignment: .leading)
                } else {
                    Text(item.title.uppercased())
                        .font(.system(size: regular ? 54 : 32, weight: .ultraLight)).tracking(regular ? 4 : 2)
                        .lineLimit(3).minimumScaleFactor(0.6)
                }
                MetaLine(item: item, detail: detail, ratings: model?.ratings)
                Text(detail?.item.overview.isEmpty == false ? detail!.item.overview : item.overview)
                    .font(.callout).foregroundStyle(.white.opacity(0.82)).lineLimit(4)
                if let genres = detail?.genres, !genres.isEmpty {
                    Text(genres.joined(separator: " · ")).font(.caption).foregroundStyle(.white.opacity(0.55))
                }
                // On narrow screens a transfer's progress gets its own line instead of squeezing the buttons.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { primaryActions; secondaryActions }
                    VStack(alignment: .leading, spacing: 12) {
                        primaryActions
                        HStack(spacing: 10) { secondaryActions }
                    }
                }
                .padding(.top, 6)
                if model?.error != nil {
                    Text("Couldn't load details.").font(.footnote).foregroundStyle(Theme.poor)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, 24)
        }
        .fullScreenCover(item: $youtubeFallback) { YouTubeFallback(youtubeKey: $0.key) { youtubeFallback = nil }.ignoresSafeArea() }
    }

    @ViewBuilder private var primaryActions: some View {
        if let model, item.mediaType == .movie {
            PrimaryActions(model: model, season: nil, episode: nil)
        }
    }

    @ViewBuilder private var secondaryActions: some View {
        let detail = model?.detail
        if detail != nil { MyListButton(item: item) }
        if detail?.imdbID != nil || detail?.trailerYouTubeKey != nil {
            Button { Task { await playTrailer() } } label: {
                if loadingTrailer {
                    ProgressView().controlSize(.small).frame(minWidth: 60)
                } else {
                    Label("Trailer", systemImage: "play.rectangle.fill")
                }
            }
            .buttonStyle(.glassPill)
            .disabled(loadingTrailer)
            .accessibilityLabel("Trailer")
        }
    }

    /// IMDb trailer in Apple's player when available; YouTube only as a fallback.
    private func playTrailer() async {
        guard let detail = model?.detail else { return }
        loadingTrailer = true
        defer { loadingTrailer = false }
        if let imdbID = detail.imdbID, let video = await app.trailer(imdbID: imdbID) {
            TrailerPlayer.present(video.url, title: item.title)
        } else if let key = detail.trailerYouTubeKey {
            youtubeFallback = TrailerKey(key: key)
        }
    }
}

struct BackButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left").font(.headline).frame(width: 40, height: 40).glassCapsule()
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.top, 8)
        .accessibilityLabel("Back")
    }
}

/// "Part of the Star Wars Collection — Watch in order".
private struct CollectionCard: View {
    let collection: CollectionRef
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Button { router.openCollection(collection.id) } label: {
            HStack(spacing: 14) {
                RemoteImage(path: collection.posterPath, size: "w185", seed: collection.name)
                    .frame(width: 46, height: 69)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text("PART OF").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.white.opacity(0.6))
                    Text(collection.name).font(.headline).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Watch in order").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(12)
            .glassRounded(16)
        }
        .buttonStyle(.lift)
        .frame(maxWidth: 640)
        .padding(.horizontal, Metrics.gutter(sizeClass))
    }
}
