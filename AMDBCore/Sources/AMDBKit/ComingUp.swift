import AMDBCore
import Foundation
import Observation

/// "Coming Up": what's in cinemas and the box office, and what's next on TV — your shows' next episodes first.
@Observable @MainActor
public final class ComingUpModel {
    public struct BoxOfficeItem: Identifiable, Sendable, Hashable {
        public let entry: BoxOfficeEntry
        public let item: CatalogItem
        public var id: Int { entry.rank }
    }

    /// Episodes airing on one day.
    public struct Day: Identifiable, Sendable, Hashable {
        public let date: String
        public let label: String
        public let episodes: [UpcomingEpisode]
        public var id: String { date }
    }

    public private(set) var boxOffice: [BoxOfficeItem] = []
    public private(set) var inCinemas: [CatalogItem] = []
    public private(set) var comingSoon: [DatedItem] = []
    public private(set) var yourEpisodes: [Day] = []
    public private(set) var premieringSoon: [DatedItem] = []
    public private(set) var returning: [CatalogItem] = []
    public private(set) var isLoading = false

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let catalog: any CatalogService
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var loadedMovies = false
    @ObservationIgnored private var loadedShows = false
    public static let region = "US"

    public init(app: AppModel, catalog: any CatalogService, now: @escaping @Sendable () -> Date = { Date() }) {
        self.app = app
        self.catalog = catalog
        self.now = now
    }

    public func loadMovies() async {
        guard !loadedMovies else { return }
        loadedMovies = true
        isLoading = true
        defer { isLoading = false }
        let catalog = catalog
        let today = CuratedList.day(now(), plus: 0)
        async let cinemas = try? catalog.nowPlaying(region: Self.region)
        async let upcoming = try? catalog.upcomingMovies(region: Self.region)
        async let chart = try? app.boxOffice()
        let (nowPlaying, soon, top) = await (cinemas, upcoming, chart)
        inCinemas = nowPlaying ?? []
        comingSoon = Self.upcoming(soon ?? [], after: today)
        boxOffice = await resolve(top ?? [])
    }

    public func loadShows() async {
        guard !loadedShows else { return }
        loadedShows = true
        isLoading = true
        defer { isLoading = false }
        let catalog = catalog
        let date = now()
        let today = CuratedList.day(date, plus: 0)
        let premieres = DiscoverQuery([
            "sort_by": "popularity.desc", "first_air_date.gte": today, "first_air_date.lte": CuratedList.day(date, plus: 30),
            "without_genres": CuratedList.notSeries,
        ])
        async let premiering = try? catalog.discoverDated(.tv, query: premieres)
        async let back = try? catalog.discover(.tv, query: CuratedList.returningThisWeek.query(for: .tv, today: date))
        let episodes = await nextEpisodes(of: Self.yourShows(library: app.library.entries, myList: app.myList.items))
        let (premieringSoon, returningShows) = await (premiering, back)
        yourEpisodes = Self.days(episodes, today: date)
        self.premieringSoon = Self.upcoming(premieringSoon ?? [], after: today, inclusive: true)
        returning = returningShows ?? []
    }

    // MARK: Pieces (static so they're easy to test)

    /// Shows in put.io and on My List, put.io first, each once.
    nonisolated static func yourShows(library: [LibraryEntry], myList: [SavedTitle]) -> [Int] {
        var seen: Set<Int> = []
        let fromLibrary = library.compactMap { $0.match?.mediaType == .tv ? $0.match?.tmdbID : nil }
        let fromList = myList.filter { $0.kind == .tv }.map(\.tmdbID)
        return (fromLibrary + fromList).filter { seen.insert($0).inserted }
    }

    /// Future dates only (today too when inclusive), soonest first; undated titles dropped.
    nonisolated static func upcoming(_ items: [DatedItem], after today: String, inclusive: Bool = false) -> [DatedItem] {
        items.filter { item in item.date.map { inclusive ? $0 >= today : $0 > today } ?? false }
            .sorted { ($0.date ?? "") < ($1.date ?? "") }
    }

    /// Episodes from today to 30 days out, grouped by day: Today, Tomorrow, the weekday, then "Oct 24".
    nonisolated static func days(_ episodes: [UpcomingEpisode], today: Date) -> [Day] {
        let first = CuratedList.day(today, plus: 0), last = CuratedList.day(today, plus: 30)
        let upcoming = episodes.filter { $0.airDate >= first && $0.airDate <= last }
        return Dictionary(grouping: upcoming, by: \.airDate).keys.sorted().map { date in
            Day(date: date, label: dayLabel(date, today: today),
                episodes: upcoming.filter { $0.airDate == date }.sorted { $0.show.title < $1.show.title })
        }
    }

    nonisolated static func dayLabel(_ date: String, today: Date) -> String {
        if date == CuratedList.day(today, plus: 0) { return "Today" }
        if date == CuratedList.day(today, plus: 1) { return "Tomorrow" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: date) else { return date }
        let withinWeek = (2...6).contains { CuratedList.day(today, plus: $0) == date }
        formatter.dateFormat = withinWeek ? "EEEE" : "MMM d"
        return formatter.string(from: day)
    }

    /// "Oct 24" for a release date.
    nonisolated public static func shortDate(_ date: String?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: date) else { return nil }
        formatter.dateFormat = "MMM d"
        return formatter.string(from: day)
    }

    private func nextEpisodes(of shows: [Int]) async -> [UpcomingEpisode] {
        let catalog = catalog
        let ids = Array(shows.prefix(40))
        return await withTaskGroup(of: UpcomingEpisode?.self) { group in
            var found: [UpcomingEpisode] = []
            var next = 0
            while next < min(6, ids.count) { let id = ids[next]; group.addTask { try? await catalog.nextEpisode(tvID: id) }; next += 1 }
            while let result = await group.next() {
                if let result { found.append(result) }
                if next < ids.count { let id = ids[next]; group.addTask { try? await catalog.nextEpisode(tvID: id) }; next += 1 }
            }
            return found
        }
    }

    private func resolve(_ entries: [BoxOfficeEntry]) async -> [BoxOfficeItem] {
        let catalog = catalog
        return await withTaskGroup(of: BoxOfficeItem?.self) { group in
            for entry in entries {
                group.addTask {
                    if let id = entry.tmdbID, let item = try? await catalog.item(.movie, id: id) { return BoxOfficeItem(entry: entry, item: item) }
                    let found = try? await catalog.searchMovie(title: entry.title, year: entry.year).first
                    return found.map { BoxOfficeItem(entry: entry, item: $0) }
                }
            }
            var items: [BoxOfficeItem] = []
            for await item in group { if let item { items.append(item) } }
            return items.sorted { $0.entry.rank < $1.entry.rank }
        }
    }
}
