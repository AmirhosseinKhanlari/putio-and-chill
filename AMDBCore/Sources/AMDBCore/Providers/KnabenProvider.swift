import Foundation

public struct KnabenProvider: SourceProvider {
    public let id = "knaben"
    private let baseURL: URL
    private let http: HTTPRequester

    public init(baseURL: URL = URL(string: "https://api.knaben.org")!, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "knaben", transport: transport)
    }

    public func releases(for query: MediaQuery) async throws -> [Release] {
        let body = Body(query: query.searchText)
        let request = try URLRequest.postJSON(baseURL.appending(path: "v1"), body: body)
        let response = try await http.decode(Response.self, request)
        return (response.hits ?? []).compactMap { hit -> Release? in
            let hash = hit.hash.flatMap(Magnet.normalize) ?? hit.magnetUrl.flatMap(Magnet.infoHash(from:))
            let link: String
            if let magnet = hit.magnetUrl, !magnet.isEmpty {
                link = magnet
            } else if let hash {
                link = Magnet.make(infoHash: hash, name: hit.title)
            } else if let direct = hit.link, !direct.isEmpty {
                link = direct
            } else {
                return nil
            }
            let parsed = ReleaseNameParser.parse(hit.title)
            guard ReleaseRelevance.matches(parsed, query) else { return nil }
            return Release(name: hit.title, link: link, infoHash: hash, sizeBytes: hit.bytes?.value,
                           seeders: hit.seeders?.value.map(Int.init), sources: [SourceTag(.direct, "Knaben")], parsed: parsed)
        }
    }

    struct Body: Encodable {
        let search_type = "100%"
        let search_field = "title"
        let query: String
        let size = 50
        let order_by = "seeders"
        let order_direction = "desc"
        let hide_unsafe = true
        let hide_xxx = true
    }

    struct Response: Decodable { let hits: [Hit]? }
    struct Hit: Decodable {
        let title: String
        let hash: String?
        let magnetUrl: String?
        let link: String?
        let bytes: LossyInt64?
        let seeders: LossyInt64?
    }
}
