import AMDBCore
import Foundation
import Observation

/// MDBList's charts (Top 10 on Streaming Today, Trending, …) and lists (Popular, Curated) for the Movies and TV tabs.
/// Each is asked for once and kept for `maxAge`; nothing shows without an MDBList key.
@Observable @MainActor
public final class MDBLists {
    public struct ChartKey: Hashable, Sendable {
        public let chart: MDBListChart
        public let kind: MediaKind
        public init(_ chart: MDBListChart, _ kind: MediaKind) { self.chart = chart; self.kind = kind }
    }

    /// The charts that get a row of their own on the Movies and TV tabs; the rest are in Lists.
    public static let rowCharts: [MDBListChart] = [.streamingTop10, .trending, .anticipated]
    /// The charts on the Lists page, in this order.
    public static let pageCharts: [MDBListChart] = [.mostWatchedWeek, .popular, .moviemeter, .mostWatched, .streamingCharts]

    public private(set) var charts: [ChartKey: [MDBListTitle]] = [:]
    public private(set) var popular: [MDBList] = []
    public private(set) var curated: [MDBList] = []
    /// Lists that couldn't be loaded the last time they were asked for.
    public private(set) var listsFailed = false
    public var isAvailable: Bool { service != nil }

    @ObservationIgnored private var service: (any ListsService)?
    @ObservationIgnored private var loadedAt: [String: Date] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let maxAge: TimeInterval
    @ObservationIgnored private let hidesRipLists: Bool

    /// `hidesRipLists`: leave out lists about releases and rips ("Latest 4K REMUX Releases") — for Chill Player.
    public init(maxAge: TimeInterval = 3 * 3600, hidesRipLists: Bool = false) {
        self.maxAge = maxAge
        self.hidesRipLists = hidesRipLists
    }

    /// The service with the current key. The lists are public, so what was loaded stays unless there's no key now.
    func use(_ service: (any ListsService)?) {
        self.service = service
        guard service == nil else { return }
        charts = [:]
        popular = []
        curated = []
        loadedAt = [:]
    }

    public func titles(_ chart: MDBListChart, _ kind: MediaKind) -> [MDBListTitle] { charts[ChartKey(chart, kind)] ?? [] }

    /// Popular and curated lists for a tab: lists of that kind and lists with both.
    public func lists(for kind: MediaKind) -> (popular: [MDBList], curated: [MDBList]) {
        (popular.filter { $0.kind == nil || $0.kind == kind }, curated.filter { $0.kind == nil || $0.kind == kind })
    }

    public func loadChart(_ chart: MDBListChart, kind: MediaKind, now: Date = Date()) async {
        let key = "chart-\(chart.rawValue)-\(kind.rawValue)"
        guard let service, start(key, now: now) else { return }
        defer { loading.remove(key) }
        guard let titles = try? await service.chart(chart, kind: kind) else { return }
        charts[ChartKey(chart, kind)] = titles
        loadedAt[key] = now
    }

    /// The rows' charts for a tab, together.
    public func loadRows(kind: MediaKind, now: Date = Date()) async {
        await withTaskGroup(of: Void.self) { group in
            for chart in Self.rowCharts { group.addTask { await self.loadChart(chart, kind: kind, now: now) } }
        }
    }

    public func loadLists(now: Date = Date()) async {
        let key = "lists"
        guard let service, start(key, now: now) else { return }
        defer { loading.remove(key) }
        async let top = try? service.popularLists()
        async let picked = try? service.curatedLists()
        let (foundPopular, foundCurated) = await (top, picked)
        listsFailed = foundPopular == nil && foundCurated == nil
        guard !listsFailed else { return }
        if let foundPopular { popular = foundPopular.filter(keeps) }
        if let foundCurated { curated = foundCurated.filter(keeps) }
        loadedAt[key] = now
    }

    /// A list's titles, `limit` at a time (not kept: the list page holds them).
    public func items(of list: MDBList, offset: Int, limit: Int = 60) async throws -> MDBListPage {
        guard let service else { throw AppError.unauthorized(service: "mdblist") }
        return try await service.items(of: list.id, offset: offset, limit: limit)
    }

    /// Whether `key` should be loaded now: not already loading, and not loaded within `maxAge`.
    private func start(_ key: String, now: Date) -> Bool {
        guard !loading.contains(key) else { return false }
        if let at = loadedAt[key], now.timeIntervalSince(at) < maxAge { return false }
        loading.insert(key)
        return true
    }

    private func keeps(_ list: MDBList) -> Bool { list.count > 0 && !(hidesRipLists && Self.isAboutRips(list.name)) }

    /// "Latest 4K REMUX Releases", "Dolby Vision P7-FEL", "WEB-DL": lists about which files exist, not about titles.
    public static func isAboutRips(_ name: String) -> Bool {
        name.range(of: #"\b(remux|rips?|torrents?|web-?dl|blu-?ray|bdrip|p7|fel|dolby vision|4k releases?)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// One list's titles, page by page (the list page).
@Observable @MainActor
public final class MDBListModel {
    public let list: MDBList
    public private(set) var titles: [MDBListTitle] = []
    public private(set) var hasMore = true
    public private(set) var isLoading = false
    public private(set) var failed = false
    @ObservationIgnored private let lists: MDBLists

    public init(list: MDBList, lists: MDBLists) {
        self.list = list
        self.lists = lists
    }

    /// The next page, when there is one and none is loading.
    public func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await lists.items(of: list, offset: offset, limit: Self.pageSize)
            // Counted in MDBList's rows: titles left out (adult, no TMDB id) still take a place.
            offset += Self.pageSize
            let known = Set(titles.map(\.id))
            titles += page.titles.filter { !known.contains($0.id) }
            hasMore = page.hasMore
            failed = false
        } catch {
            failed = true
        }
    }

    static let pageSize = 60
    @ObservationIgnored private var offset = 0
}
