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
                                   ratings: { [app] imdbID, kind in await app.ratings(imdbID: imdbID, kind: kind) })
            model = title
            await title.load()
        }
    }
}

private struct TitleHeader: View {
    let item: CatalogItem
    let model: TitleModel?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var trailer: TrailerKey?

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
                HStack(spacing: 10) {
                    if let model, item.mediaType == .movie {
                        PrimaryActions(model: model, season: nil, episode: nil)
                    }
                    if let key = detail?.trailerYouTubeKey {
                        Button { trailer = TrailerKey(key: key) } label: { Label("Trailer", systemImage: "play.rectangle.fill") }
                            .buttonStyle(.glassPill)
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
        .fullScreenCover(item: $trailer) { TrailerSheet(youtubeKey: $0.key) { trailer = nil }.ignoresSafeArea() }
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
