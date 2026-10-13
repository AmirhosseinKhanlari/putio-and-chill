import Foundation

public struct ApibayProvider: SourceProvider {
    public let id = "apibay"
    private let baseURL: URL
    private let http: HTTPRequester

    public init(baseURL: URL = URL(string: "https://apibay.org")!, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "apibay", transport: transport)
    }

    public func releases(for query: MediaQuery) async throws -> [Release] {
        var components = URLComponents(url: baseURL.appending(path: "q.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query.searchText), URLQueryItem(name: "cat", value: "0")]
        let items = try await http.decode([Item].self, .get(components.url!), decoder: .snakeCase)
        return items.compactMap { item -> Release? in
            guard item.id != "0", let hash = Magnet.normalize(item.infoHash),
                  hash != String(repeating: "0", count: 40) else { return nil }
            let parsed = ReleaseNameParser.parse(item.name)
            guard ReleaseRelevance.matches(parsed, query) else { return nil }
            return Release(name: item.name, link: Magnet.make(infoHash: hash, name: item.name), infoHash: hash,
                           sizeBytes: Int64(item.size), seeders: Int(item.seeders),
                           sources: [SourceTag(.direct, "TPB")], parsed: parsed)
        }
    }

    struct Item: Decodable {
        let id: String
        let name: String
        let infoHash: String
        let seeders: String
        let size: String
    }
}
