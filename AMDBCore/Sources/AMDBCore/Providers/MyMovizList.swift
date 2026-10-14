import Foundation

/// A list of newly released or updated movies or shows from another site (no account needed).
public protocol LatestTitlesSource: Sendable {
    var kind: MediaKind { get }
    func latestTitles() async throws -> [ChillTitle]
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

    public func latestTitles() async throws -> [ChillTitle] {
        let data = try await http.data(.get(url, headers: ["Accept": "text/html", "Accept-Language": "en"]))
        // The first page is the newest 24; that's all the app shows from here.
        return Array(Self.parse(String(decoding: data, as: UTF8.self), kind: kind).prefix(24))
    }

    static func parse(_ html: String, kind: MediaKind = .movie) -> [ChillTitle] {
        let card = try! NSRegularExpression(pattern: #"<a class="mv-card"[^>]*\btitle="([^"]+)""#)
        let ns = html as NSString
        let matches = card.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var titles: [ChillTitle] = []
        for (index, match) in matches.enumerated() {
            let label = decodeEntities(ns.substring(with: match.range(at: 1))).trimmingCharacters(in: .whitespaces)
            // The IMDb id sits in this card's poster URL, before the next card starts.
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: match.range.location, length: min(1500, end - match.range.location)))
            let imdbID = body.range(of: #"tt\d{6,}"#, options: .regularExpression).map { String(body[$0]) }
            let (title, year) = splitYear(label)
            guard !title.isEmpty else { continue }
            titles.append(ChillTitle(imdbID: imdbID, title: title, year: year, kind: kind, source: "MYMOVIZ"))
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
