import AMDBCore
import AMDBKit
import SwiftUI

/// A movie or show: backdrop, logo, scores, actions (play / resume / get / versions), and episodes for shows.
struct TVTitleView: View {
    let item: CatalogItem
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @Environment(AmbientController.self) private var ambient
    @State private var model: TitleModel?
    @State private var message: String?
    @State private var working = false
    @State private var episodeChoice: EpisodeChoice?
    @State private var trailer: TrailerURL?

    var body: some View {
        ZStack {
            backdrop
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // First screen: the art, with title and actions at the bottom left.
                    header
                        .containerRelativeFrame(.vertical, alignment: .bottomLeading)
                    VStack(alignment: .leading, spacing: 50) {
                        if item.mediaType == .tv, let model { episodes(model) }
                        if let cast = model?.detail?.cast, !cast.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Cast").font(.title3.weight(.semibold))
                                Text(cast.prefix(8).map(\.name).joined(separator: " · ")).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, TVMetrics.edge)
                        }
                        if let recommendations = model?.detail?.recommendations, !recommendations.isEmpty {
                            TVCatalogShelf(row: CatalogRow(id: "more", title: "More Like This", items: recommendations))
                        }
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 80)
                    .background(Theme.background.opacity(0.92))
                }
            }
            .scrollClipDisabled()
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { ambient.focus(item) }
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let title = TitleModel(item: item, catalog: catalog, library: app.library, transfers: app.transfers,
                                   ratings: { [app] imdbID, kind in await app.ratings(imdbID: imdbID, kind: kind) },
                                   episodeRatings: { [app] imdbID, season in await app.episodeRatings(seriesIMDbID: imdbID, season: season) })
            model = title
            await title.load()
        }
        .confirmationDialog(episodeChoice?.title ?? "", isPresented: Binding(get: { episodeChoice != nil },
                                                                             set: { if !$0 { episodeChoice = nil } }),
                            titleVisibility: .visible) {
            if let choice = episodeChoice, let model { episodeActions(choice, model) }
        }
        .fullScreenCover(item: $trailer) { TVTrailerPlayer(url: $0.url).ignoresSafeArea() }
    }

    // MARK: Header

    /// Full-screen art behind the page (stays put while the page scrolls).
    private var backdrop: some View {
        ZStack {
            Theme.background
            RemoteImage(path: item.backdropPath ?? item.posterPath, size: "original", seed: item.title)
            LinearGradient(stops: [.init(color: Theme.background.opacity(0.92), location: 0),
                                   .init(color: Theme.background.opacity(0.55), location: 0.4),
                                   .init(color: .clear, location: 0.7)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: Theme.background.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let logo = model?.detail?.logoPath {
                RemoteImage(path: logo, size: "w500", seed: item.title, contentMode: .fit, alignment: .leading)
                    .frame(maxWidth: 640, maxHeight: 220, alignment: .leading)
                    .accessibilityLabel(item.title)
            } else {
                Text(item.title.uppercased()).font(.system(size: 80, weight: .ultraLight)).tracking(6)
                    .lineLimit(2).minimumScaleFactor(0.6).frame(maxWidth: 1100, alignment: .leading)
            }
            meta
            let overview = model?.detail?.item.overview.isEmpty == false ? model!.detail!.item.overview : item.overview
            if !overview.isEmpty {
                Text(overview).font(.callout).foregroundStyle(.white.opacity(0.88)).lineLimit(3)
                    .frame(maxWidth: 1000, alignment: .leading)
            }
            Group {
                if let model, item.mediaType == .movie { actions(model) } else { secondaryActions }
            }
            .labelStyle(TVActionLabelStyle())
            .padding(.top, 10)
            if let message { Text(message).font(.callout).foregroundStyle(Theme.okay) }
        }
        .padding(.horizontal, TVMetrics.edge)
        .padding(.bottom, 70)
        .focusSection()
    }

    private var meta: some View {
        HStack(spacing: 20) {
            if let year = item.year { Text(String(year)) }
            if let runtime = Format.runtime(model?.detail?.runtimeMinutes) { Text(runtime) }
            if let genres = model?.detail?.genres, !genres.isEmpty { Text(genres.prefix(3).joined(separator: " · ")) }
            RatingsBadges(ratings: model?.ratings, tmdb: model?.detail?.item.voteAverage ?? item.voteAverage)
            if !app.library.matching(tmdbID: item.tmdbID).isEmpty {
                Label("In put.io", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white.opacity(0.8))
    }

    // MARK: Movie actions

    @ViewBuilder private func actions(_ model: TitleModel) -> some View {
        HStack(alignment: .center, spacing: 24) {
            switch model.action() {
            case .get:
                Button { Task { await get(model, season: nil, episode: nil) } } label: {
                    if working { ProgressView().frame(width: 220, height: 48) } else { Label("Get & Watch", systemImage: "play.fill") }
                }
                .tvGlass(prominent: true)
                .disabled(working)
                versionsButton(model, season: nil, episode: nil)
            case let .play(entry):
                Button { router.play(entry, from: 0) } label: { Label("Play", systemImage: "play.fill") }
                    .tvGlass(prominent: true)
                versionsButton(model, season: nil, episode: nil)
            case let .resume(entry, seconds):
                Button { router.play(entry, from: seconds) } label: { Label("Resume \(Format.clock(seconds))", systemImage: "play.fill") }
                    .tvGlass(prominent: true)
                Button { router.play(entry, from: 0) } label: { Label("Start Over", systemImage: "backward.end.fill") }
                    .tvGlass()
            case let .downloading(transfer):
                TVTransferStatus(transfer: transfer)
                Button("Cancel", role: .destructive) { Task { try? await app.transfers.cancel(transfer.id) } }
                    .tvGlass()
            case let .failed(transfer):
                Text("Transfer failed").foregroundStyle(Theme.poor)
                Button {
                    app.transfers.dismiss(transfer.id)
                    openVersions(model, season: nil, episode: nil)
                } label: { Label("Try Another Version", systemImage: "arrow.triangle.2.circlepath") }
                .tvGlass(prominent: true)
            }
            secondaryActions
        }
        .padding(.top, 8)
    }

    private var secondaryActions: some View {
        HStack(spacing: 24) {
            TVMyListButton(item: item)
            if let imdbID = model?.detail?.imdbID {
                Button { Task { await playTrailer(imdbID) } } label: { Label("Trailer", systemImage: "film") }
                    .tvGlass()
            }
        }
    }

    private func versionsButton(_ model: TitleModel, season: Int?, episode: Int?) -> some View {
        Button { openVersions(model, season: season, episode: episode) } label: {
            Label("Versions", systemImage: "square.stack.3d.up")
        }
        .tvGlass()
    }

    // MARK: Episodes

    @ViewBuilder private func episodes(_ model: TitleModel) -> some View {
        let seasons = model.detail?.seasons ?? []
        VStack(alignment: .leading, spacing: 10) {
            if !seasons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(seasons, id: \.number) { season in
                            Button { Task { await model.selectSeason(season.number) } } label: {
                                Text(season.name).fontWeight(model.selectedSeason == season.number ? .bold : .regular)
                            }
                            .tvGlass(prominent: model.selectedSeason == season.number)
                        }
                    }
                    .padding(.horizontal, TVMetrics.edge)
                    .padding(.vertical, 20)
                }
                .focusSection()
            }
            if let season = model.selectedSeason {
                TVShelf(title: "Episodes") {
                    ForEach(model.episodes) { episode in
                        let resume = app.library.matching(tmdbID: item.tmdbID, season: season, episode: episode.number)
                            .map { app.library.resumeSeconds(for: $0) }.max() ?? 0
                        let rating = model.episodeRatings[episode.number].map { String(format: "IMDb %.1f", $0.rating) }
                        let inPutio = !app.library.matching(tmdbID: item.tmdbID, season: season, episode: episode.number).isEmpty
                        TVWideCard(title: "\(episode.number). \(episode.name)",
                                   subtitle: [inPutio ? (resume >= 30 ? "Resume \(Format.clock(resume))" : "In put.io") : nil,
                                              rating, Format.runtime(episode.runtimeMinutes)].compactMap { $0 }.joined(separator: " · "),
                                   imagePath: episode.stillPath, progress: nil, tintItem: nil) {
                            episodeChoice = EpisodeChoice(season: season, episode: episode.number,
                                                          title: "S\(season) · E\(episode.number) \(episode.name)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func episodeActions(_ choice: EpisodeChoice, _ model: TitleModel) -> some View {
        switch model.action(season: choice.season, episode: choice.episode) {
        case let .play(entry):
            Button("Play") { router.play(entry, from: 0) }
        case let .resume(entry, seconds):
            Button("Resume \(Format.clock(seconds))") { router.play(entry, from: seconds) }
            Button("Start Over") { router.play(entry, from: 0) }
        case .downloading:
            Button("Downloading…") {}
        case .get, .failed:
            Button("Get & Watch") { Task { await get(model, season: choice.season, episode: choice.episode) } }
            Button("Versions") { openVersions(model, season: choice.season, episode: choice.episode) }
            Button("Get Whole Season") { openVersions(model, season: choice.season, episode: nil) }
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: Actions

    private func get(_ model: TitleModel, season: Int?, episode: Int?) async {
        guard let query = model.query(season: season, episode: episode) else { return }
        guard app.settings.oneTapGet else { return openVersions(model, season: season, episode: episode) }
        working = true
        defer { working = false }
        message = "Finding the best version…"
        switch await app.smartGet(query, target: model.target(season: season, episode: episode)) {
        case .sent: message = "Sent to put.io. It plays here as soon as it's ready."
        case .noMatch:
            message = nil
            openVersions(model, season: season, episode: episode)
        case .failed:
            message = "Couldn't send it to put.io. Pick a version instead."
            openVersions(model, season: season, episode: episode)
        }
    }

    private func openVersions(_ model: TitleModel, season: Int?, episode: Int?) {
        guard let query = model.query(season: season, episode: episode) else { return }
        router.open(.versions(TVVersionsRequest(query: query, target: model.target(season: season, episode: episode),
                                                playNow: app.library.matching(tmdbID: item.tmdbID, season: season, episode: episode))))
    }

    private func playTrailer(_ imdbID: String) async {
        if let video = await app.trailer(imdbID: imdbID) {
            trailer = TrailerURL(url: video.url)
        } else {
            message = "No trailer found."
        }
    }
}

private struct EpisodeChoice: Equatable {
    let season: Int
    let episode: Int
    let title: String
}

struct TrailerURL: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Ring-free transfer progress for the TV: percentage and speed.
struct TVTransferStatus: View {
    let transfer: TrackedTransfer

    var body: some View {
        HStack(spacing: 18) {
            ProgressView(value: Double(transfer.percent), total: 100).frame(width: 260)
            Text(label).font(.callout.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch transfer.phase {
        case .queued: "Queued"
        case .finishing: "Finishing up"
        case .completed: "Preparing"
        default:
            transfer.isStalled ? "Stalled: no peers"
                : ["\(transfer.percent)%", Format.speed(transfer.transfer?.downSpeed)].compactMap { $0 }.joined(separator: " · ")
        }
    }
}
