import Foundation

public struct ChillIndexer: Decodable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let enabled: Bool?
}

public actor ChillProvider: SourceProvider {
    public nonisolated let id = "chill"
    private nonisolated let token: String
    private nonisolated let baseURL: URL
    private nonisolated let http: HTTPRequester
    private var cachedIndexers: [ChillIndexer]?

    public init(token: String, transport: any HTTPTransport, baseURL: URL = URL(string: "https://api.chill.institute/v4")!) {
        self.token = token
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "chill", transport: transport)
    }

    public func indexers() async throws -> [ChillIndexer] {
        if let cachedIndexers { return cachedIndexers }
        let response: IndexersResponse = try await call("GetIndexers", Empty())
        let enabled = (response.indexers ?? []).filter { $0.enabled == true }
        cachedIndexers = enabled
        return enabled
    }

    public func releases(for query: MediaQuery) async throws -> [Release] {
        switch query {
        case .movie, .text:
            let text = query.searchText
            let indexers = try await indexers()
            let releases = try await withThrowingTaskGroup(of: [Release].self) { group in
                for indexer in indexers {
                    group.addTask { try await self.search(text, indexerID: indexer.id) }
                }
                var all: [Release] = []
                var lastError: (any Error)?
                while let result = await group.nextResult() {
                    switch result {
                    case let .success(rows): all += rows
                    case let .failure(error): lastError = error
                    }
                }
                if all.isEmpty, let lastError { throw lastError }
                return all
            }
            return releases.filter { ReleaseRelevance.matches($0.parsed, query) }
        case let .episode(imdbID, _, season, episode):
            let response: EpisodeResponse = try await call(
                "GetTVShowEpisodeDownload", EpisodeRequest(imdbId: imdbID, seasonNumber: season, episodeNumber: episode))
            return response.download.map { [Self.release(from: $0)] } ?? []
        case let .season(imdbID, _, season):
            let response: SeasonResponse = try await call(
                "GetTVShowSeasonDownloads", SeasonRequest(imdbId: imdbID, seasonNumber: season))
            return response.seasonPack.map { [Self.release(from: $0)] } ?? []
        }
    }

    private nonisolated func search(_ text: String, indexerID: String) async throws -> [Release] {
        let response: SearchResponse = try await call("Search", SearchRequest(query: text, indexerId: indexerID))
        return (response.results ?? []).compactMap(Self.release(from:))
    }

    private nonisolated func call<Req: Encodable & Sendable, Res: Decodable>(_ method: String, _ body: Req) async throws -> Res {
        let request = try URLRequest.postJSON(
            baseURL.appending(path: "chill.v4.UserService/\(method)"), body: body,
            headers: ["Authorization": "Bearer \(token)", "Connect-Protocol-Version": "1"])
        return try await http.decode(Res.self, request)
    }

    static func release(from result: SearchResult) -> Release? {
        guard let link = result.link, !link.isEmpty else { return nil }
        let name = result.title ?? ""
        var parsed = ReleaseNameParser.parse(name)
        if let info = result.releaseInfo {
            if let title = info.title, !title.isEmpty { parsed.title = title }
            if let year = info.year { parsed.year = year }
            if let season = info.season { parsed.season = season }
            if let episode = info.episode { parsed.episode = episode }
            if let label = info.resolution, Resolution(label: label) != .unknown { parsed.resolution = Resolution(label: label) }
        }
        let tagName = [result.source, result.indexer].compactMap { $0 }.first { !$0.isEmpty } ?? "chill"
        return Release(name: name, link: link, sizeBytes: result.size?.value,
                       seeders: result.seeders?.value.map(Int.init), sources: [SourceTag(.chill, tagName)], parsed: parsed)
    }

    static func release(from download: TVShowDownload) -> Release {
        var parsed = ReleaseNameParser.parse(download.title ?? "")
        if let label = download.resolution, Resolution(label: label) != .unknown { parsed.resolution = Resolution(label: label) }
        return Release(name: download.title ?? "", link: download.link ?? "", sizeBytes: download.size?.value,
                       seeders: download.seeders?.value.map(Int.init),
                       sources: [SourceTag(.chill, download.indexer ?? "chill")], parsed: parsed)
    }

    struct Empty: Encodable, Sendable {}
    struct SearchRequest: Encodable, Sendable { let query: String; let indexerId: String }
    struct EpisodeRequest: Encodable, Sendable { let imdbId: String; let seasonNumber: Int; let episodeNumber: Int }
    struct SeasonRequest: Encodable, Sendable { let imdbId: String; let seasonNumber: Int }

    struct IndexersResponse: Decodable { let indexers: [ChillIndexer]? }
    struct SearchResponse: Decodable { let results: [SearchResult]? }
    struct SearchResult: Decodable {
        let title: String?
        let indexer: String?
        let link: String?
        let seeders: LossyInt64?
        let size: LossyInt64?
        let source: String?
        let releaseInfo: ReleaseInfo?
    }
    struct ReleaseInfo: Decodable {
        let title: String?
        let year: Int?
        let season: Int?
        let episode: Int?
        let resolution: String?
    }
    struct TVShowDownload: Decodable {
        let title: String?
        let link: String?
        let size: LossyInt64?
        let seeders: LossyInt64?
        let resolution: String?
        let indexer: String?
    }
    struct EpisodeResponse: Decodable { let download: TVShowDownload? }
    struct SeasonResponse: Decodable { let seasonPack: TVShowDownload? }
}
