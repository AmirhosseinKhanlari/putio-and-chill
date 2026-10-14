import AMDBCore
import Foundation

/// Themed TMDB lists for the Movies and TV Shows tabs (New on Netflix, New Series, Returning This Week, …).
public enum CuratedList: String, CaseIterable, Sendable {
    case newOnNetflix, newOnDisney, newSeries, returningThisWeek, criticallyAcclaimed

    public var title: String {
        switch self {
        case .newOnNetflix: "New on Netflix"
        case .newOnDisney: "New on Disney+"
        case .newSeries: "New Series"
        case .returningThisWeek: "Returning This Week"
        case .criticallyAcclaimed: "Critically Acclaimed"
        }
    }

    /// New Series and Returning This Week are about shows only.
    public func applies(to kind: MediaKind) -> Bool {
        switch self {
        case .newSeries, .returningThisWeek: kind == .tv
        default: kind == .movie || kind == .tv
        }
    }

    /// TMDB watch-provider ids (US catalog) for movies; network ids for each service's own shows.
    static let netflix = "8", disneyPlus = "337"
    static let netflixNetwork = "213", disneyPlusNetwork = "2739"
    /// Talk, News, Reality and Soap: daily shows that would crowd out series in the TV lists.
    public static let notSeries = "10767|10763|10764|10766"

    /// TMDB /discover filters for this list. Streaming lists use the US catalog.
    public func query(for kind: MediaKind, today: Date, region: String = "US") -> DiscoverQuery {
        let day = { (offset: Int) in Self.day(today, plus: offset) }
        let releasedAfter = kind == .tv ? "first_air_date.gte" : "primary_release_date.gte"
        let releasedBefore = kind == .tv ? "first_air_date.lte" : "primary_release_date.lte"
        var parameters = ["sort_by": "popularity.desc"]
        switch self {
        case .newOnNetflix, .newOnDisney:
            if kind == .tv {
                // The service's own shows with episodes out in the last month: new shows and new seasons. (By watch
                // provider this would be network reruns like Law & Order that also stream there.)
                parameters["with_networks"] = self == .newOnNetflix ? Self.netflixNetwork : Self.disneyPlusNetwork
                parameters["air_date.gte"] = day(-30)
                parameters["air_date.lte"] = day(0)
                parameters["without_genres"] = Self.notSeries
            } else {
                parameters["with_watch_providers"] = self == .newOnNetflix ? Self.netflix : Self.disneyPlus
                parameters["watch_region"] = region
                parameters["with_watch_monetization_types"] = "flatrate"
                parameters[releasedAfter] = day(-120)
                parameters[releasedBefore] = day(0)
            }
        case .newSeries:
            parameters[releasedAfter] = day(-60)
            parameters[releasedBefore] = day(0)
            parameters["vote_count.gte"] = "5"
            parameters["without_genres"] = Self.notSeries
        case .returningThisWeek:
            // Episodes airing in the next seven days of shows that premiered over three months ago.
            parameters["air_date.gte"] = day(0)
            parameters["air_date.lte"] = day(7)
            parameters[releasedBefore] = day(-90)
            parameters["without_genres"] = Self.notSeries
            parameters["vote_count.gte"] = "50"
        case .criticallyAcclaimed:
            // Highly rated with plenty of votes, from the last five years (Top Rated covers all time).
            parameters["sort_by"] = "vote_average.desc"
            parameters["vote_average.gte"] = kind == .tv ? "8.0" : "7.5"
            parameters["vote_count.gte"] = kind == .tv ? "300" : "1000"
            parameters[releasedAfter] = day(-5 * 365)
        }
        return DiscoverQuery(parameters)
    }

    public static func day(_ date: Date, plus days: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let shifted = calendar.date(byAdding: .day, value: days, to: date) ?? date
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
