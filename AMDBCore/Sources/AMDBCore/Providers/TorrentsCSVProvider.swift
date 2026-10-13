import Foundation

/// torrents-csv.com: `GET {base}/service/search?q=…&size=50`.
public struct TorrentsCSVProvider: SourceProvider {
    public let id = "torrentscsv"
    private let baseURL: URL
    private let http: HTTPRequester

    public init(baseURL: URL = URL(string: "https://torrents-csv.com")!, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "torrentscsv", transport: transport)
    }

    public func releases(for query: MediaQuery) async throws -> [Release] {
        var components = URLComponents(url: baseURL.appending(path: "service/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query.searchText), URLQueryItem(name: "size", value: "50")]
        let response = try await http.decode(Response.self, .get(components.url!), decoder: .snakeCase)
        return (response.torrents ?? []).compactMap { torrent -> Release? in
            guard let hash = Magnet.normalize(torrent.infohash) else { return nil }
            let parsed = ReleaseNameParser.parse(torrent.name)
            guard ReleaseRelevance.matches(parsed, query) else { return nil }
            return Release(name: torrent.name, link: Magnet.make(infoHash: hash, name: torrent.name), infoHash: hash,
                           sizeBytes: torrent.sizeBytes?.value, seeders: torrent.seeders?.value.map(Int.init),
                           sources: [SourceTag(.direct, "Torrents.csv")], parsed: parsed)
        }
    }

    struct Response: Decodable { let torrents: [Torrent]? }
    struct Torrent: Decodable {
        let infohash: String
        let name: String
        let sizeBytes: LossyInt64?
        let seeders: LossyInt64?
    }
}
