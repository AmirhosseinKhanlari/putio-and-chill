import AMDBCore
import AMDBKit
import SwiftUI

struct TitleView: View {
    let item: CatalogItem
    /// An episode to open the page on (an Up Next card): its season is shown, scrolled to it.
    var focus: EpisodeKey?
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.keyNavTab) private var tab
    @State private var model: TitleModel?
    @State private var scrolledToFocus = false
    /// Between onAppear and onDisappear (a tab switch fires neither: hidden tabs stay mounted).
    @State private var isOnScreen = false

    /// The item as it came in, with what TMDB loaded filling in whatever the link that opened the page didn't carry:
    /// a page opened from a new-episode notification, a widget's Up Next card or Downloads' "Go to Show" arrives
    /// with only its id, and showed no artwork, name or year.
    private var shown: CatalogItem {
        guard let loaded = model?.detail?.item else { return item }
        return item.filled(from: loaded)
    }

    var body: some View {
        ScrollViewReader { proxy in
            page.onChange(of: model?.episodes.count ?? 0) { _, count in
                guard let focus, !scrolledToFocus, count > 0, model?.selectedSeason == focus.season else { return }
                scrolledToFocus = true
                withAnimation { proxy.scrollTo(focus, anchor: .center) }
            }
        }
    }

    private var page: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                TitleHeader(item: shown, model: model)
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
            isOnScreen = true
            syncActiveTitle()
            ambient.focus(shown)
        }
        .onDisappear {
            isOnScreen = false
            syncActiveTitle()
        }
        .onChange(of: router.tab) { _, _ in syncActiveTitle() }
        // The page opened with only an id: the glow takes the artwork's colors once TMDB has answered.
        .onChange(of: model?.detail?.item) { _, loaded in
            guard loaded != nil, item.backdropPath == nil, item.posterPath == nil else { return }
            ambient.focus(shown)
        }
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let title = TitleModel(item: item, catalog: catalog, library: app.library, transfers: app.transfers, focus: focus,
                                   ratings: { [app] imdbID, tmdbID, kind in await app.ratings(imdbID: imdbID, tmdbID: tmdbID, kind: kind) },
                                   episodeRatings: { [app] imdbID, season in await app.episodeRatings(seriesIMDbID: imdbID, season: season) })
            model = title
            await title.load()
        }
    }

    /// A ready transfer counts down on this page only while it's the page in view: in the tab that's showing and
    /// not under another page. Hidden tabs stay mounted, so a tab switch has to be noticed here too, or an unseen
    /// page would count down and start playback.
    private func syncActiveTitle() {
        let active = isOnScreen && (tab == nil || router.tab == tab)
        if active {
            router.activeTitle = item.tmdbID
        } else if router.activeTitle == item.tmdbID {
            router.activeTitle = nil
        }
    }
}

private extension CatalogItem {
    /// This item with `loaded`'s values wherever this one has none.
    func filled(from loaded: CatalogItem) -> CatalogItem {
        CatalogItem(tmdbID: tmdbID, mediaType: mediaType,
                    title: title.isEmpty ? loaded.title : title,
                    overview: overview.isEmpty ? loaded.overview : overview,
                    posterPath: posterPath ?? loaded.posterPath,
                    backdropPath: backdropPath ?? loaded.backdropPath,
                    profilePath: profilePath ?? loaded.profilePath,
                    year: year ?? loaded.year,
                    voteAverage: voteAverage ?? loaded.voteAverage,
                    genreIDs: genreIDs.isEmpty ? loaded.genreIDs : genreIDs,
                    knownFor: knownFor)
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
                if let model, model.error != nil {
                    HStack(spacing: 12) {
                        Text("Couldn't load details.").font(.footnote).foregroundStyle(Theme.poor)
                        Button("Try Again") { Task { await model.load() } }
                            .font(.footnote.weight(.semibold))
                    }
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
        } else if let model, item.mediaType == .tv {
            ShowPrimaryActions(model: model)
        }
    }

    @ViewBuilder private var secondaryActions: some View {
        let detail = model?.detail
        if detail != nil { MyListButton(item: item) }
        // Shows: new-episode alerts.
        if detail != nil, item.mediaType == .tv {
            EpisodeBell(show: item).glassCapsule()
        }
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
            Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44).glassCapsule()
                // A forgiving touch area around the visible circle.
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
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
