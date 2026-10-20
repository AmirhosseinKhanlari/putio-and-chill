import Foundation

public struct EZTVProvider: SourceProvider {
    public let id = "eztv"
    private let baseURL: URL
    private let http: HTTPRequester
    private let maxPages: Int
    private let pageSize = 100

    public init(baseURL: URL = URL(string: "https://eztvx.to")!, transport: any HTTPTransport, maxPages: Int = 3) {
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "eztv", transport: transport)
        self.maxPages = maxPages
    }

    public func releases(for query: MediaQuery) async throws -> [Release] {
        let season: Int
        let episode: Int?
        switch query {
        case let .episode(_, _, s, e): season = s; episode = e
        case let .season(_, _, s): season = s; episode = nil
        default: return []
        }
        // EZTV's API only looks shows up by IMDb id; without one there's nothing to ask (the text sources cover it).
        guard let imdbID = query.imdbID else { return [] }
        let digits = imdbID.hasPrefix("tt") ? String(imdbID.dropFirst(2)) : imdbID

        var torrents: [Torrent] = []
        for page in 1...maxPages {
            var components = URLComponents(url: baseURL.appending(path: "api/get-torrents"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "imdb_id", value: digits),
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ]
            let response = try await http.decode(Response.self, .get(components.url!), decoder: .snakeCase)
            let batch = response.torrents ?? []
            torrents += batch
            if batch.count < pageSize { break }
        }

        return torrents.compactMap { t -> Release? in
            let name = t.title ?? t.filename ?? ""
            let parsed = ReleaseNameParser.parse(name)
            let s = t.season?.value.map(Int.init) ?? parsed.season
            let e = t.episode?.value.map(Int.init) ?? parsed.episode
            if let episode {
                guard s == season, e == episode else { return nil }
            } else {
                guard s == season, e == 0 || e == nil || parsed.isSeasonPack else { return nil }
            }
            let hash = t.hash.flatMap(Magnet.normalize)
            let link: String
            if let magnet = t.magnetUrl, !magnet.isEmpty {
                link = magnet
            } else if let hash {
                link = Magnet.make(infoHash: hash, name: name)
            } else {
                return nil
            }
            return Release(name: name, link: link, infoHash: hash, sizeBytes: t.sizeBytes?.value,
                           seeders: t.seeds?.value.map(Int.init), sources: [SourceTag(.direct, "EZTV")], parsed: parsed)
        }
    }

    struct Response: Decodable { let torrents: [Torrent]? }
    struct Torrent: Decodable {
        let hash: String?
        let filename: String?
        let title: String?
        let season: LossyInt64?
        let episode: LossyInt64?
        let seeds: LossyInt64?
        let sizeBytes: LossyInt64?
        let magnetUrl: String?
    }
}
