import AMDBCore
import AMDBKit
import SwiftUI

/// A movie or show: full-screen art; logo, details, scores and actions at the bottom left; then episodes,
/// cast & crew (round photos → person pages), the collection, and more like this.
struct TVTitleView: View {
    let item: CatalogItem
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var model: TitleModel?

    var body: some View {
        ZStack {
            TVBackdrop(path: model?.detail?.item.backdropPath ?? item.backdropPath ?? item.posterPath, seed: item.title)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // Shows: the header takes a little over half the screen so the seasons and episodes are in view.
                    header.containerRelativeFrame(.vertical, alignment: .bottomLeading) { height, _ in
                        item.mediaType == .tv ? height * 0.6 : height
                    }
                    VStack(alignment: .leading, spacing: 30) {
                        if item.mediaType == .tv, let model { TVEpisodes(model: model, item: item) }
                        castAndCrew
                        if let recommendations = model?.detail?.recommendations, !recommendations.isEmpty {
                            TVCatalogShelf(row: CatalogRow(id: "more", title: "More Like This", items: recommendations))
                        }
                    }
                    .padding(.top, 30)
                    .padding(.bottom, 90)
                    .background {
                        // Fades up into the art so there's no hard edge under the header.
                        Color.black.overlay(alignment: .top) {
                            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 220).offset(y: -220)
                        }
                        .ignoresSafeArea(edges: .horizontal)
                    }
                }
            }
            .scrollClipDisabled()
        }
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let title = TitleModel(item: item, catalog: catalog, library: app.library, transfers: app.transfers,
                                   ratings: { [app] imdbID, kind in await app.ratings(imdbID: imdbID, kind: kind) },
                                   episodeRatings: { [app] imdbID, season in await app.episodeRatings(seriesIMDbID: imdbID, season: season) })
            model = title
            await title.load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            TVTitleArt(item: item, logoPath: model?.detail?.logoPath)
            TVMetaLine(item: item, detail: model?.detail,
                       extra: app.library.matching(tmdbID: item.tmdbID).isEmpty ? [] : ["In put.io"])
            TVRatingsLine(ratings: model?.ratings, tmdb: model?.detail?.item.voteAverage ?? item.voteAverage)
            let overview = model?.detail?.item.overview.isEmpty == false ? model!.detail!.item.overview : item.overview
            if !overview.isEmpty {
                Text(overview).font(.system(size: 26)).foregroundStyle(.white.opacity(0.86)).lineLimit(3)
                    .frame(maxWidth: 940, alignment: .leading)
            }
            if let model { TVTitleActions(model: model, item: item).padding(.top, 14) }
            if let collection = model?.detail?.collection {
                Button { router.open(.collection(collection.id)) } label: {
                    Label("Part of the \(collection.name) · Watch in order", systemImage: "square.stack")
                }
                .tvPill()
            }
        }
        .padding(.horizontal, TVMetrics.edge)
        .padding(.bottom, 80)
        .focusSection()
    }

    @ViewBuilder private var castAndCrew: some View {
        let cast = model?.detail?.cast ?? []
        let crew = (model?.detail?.crew ?? []).prefix(2)
        if !cast.isEmpty || !crew.isEmpty {
            TVShelf(title: "Cast & Crew") {
                ForEach(Array(cast.prefix(14).enumerated()), id: \.offset) { _, member in
                    TVCastCircle(member: member) { if let id = member.id { router.open(.person(id)) } }
                }
                ForEach(Array(crew.enumerated()), id: \.offset) { _, member in
                    TVCastCircle(member: member, role: member.character ?? "Director") { if let id = member.id { router.open(.person(id)) } }
                }
            }
        }
    }
}

/// Play / Resume / Get & Watch / progress, then Versions, My List and Trailer — shared by title pages and Home's hero.
struct TVTitleActions: View {
    let model: TitleModel
    let item: CatalogItem
    var showsDetails = false
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var working = false
    @State private var message: String?
    @State private var trailer: TrailerURL?
    /// The main button (Play / Resume / Get & Watch) takes focus first, as in Apple's TV app.
    @FocusState private var primaryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 22) {
                if item.mediaType == .movie {
                    primary
                } else {
                    showPrimary
                    if showsDetails {
                        Button { router.open(item) } label: { Label("Episodes", systemImage: "list.bullet") }.tvPill()
                            .focused($primaryFocused)
                    }
                }
                TVMyListCircle(item: item)
                if let imdbID = model.detail?.imdbID {
                    Button { Task { await playTrailer(imdbID) } } label: { Image(systemName: "film") }
                        .tvCircle().accessibilityLabel("Trailer")
                }
                if showsDetails {
                    Button { router.open(item) } label: { Image(systemName: "ellipsis") }
                        .tvCircle().accessibilityLabel("More info")
                }
            }
            if let message { Text(message).font(.system(size: 22)).foregroundStyle(TVMetrics.secondaryText) }
        }
        .defaultFocus($primaryFocused, true)
        .fullScreenCover(item: $trailer) { TVTrailerPlayer(url: $0.url).ignoresSafeArea() }
    }

    /// Shows: resume where you left off, else the first episode you have in put.io.
    @ViewBuilder private var showPrimary: some View {
        if let entry = app.library.continueWatching.first(where: { $0.match?.tmdbID == item.tmdbID }) {
            let seconds = app.library.resumeSeconds(for: entry)
            Button { router.play(entry, from: seconds) } label: {
                Label("Resume \(Self.episodeLabel(entry))", systemImage: "play.fill")
            }
            .tvPill().focused($primaryFocused)
        } else if let first = app.library.matching(tmdbID: item.tmdbID).min(by: Self.episodeOrder) {
            Button { router.play(first, from: 0) } label: { Label("Play \(Self.episodeLabel(first))", systemImage: "play.fill") }
                .tvPill().focused($primaryFocused)
        }
    }

    static func episodeLabel(_ entry: LibraryEntry) -> String {
        guard let season = entry.match?.season else { return "" }
        return "S\(season)" + (entry.match?.episode.map { " E\($0)" } ?? "")
    }

    static func episodeOrder(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        (a.match?.season ?? 0, a.match?.episode ?? 0) < (b.match?.season ?? 0, b.match?.episode ?? 0)
    }

    @ViewBuilder private var primary: some View {
        switch model.action() {
        case .get:
            Button { Task { await get() } } label: {
                if working { Label("Finding the best version…", systemImage: "hourglass") } else { Label("Get & Watch", systemImage: "play.fill") }
            }
            .tvPill().disabled(working).focused($primaryFocused)
            Button { openVersions() } label: { Label("Versions", systemImage: "square.stack.3d.up") }.tvPill()
        case let .play(entry):
            Button { router.play(entry, from: 0) } label: { Label("Play", systemImage: "play.fill") }.tvPill().focused($primaryFocused)
            Button { openVersions() } label: { Label("Versions", systemImage: "square.stack.3d.up") }.tvPill()
        case let .resume(entry, seconds):
            Button { router.play(entry, from: seconds) } label: { Label("Resume \(Format.clock(seconds))", systemImage: "play.fill") }.tvPill()
                .focused($primaryFocused)
            Button { router.play(entry, from: 0, exactStart: true) } label: { Image(systemName: "arrow.counterclockwise") }
                .tvCircle().accessibilityLabel("Start over")
        case let .downloading(transfer):
            TVTransferStatus(transfer: transfer)
            Button("Cancel") { Task { try? await app.transfers.cancel(transfer.id) } }.tvPill()
        case let .failed(transfer):
            Button {
                app.transfers.dismiss(transfer.id)
                openVersions()
            } label: { Label("Try Another Version", systemImage: "arrow.triangle.2.circlepath") }.tvPill()
                .focused($primaryFocused)
        }
    }

    private func get() async {
        guard let query = model.query() else {
            message = model.queryUnavailableMessage
            return
        }
        guard app.settings.oneTapGet else { return openVersions() }
        working = true
        defer { working = false }
        switch await app.smartGet(query, target: model.target()) {
        case .sent: message = "Sent to put.io. It'll play here as soon as it's ready."
        case .noMatch: openVersions()
        case .failed:
            message = "Couldn't send it to put.io. Pick a version instead."
            openVersions()
        }
    }

    private func openVersions() {
        guard let query = model.query() else {
            message = model.queryUnavailableMessage
            return
        }
        router.open(.versions(TVVersionsRequest(query: query, target: model.target(),
                                                playNow: app.library.matching(tmdbID: item.tmdbID))))
    }

    private func playTrailer(_ imdbID: String) async {
        if let video = await app.trailer(imdbID: imdbID) { trailer = TrailerURL(url: video.url) } else { message = "No trailer found." }
    }
}

/// ＋ / ✓ My List as a round button.
struct TVMyListCircle: View {
    let item: CatalogItem
    @Environment(AppModel.self) private var app

    var body: some View {
        let saved = app.myList.contains(item)
        Button { Task { await app.myList.toggle(item) } } label: { Image(systemName: saved ? "checkmark" : "plus") }
            .tvCircle()
            .accessibilityLabel(saved ? "Remove from My List" : "Add to My List")
    }
}

/// Seasons and episodes: IMDb score per episode, best of season, resume points; choose to play, get or pick a version.
struct TVEpisodes: View {
    let model: TitleModel
    let item: CatalogItem
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var message: String?
    /// Episodes being looked up (Get & Watch) before put.io starts downloading them.
    @State private var searching: Set<Int> = []
    @State private var deleting: [LibraryEntry] = []

    var body: some View {
        let seasons = model.detail?.seasons ?? []
        VStack(alignment: .leading, spacing: 6) {
            if !seasons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(seasons, id: \.number) { season in
                            Button { Task { await model.selectSeason(season.number) } } label: {
                                if model.selectedSeason == season.number {
                                    Label(season.name, systemImage: "checkmark")
                                } else {
                                    Text(season.name)
                                }
                            }
                            .tvPill()
                        }
                    }
                    .padding(.horizontal, TVMetrics.edge).padding(.vertical, 20)
                }
                .focusSection()
            }
            if let message { Text(message).font(.system(size: 22)).foregroundStyle(TVMetrics.secondaryText).padding(.horizontal, TVMetrics.edge) }
            if let season = model.selectedSeason {
                TVShelf(title: "Episodes", trailing: AnyView(Text("Hold Select for more").font(.system(size: 20)).foregroundStyle(TVMetrics.secondaryText))) {
                    ForEach(model.episodes) { episode in
                        let entries = app.library.matching(tmdbID: item.tmdbID, season: season, episode: episode.number)
                        let resume = entries.map { app.library.resumeSeconds(for: $0) }.max() ?? 0
                        let action = model.action(season: season, episode: episode.number)
                        TVEpisodeCard(title: "\(episode.number). \(episode.name)",
                                      subtitle: subtitle(episode, action: action, resume: resume),
                                      imagePath: episode.stillPath ?? item.backdropPath,
                                      state: cardState(action, searching: searching.contains(episode.number)),
                                      watched: episode.runtimeMinutes.map { Double(resume) / Double($0 * 60) }) {
                            tap(action, season: season, episode: episode.number)
                        } menu: {
                            menu(action, season: season, episode: episode.number, entries: entries)
                        }
                    }
                }
            }
        }
        .alert(deleting.count == 1 ? "Delete this episode from put.io?" : "Delete \(deleting.count) files from put.io?",
               isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                let doomed = deleting
                Task { try? await app.library.delete(doomed); await app.storage.refresh() }
            }
        } message: {
            Text("It goes to put.io's Trash.")
        }
    }

    private func subtitle(_ episode: Episode, action: TitleAction, resume: Int) -> String {
        var parts: [String] = []
        switch action {
        case .resume: parts.append("Resume \(Format.clock(resume))")
        case .play: parts.append("In put.io")
        case let .downloading(transfer): parts.append("Getting · \(transfer.percent)%")
        case .failed: parts.append("Didn't download · choose another version")
        case .get: break
        }
        if let score = model.episodeRatings[episode.number] { parts.append(String(format: "IMDb %.1f", score.rating)) }
        if let runtime = Format.runtime(episode.runtimeMinutes) { parts.append(runtime) }
        if isBest(episode.number) { parts.append("Best of season") }
        return parts.joined(separator: " · ")
    }

    private func isBest(_ number: Int) -> Bool {
        let scores = model.episodeRatings
        guard scores.count >= 3, let mine = scores[number]?.rating else { return false }
        return scores.values.allSatisfy { $0.rating <= mine } && scores.values.filter { $0.rating == mine }.count == 1
    }

    private func cardState(_ action: TitleAction, searching: Bool) -> TVEpisodeState {
        if searching { return .searching }
        switch action {
        case .play, .resume: return .ready
        case let .downloading(transfer): return .downloading(Double(transfer.percent) / 100)
        case .failed: return .failed
        case .get: return .notInPutio
        }
    }

    /// Select: plays what's in put.io; gets what isn't (progress shows on the card, then select plays it).
    private func tap(_ action: TitleAction, season: Int, episode: Int) {
        switch action {
        case let .play(entry): router.play(entry, from: 0)
        case let .resume(entry, seconds): router.play(entry, from: seconds)
        case .downloading: message = "Still downloading to put.io. It plays as soon as it's ready."
        case .failed: openVersions(season, episode)
        case .get:
            if app.settings.oneTapGet { Task { await get(season, episode) } } else { openVersions(season, episode) }
        }
    }

    /// Hold Select: everything else for the episode.
    @ViewBuilder private func menu(_ action: TitleAction, season: Int, episode: Int, entries: [LibraryEntry]) -> some View {
        switch action {
        case let .play(entry):
            Button("Play") { router.play(entry, from: 0) }
        case let .resume(entry, seconds):
            Button("Resume \(Format.clock(seconds))") { router.play(entry, from: seconds) }
            Button("Start Over") { router.play(entry, from: 0, exactStart: true) }
        case let .downloading(transfer):
            Button("Cancel Download", role: .destructive) { Task { try? await app.transfers.cancel(transfer.id) } }
        case .get, .failed:
            Button("Get & Watch") { Task { await get(season, episode) } }
        }
        Button(entries.isEmpty ? "Choose Version" : "Other Versions") { openVersions(season, episode) }
        Button("Get Whole Season") { openVersions(season, nil) }
        if !entries.isEmpty {
            Button(entries.count == 1 ? "Delete from put.io" : "Delete \(entries.count) Versions from put.io", role: .destructive) {
                deleting = entries
            }
        }
    }

    private func get(_ season: Int, _ episode: Int) async {
        guard !searching.contains(episode) else { return }
        guard let query = model.query(season: season, episode: episode) else {
            message = model.queryUnavailableMessage
            return
        }
        searching.insert(episode)
        defer { searching.remove(episode) }
        message = nil
        switch await app.smartGet(query, target: model.target(season: season, episode: episode)) {
        case .sent: break
        case .noMatch, .failed: openVersions(season, episode)
        }
    }

    private func openVersions(_ season: Int, _ episode: Int?) {
        guard let query = model.query(season: season, episode: episode) else {
            message = model.queryUnavailableMessage
            return
        }
        router.open(.versions(TVVersionsRequest(query: query, target: model.target(season: season, episode: episode),
                                                playNow: app.library.matching(tmdbID: item.tmdbID, season: season, episode: episode))))
    }
}

/// An episode: its still with what state it's in (a ring while it downloads to put.io, a check once it's there,
/// how much was watched); select does the obvious thing, hold Select shows the rest.
enum TVEpisodeState: Equatable {
    case notInPutio, searching, downloading(Double), ready, failed
}

struct TVEpisodeCard<Menu: View>: View {
    let title: String
    let subtitle: String
    let imagePath: String?
    let state: TVEpisodeState
    /// Fraction watched, for the bar along the bottom.
    let watched: Double?
    let action: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: action) {
                RemoteImage(path: imagePath, size: "w780", seed: title)
                    .frame(width: TVMetrics.wide.width, height: TVMetrics.wide.height)
                    .overlay { overlay }
                    .overlay(alignment: .bottom) {
                        if let watched, watched > 0.02, state == .ready {
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(.white).frame(width: (TVMetrics.wide.width - 40) * min(watched, 1))
                            }
                            .frame(height: 6)
                            .padding(.horizontal, 20).padding(.bottom, 16)
                        }
                    }
            }
            .buttonStyle(.card)
            .contextMenu { menu() }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 23, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 20)).foregroundStyle(TVMetrics.secondaryText).lineLimit(1)
            }
            .frame(width: TVMetrics.wide.width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var overlay: some View {
        switch state {
        case .searching:
            ZStack {
                Color.black.opacity(0.55)
                ProgressView().scaleEffect(1.4)
            }
        case let .downloading(progress):
            ZStack {
                Color.black.opacity(0.55)
                ProgressRing(progress: progress, lineWidth: 8)
                    .frame(width: 96, height: 96)
                    .overlay { Text("\(Int(progress * 100))%").font(.system(size: 26, weight: .bold).monospacedDigit()) }
            }
        case .ready:
            Image(systemName: "play.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white, .black.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
        case .notInPutio:
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 26, weight: .semibold))
                .padding(10)
                .background(.black.opacity(0.45), in: Circle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
        }
    }
}

struct TrailerURL: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Transfer progress for the TV: bar, percentage and speed.
struct TVTransferStatus: View {
    let transfer: TrackedTransfer

    var body: some View {
        HStack(spacing: 18) {
            ProgressView(value: Double(transfer.percent), total: 100).frame(width: 260).tint(.white)
            Text(label).font(.system(size: 24, weight: .medium).monospacedDigit())
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
