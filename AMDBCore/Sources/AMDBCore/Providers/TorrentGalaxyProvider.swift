import Foundation

/// torrentgalaxy.info: `GET {base}/get-posts/keywords:<words>:order:-se/` (HTML, most seeded first). The list has no
/// info-hashes, so the detail pages of the best few matches are read for theirs, a few at a time. Matches without a
/// hash are left out: put.io needs a magnet link.
public struct TorrentGalaxyProvider: SourceProvider {
    public let id = "torrentgalaxy"
    private let baseURL: URL
    private let http: HTTPRequester
    private let detailLimit: Int
    private let parallelDetails: Int

    /// It's a browser site; ask like one.
    static let headers = [
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Language": "en",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
    ]

    public init(baseURL: URL = URL(string: "https://torrentgalaxy.info")!, transport: any HTTPTransport,
                detailLimit: Int = 8, parallelDetails: Int = 4) {
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "torrentgalaxy", transport: transport)
        self.detailLimit = detailLimit
        self.parallelDetails = max(parallelDetails, 1)
    }

    public func releases(for query: MediaQuery) async throws -> [Release] {
        let data = try await http.data(.get(searchURL(for: query), headers: Self.headers))
        let matches = TorrentGalaxyPage.rows(in: String(decoding: data, as: UTF8.self))
            .filter { !TorrentGalaxyPage.skippedCategories.contains($0.category ?? "") }
            .map { (row: $0, parsed: ReleaseNameParser.parse($0.name)) }
            .filter { ReleaseRelevance.matches($0.parsed, query) }
        let needed = matches.filter { $0.row.infoHash == nil }
            .sorted { ($0.row.seeders ?? -1) > ($1.row.seeders ?? -1) }
            .prefix(detailLimit).map(\.row.detailPath)
        let fetched = await detailHashes(Array(needed))
        return matches.compactMap { match -> Release? in
            guard let hash = match.row.infoHash ?? fetched[match.row.detailPath] else { return nil }
            return Release(name: match.row.name, link: Magnet.make(infoHash: hash, name: match.row.name), infoHash: hash,
                           sizeBytes: match.row.sizeBytes, seeders: match.row.seeders,
                           sources: [SourceTag(.direct, "TorrentGalaxy")], parsed: match.parsed)
        }
    }

    func searchURL(for query: MediaQuery) -> URL {
        baseURL.appending(path: "get-posts/keywords:\(TorrentGalaxyPage.keywords(query.searchText)):order:-se/")
    }

    /// Detail path → info-hash, `parallelDetails` at a time. A page that fails or has no hash is skipped.
    private func detailHashes(_ paths: [String]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            var queue = paths.makeIterator()
            for _ in 0..<parallelDetails {
                guard let path = queue.next() else { break }
                group.addTask { (path, await detailHash(path)) }
            }
            var found: [String: String] = [:]
            for await (path, hash) in group {
                if let hash { found[path] = hash }
                if !Task.isCancelled, let next = queue.next() { group.addTask { (next, await detailHash(next)) } }
            }
            return found
        }
    }

    private func detailHash(_ path: String) async -> String? {
        guard path.hasPrefix("/post-detail/"), let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return nil }
        var request = URLRequest.get(url, headers: Self.headers)
        // One slow page shouldn't use up the whole search's time.
        request.timeoutInterval = 5
        guard let data = try? await http.data(request) else { return nil }
        return TorrentGalaxyPage.infoHash(inDetail: String(decoding: data, as: UTF8.self))
    }
}
