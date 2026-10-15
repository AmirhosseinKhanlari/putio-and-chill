import AMDBCore
import AMDBKit
import SwiftUI

/// On tvOS 27 and later the sidebar also shows your put.io account and free space above the tabs.
struct TVSidebarAccountHeader: ViewModifier {
    let name: String
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        if #available(tvOS 27.0, *) {
            content.tabViewSidebarHeader {
                HStack(spacing: 14) {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 24, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.95), Color(red: 1, green: 0.45, blue: 0.3)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                        if let disk = app.storage.disk {
                            Text("\(Format.bytes(disk.avail)) free").font(.system(size: 18)).foregroundStyle(TVMetrics.secondaryText)
                        }
                    }
                }
            }
        } else {
            content
        }
    }
}

/// A genre in the sidebar's Browse section, with the matching TMDB genre for movies and for shows.
struct TVGenre: Identifiable, Hashable {
    let id: Int
    let name: String
    let symbol: String
    let movieGenre: Int
    let tvGenre: Int?

    static let all: [TVGenre] = [
        TVGenre(id: 28, name: "Action", symbol: "flame", movieGenre: 28, tvGenre: 10759),
        TVGenre(id: 35, name: "Comedy", symbol: "face.smiling", movieGenre: 35, tvGenre: 35),
        TVGenre(id: 18, name: "Drama", symbol: "theatermasks", movieGenre: 18, tvGenre: 18),
        TVGenre(id: 878, name: "Sci-Fi", symbol: "sparkles", movieGenre: 878, tvGenre: 10765),
        TVGenre(id: 80, name: "Crime", symbol: "magnifyingglass.circle", movieGenre: 80, tvGenre: 80),
        TVGenre(id: 53, name: "Thriller", symbol: "bolt.heart", movieGenre: 53, tvGenre: 9648),
        TVGenre(id: 27, name: "Horror", symbol: "moon.haze", movieGenre: 27, tvGenre: nil),
        TVGenre(id: 16, name: "Animation", symbol: "paintpalette", movieGenre: 16, tvGenre: 16),
        TVGenre(id: 99, name: "Documentary", symbol: "film.stack", movieGenre: 99, tvGenre: 99),
    ]
}

/// One genre: popular and highly rated movies and shows.
struct TVGenreView: View {
    let genre: TVGenre
    @Environment(AppModel.self) private var app
    @State private var rows: [CatalogRow] = []
    @State private var loaded = false

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 30) {
                TVPageHeader(title: genre.name).padding(.horizontal, TVMetrics.edge)
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(.top, 80) }
                ForEach(rows) { TVCatalogShelf(row: $0) }
            }
            .padding(.vertical, 40)
        }
        .tvPageBackground()
        .task(id: genre.id) { await load() }
    }

    private func load() async {
        guard let catalog = app.catalog else { return }
        let genre = genre
        async let movies = try? catalog.discover(.movie, genreID: genre.movieGenre)
        async let topMovies = try? catalog.discover(.movie, genreIDs: [genre.movieGenre], minRating: 7.5, minVotes: 1000, page: 1).items
        async let shows: [CatalogItem]? = if let tv = genre.tvGenre { try? await catalog.discover(.tv, genreID: tv) } else { nil }
        async let topShows: [CatalogItem]? = if let tv = genre.tvGenre {
            try? await catalog.discover(.tv, genreIDs: [tv], minRating: 7.5, minVotes: 300, page: 1).items
        } else { nil }
        let candidates: [(String, String, [CatalogItem]?)] = [
            ("movies", "Popular Movies", await movies), ("shows", "Popular Shows", await shows),
            ("topMovies", "Highly Rated Movies", await topMovies), ("topShows", "Highly Rated Shows", await topShows),
        ]
        rows = candidates.compactMap { id, title, items in
            guard let items, !items.isEmpty else { return nil }
            return CatalogRow(id: "\(genre.id)-\(id)", title: title, items: items)
        }
        loaded = true
    }
}

/// The connected IMDb watchlist as a grid.
struct TVIMDbWatchlistView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router

    var body: some View {
        let watchlist = app.imdbWatchlist
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 34) {
                TVPageHeader(title: "IMDb Watchlist", subtitle: subtitle)
                if !watchlist.isConnected {
                    TVIMDbConnect()
                } else {
                    Button { Task { await app.imdbWatchlist.load(force: true) } } label: {
                        Label(watchlist.isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .tvPill()
                    .disabled(watchlist.isLoading)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.poster.width), spacing: 40), count: 6),
                          alignment: .leading, spacing: 50) {
                    ForEach(watchlist.items) { item in TVPosterButton(item: item) { router.open(item) } }
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.vertical, 40)
        }
        .tvPageBackground()
        .task { await app.imdbWatchlist.load() }
    }

    private var subtitle: String? {
        let watchlist = app.imdbWatchlist
        guard watchlist.isConnected else { return nil }
        if let problem = watchlist.problem { return problem }
        return watchlist.isLoading && watchlist.items.isEmpty ? "Loading…" : "\(watchlist.items.count) titles"
    }
}

/// Everything on its way to put.io: progress, and hold Select to cancel. Finished ones play.
struct TVTransfersView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router

    var body: some View {
        let transfers = app.transfers.tracked
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 34) {
                TVPageHeader(title: "Downloading to put.io",
                             subtitle: transfers.isEmpty ? "Nothing on its way. Get & Watch on any title sends it here." : "Hold Select to cancel")
                // Something to select on an empty page (otherwise the remote has nowhere to go).
                if transfers.isEmpty {
                    Button { router.select(.home) } label: { Label("Find Something to Watch", systemImage: "house") }.tvPill()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.wide.width), spacing: 40), count: 3),
                          alignment: .leading, spacing: 50) {
                    ForEach(transfers) { transfer in card(transfer) }
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.vertical, 40)
        }
        .tvPageBackground()
    }

    private func card(_ transfer: TrackedTransfer) -> some View {
        let ready = transfer.playableFile != nil
        let failed = if case .failed = transfer.phase { true } else { false }
        let pending = transfer.pending
        let episode = pending.season.map { "S\($0)" + (pending.episode.map { " E\($0)" } ?? "") + " · " } ?? ""
        let status = ready ? "Ready to watch" : failed ? "Didn't download"
            : transfer.isStalled ? "Stalled: no peers" : ["\(transfer.percent)%", Format.speed(transfer.transfer?.downSpeed)].compactMap { $0 }.joined(separator: " · ")
        return TVWideCard(title: pending.title, subtitle: episode + status, imagePath: pending.backdropPath ?? pending.posterPath,
                          progress: ready || failed ? nil : Double(transfer.percent) / 100) {
            if ready {
                router.playTransfer(transfer)
            } else {
                router.open(CatalogItem(tmdbID: pending.tmdbID, mediaType: pending.kind, title: pending.title,
                                        posterPath: pending.posterPath, backdropPath: pending.backdropPath))
            }
        }
        .contextMenu {
            if ready || failed {
                Button("Remove from List") { app.transfers.dismiss(transfer.id) }
            } else {
                Button("Cancel Download", role: .destructive) { Task { try? await app.transfers.cancel(transfer.id) } }
            }
        }
    }
}

/// Connect an IMDb watchlist on the TV: the link can be typed with the iPhone's keyboard (tvOS offers it when a text
/// field is selected), or the watchlist connected on the iPhone shows up here by itself.
struct TVIMDbConnect: View {
    @Environment(AppModel.self) private var app
    @State private var link = ""
    @State private var problem: String?
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Paste your IMDb watchlist link. Select the field and your iPhone offers its keyboard, or connect it on your iPhone or iPad (Settings → Connected Services → IMDb) and it appears here.")
                .font(.system(size: 26)).foregroundStyle(TVMetrics.secondaryText).frame(maxWidth: 1200, alignment: .leading)
            HStack(spacing: 24) {
                TextField("imdb.com/user/…/watchlist", text: $link)
                    .textContentType(.URL)
                    .frame(width: 900)
                    .onSubmit { connect() }
                Button { connect() } label: {
                    Label(connecting ? "Connecting…" : "Connect", systemImage: "link")
                }
                .tvPill()
                .disabled(connecting || link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem { Text(problem).font(.system(size: 24)).foregroundStyle(Theme.okay) }
        }
    }

    private func connect() {
        guard !connecting else { return }
        connecting = true
        Task {
            problem = await app.connectIMDb(link)
            connecting = false
            if problem == nil { link = "" }
        }
    }
}
