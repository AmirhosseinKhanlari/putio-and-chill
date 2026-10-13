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
                if let cast = model?.detail?.cast, !cast.isEmpty { CastRow(cast: cast) }
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
                if let model, item.mediaType == .movie {
                    PrimaryActions(model: model, season: nil, episode: nil).padding(.top, 6)
                } else if model?.error != nil {
                    Text("Couldn't load details.").font(.footnote).foregroundStyle(Theme.poor)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, 24)
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

private struct CastRow: View {
    let cast: [CastMember]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast").font(.title3.weight(.semibold)).padding(.horizontal, Metrics.gutter(sizeClass))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(cast, id: \.self) { member in
                        VStack(spacing: 6) {
                            RemoteImage(path: member.profilePath, size: "w185", seed: member.name)
                                .frame(width: 72, height: 72).clipShape(Circle())
                            Text(member.name).font(.caption.weight(.semibold)).lineLimit(1)
                            if let character = member.character {
                                Text(character).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 92)
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}
