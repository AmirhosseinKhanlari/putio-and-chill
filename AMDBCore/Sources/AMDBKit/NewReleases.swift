import AMDBCore
import Foundation

/// The freshest row on the Movies and TV Shows tabs, straight from TMDB: movies that just came out to stream or
/// buy, and shows with an episode out this week.
public enum NewReleases {
    public static func title(for kind: MediaKind) -> String {
        kind == .tv ? "New Episodes This Week" : "New to Stream"
    }

    /// Movies: a digital (4) or physical (5) release in `region` in the last 45 days, newest first, with at least ten
    /// votes (TMDB lists many releases nobody has seen yet). Shows: an episode aired in the last seven days, most
    /// popular first, without talk, news, reality and soaps (daily shows would fill the row).
    public static func query(for kind: MediaKind, today: Date, region: String) -> DiscoverQuery {
        let day = { (offset: Int) in CuratedList.day(today, plus: offset) }
        if kind == .tv {
            return DiscoverQuery(["air_date.gte": day(-7), "air_date.lte": day(0), "sort_by": "popularity.desc",
                                  "without_genres": CuratedList.notSeries, "vote_count.gte": "10"])
        }
        return DiscoverQuery(["with_release_type": "4|5", "region": region, "release_date.gte": day(-45),
                              "release_date.lte": day(0), "sort_by": "release_date.desc", "vote_count.gte": "10"])
    }

    /// Where release dates are read for: the device's region, else the US.
    public static var deviceRegion: String {
        Locale.current.region?.identifier.uppercased().nilIfEmpty ?? "US"
    }

    /// The row's titles; a region TMDB has no releases for falls back to the US.
    static func load(_ kind: MediaKind, catalog: any CatalogService, today: Date, region: String) async -> CatalogRow? {
        var items = (try? await catalog.discover(kind, query: query(for: kind, today: today, region: region))) ?? []
        if items.isEmpty, kind == .movie, region != "US" {
            items = (try? await catalog.discover(kind, query: query(for: kind, today: today, region: "US"))) ?? []
        }
        return items.isEmpty ? nil : CatalogRow(id: "new", title: title(for: kind), items: items)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
