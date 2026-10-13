import Foundation

public struct TrailerVideo: Sendable, Hashable {
    public let name: String
    /// Signed IMDb CDN URL (HLS when available, else the best MP4). Expires; fetch right before playing.
    public let url: URL

    public init(name: String, url: URL) { self.name = name; self.url = url }
}

/// Trailers from IMDb's GraphQL API (the one imdb.com uses). Videos are plain HLS/MP4, so AVPlayer plays them natively.
/// Unofficial: if IMDb changes it, callers fall back to YouTube.
public struct IMDbTrailerClient: Sendable {
    private let endpoint: URL
    private let http: HTTPRequester

    public init(transport: any HTTPTransport, endpoint: URL = URL(string: "https://caching.graphql.imdb.com/")!) {
        self.endpoint = endpoint
        self.http = HTTPRequester(service: "imdb", transport: transport)
    }

    public func trailer(imdbID: String) async throws -> TrailerVideo? {
        let id = imdbID.filter { $0.isLetter || $0.isNumber }
        let query = """
        { title(id: "\(id)") { primaryVideos(first: 5) { edges { node { id name { value } \
        contentType { displayName { value } } playbackURLs { url videoMimeType videoDefinition } } } } } }
        """
        let request = try URLRequest.postJSON(endpoint, body: ["query": query], headers: [
            "x-imdb-client-name": "imdb-web-next-localized",
            "x-imdb-user-country": "US",
            "x-imdb-user-language": "en-US",
        ])
        let response = try await http.decode(Response.self, request)
        let videos = response.data?.title?.primaryVideos?.edges?.compactMap(\.node) ?? []
        let chosen = videos.first { $0.contentType?.displayName?.value.localizedCaseInsensitiveContains("trailer") == true }
            ?? videos.first
        guard let chosen, let url = Self.bestURL(chosen.playbackURLs ?? []) else { return nil }
        return TrailerVideo(name: chosen.name?.value ?? "Trailer", url: url)
    }

    static func bestURL(_ urls: [PlaybackURL]) -> URL? {
        if let hls = urls.first(where: { $0.videoMimeType == "M3U8" }) { return URL(string: hls.url) }
        let rank = ["DEF_1080p": 4, "DEF_720p": 3, "DEF_480p": 2, "DEF_SD": 1]
        let best = urls.filter { $0.videoMimeType == "MP4" }
            .max { (rank[$0.videoDefinition ?? ""] ?? 0) < (rank[$1.videoDefinition ?? ""] ?? 0) }
        return best.flatMap { URL(string: $0.url) }
    }

    struct Response: Decodable {
        struct DataBody: Decodable { let title: Title? }
        struct Title: Decodable { let primaryVideos: Videos? }
        struct Videos: Decodable { let edges: [Edge]? }
        struct Edge: Decodable { let node: Video? }
        struct Video: Decodable {
            let name: Text?
            let contentType: ContentType?
            let playbackURLs: [PlaybackURL]?
        }
        struct ContentType: Decodable { let displayName: Text? }
        struct Text: Decodable { let value: String }
        let data: DataBody?
    }

    struct PlaybackURL: Decodable {
        let url: String
        let videoMimeType: String?
        let videoDefinition: String?
    }
}
