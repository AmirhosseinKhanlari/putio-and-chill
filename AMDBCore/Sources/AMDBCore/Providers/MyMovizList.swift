import Foundation

/// A movie or show from a site's list of newest titles (MyMoviz), before it is matched to TMDB.
public struct LatestTitle: Sendable, Hashable, Codable {
    public let imdbID: String?
    public let title: String
    public let year: Int?
    public let kind: MediaKind
    public let source: String

    public init(imdbID: String?, title: String, year: Int?, kind: MediaKind, source: String) {
        self.imdbID = imdbID; self.title = title; self.year = year; self.kind = kind; self.source = source
    }

    /// Same title across lists: IMDb id when there is one, else title and year.
    public var mergeKey: String { imdbID ?? "\(title.lowercased())|\(year ?? 0)" }

    /// One list: duplicates dropped (first list wins), newest year first, undated titles after, otherwise in list
    /// order. Lists are interleaved so each list's top picks come before any list's tail.
    public static func combine(_ lists: [[LatestTitle]]) -> [LatestTitle] {
        var seen: Set<String> = []
        var merged: [LatestTitle] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count {
                if seen.insert(list[index].mergeKey).inserted { merged.append(list[index]) }
            }
        }
        return merged.enumerated().sorted { a, b in
            switch (a.element.year, b.element.year) {
            case let (x?, y?) where x != y: return x > y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// A list of newly released or updated movies or shows from another site (no account needed).
public protocol LatestTitlesSource: Sendable {
    var kind: MediaKind { get }
    func latestTitles() async throws -> [LatestTitle]
}

/// mymoviz.co "latest movies" / "latest TV shows": server-rendered HTML, newest first. Each card carries the English
/// title with its year and the IMDb id in the poster's file name.
public struct MyMovizClient: LatestTitlesSource {
    public let kind: MediaKind
    private let http: HTTPRequester
    private let url: URL

    public init(kind: MediaKind, transport: any HTTPTransport) {
        self.kind = kind
        self.http = HTTPRequester(service: "mymoviz", transport: transport)
        self.url = URL(string: kind == .tv ? "https://mymoviz.co/tvshows/tv-latest" : "https://mymoviz.co/main/latest-movies")!
    }

    public func latestTitles() async throws -> [LatestTitle] {
        let data = try await http.data(.get(url, headers: ["Accept": "text/html", "Accept-Language": "en"]))
        // The first page is the newest 24; that's all the app shows from here.
        return Array(Self.parse(String(decoding: data, as: UTF8.self), kind: kind).prefix(24))
    }

    static func parse(_ html: String, kind: MediaKind = .movie) -> [LatestTitle] {
        let card = try! NSRegularExpression(pattern: #"<a class="mv-card"[^>]*\btitle="([^"]+)""#)
        let ns = html as NSString
        let matches = card.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var titles: [LatestTitle] = []
        for (index, match) in matches.enumerated() {
            let label = decodeEntities(ns.substring(with: match.range(at: 1))).trimmingCharacters(in: .whitespaces)
            // The IMDb id sits in this card's poster URL, before the next card starts.
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: match.range.location, length: min(1500, end - match.range.location)))
            let imdbID = body.range(of: #"tt\d{6,}"#, options: .regularExpression).map { String(body[$0]) }
            let (title, year) = splitYear(label)
            guard !title.isEmpty else { continue }
            titles.append(LatestTitle(imdbID: imdbID, title: title, year: year, kind: kind, source: "MYMOVIZ"))
        }
        return titles
    }

    /// "Unit 23 Reloaded 2024" → ("Unit 23 Reloaded", 2024).
    static func splitYear(_ label: String) -> (String, Int?) {
        guard let range = label.range(of: #"\s(19|20)\d{2}$"#, options: .regularExpression) else { return (label, nil) }
        return (String(label[..<range.lowerBound]), Int(label[range].trimmingCharacters(in: .whitespaces)))
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
    }
}
