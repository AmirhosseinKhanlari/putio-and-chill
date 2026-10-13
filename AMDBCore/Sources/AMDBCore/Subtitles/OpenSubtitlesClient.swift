import Foundation

/// What to look for: TMDB IDs (episodes use the show's ID plus season/episode), the file hash when known.
public struct SubtitleSearch: Sendable, Hashable {
    public let tmdbID: Int?
    public let kind: MediaKind?
    public let season: Int?
    public let episode: Int?
    public let query: String?
    public let languages: [String]
    public let movieHash: String?

    public init(tmdbID: Int?, kind: MediaKind?, season: Int?, episode: Int?, query: String?, languages: [String],
                movieHash: String?) {
        self.tmdbID = tmdbID; self.kind = kind; self.season = season; self.episode = episode
        self.query = query; self.languages = languages; self.movieHash = movieHash
    }
}

public struct SubtitleResult: Sendable, Hashable, Identifiable {
    /// The file to download (`file_id`).
    public let fileID: Int
    public let language: String
    public let release: String
    public let downloads: Int
    public let hearingImpaired: Bool
    public let machineTranslated: Bool
    public let trusted: Bool
    /// The subtitle was made for this exact file (same OpenSubtitles hash).
    public let hashMatch: Bool
    public var id: Int { fileID }

    public init(fileID: Int, language: String, release: String, downloads: Int, hearingImpaired: Bool = false,
                machineTranslated: Bool = false, trusted: Bool = false, hashMatch: Bool = false) {
        self.fileID = fileID; self.language = language; self.release = release; self.downloads = downloads
        self.hearingImpaired = hearingImpaired; self.machineTranslated = machineTranslated
        self.trusted = trusted; self.hashMatch = hashMatch
    }
}

public struct SubtitleDownload: Sendable, Hashable {
    public let link: URL
    /// Downloads left today, when the API says.
    public let remaining: Int?

    public init(link: URL, remaining: Int?) { self.link = link; self.remaining = remaining }
}

public struct OpenSubtitlesLogin: Sendable, Hashable {
    public let token: String
    public let allowedDownloads: Int?
    public let isVIP: Bool
    /// API host for this account; VIP accounts get their own (vip-api.opensubtitles.com) with the higher limit.
    public let host: String?

    public init(token: String, allowedDownloads: Int?, isVIP: Bool = false, host: String? = nil) {
        self.token = token; self.allowedDownloads = allowedDownloads; self.isVIP = isVIP; self.host = host
    }
}

public enum OpenSubtitlesError: Error, Equatable, Sendable {
    /// Daily download limit reached (406); signing in raises it.
    case quotaReached
    case badCredentials
}

/// OpenSubtitles.com REST API v1. Every request carries `Api-Key` and an app `User-Agent`;
/// downloads also send the user's token when signed in, which raises the daily limit.
public struct OpenSubtitlesClient: Sendable {
    private let apiKey: String
    private let userAgent: String
    private let baseURL: URL
    private let http: HTTPRequester

    public init(apiKey: String, transport: any HTTPTransport, userAgent: String = "AMDB v1.0",
                baseURL: URL = URL(string: "https://api.opensubtitles.com/api/v1")!) {
        self.apiKey = apiKey
        self.userAgent = userAgent
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "opensubtitles", transport: transport)
    }

    /// Best first: exact file match, then human-made, trusted, most downloaded.
    public func search(_ search: SubtitleSearch) async throws -> [SubtitleResult] {
        let response = try await http.decode(SearchResponse.self, .get(searchURL(search), headers: headers(token: nil)))
        let results = (response.data ?? []).compactMap { item -> SubtitleResult? in
            guard let attributes = item.attributes, let file = attributes.files?.first, let fileID = file.fileId else { return nil }
            return SubtitleResult(fileID: fileID, language: attributes.language ?? "",
                                  release: attributes.release ?? file.fileName ?? "Subtitle",
                                  downloads: attributes.downloadCount ?? 0,
                                  hearingImpaired: attributes.hearingImpaired ?? false,
                                  machineTranslated: (attributes.aiTranslated ?? false) || (attributes.machineTranslated ?? false),
                                  trusted: attributes.fromTrusted ?? false,
                                  hashMatch: attributes.moviehashMatch ?? false)
        }
        return results.sorted { a, b in
            if a.hashMatch != b.hashMatch { return a.hashMatch }
            if a.machineTranslated != b.machineTranslated { return !a.machineTranslated }
            if a.trusted != b.trusted { return a.trusted }
            return a.downloads > b.downloads
        }
    }

    /// The API wants parameters sorted and lowercase (it redirects otherwise).
    func searchURL(_ search: SubtitleSearch) -> URL {
        var items: [(String, String)] = []
        if !search.languages.isEmpty {
            items.append(("languages", search.languages.map { $0.lowercased() }.sorted().joined(separator: ",")))
        }
        if let hash = search.movieHash { items.append(("moviehash", hash.lowercased())) }
        if let tmdbID = search.tmdbID {
            if search.kind == .tv {
                items.append(("parent_tmdb_id", String(tmdbID)))
                if let season = search.season { items.append(("season_number", String(season))) }
                if let episode = search.episode { items.append(("episode_number", String(episode))) }
                items.append(("type", "episode"))
            } else {
                items.append(("tmdb_id", String(tmdbID)))
                items.append(("type", "movie"))
            }
        } else if let query = search.query, !query.isEmpty {
            items.append(("query", query.lowercased()))
        }
        var components = URLComponents(url: baseURL.appending(path: "subtitles"), resolvingAgainstBaseURL: false)!
        components.queryItems = items.sorted { $0.0 < $1.0 }.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    public func login(username: String, password: String) async throws -> OpenSubtitlesLogin {
        let request = try URLRequest.postJSON(baseURL.appending(path: "login"),
                                              body: ["username": username, "password": password], headers: headers(token: nil))
        do {
            let response = try await http.decode(LoginResponse.self, request)
            guard let token = response.token else { throw OpenSubtitlesError.badCredentials }
            return OpenSubtitlesLogin(token: token, allowedDownloads: response.user?.allowedDownloads,
                                      isVIP: response.user?.vip ?? false, host: response.baseUrl)
        } catch AppError.unauthorized(_) {
            throw OpenSubtitlesError.badCredentials
        } catch AppError.http(_, let status) where status == 400 || status == 403 {
            throw OpenSubtitlesError.badCredentials
        }
    }

    /// Asks for a temporary download link; counts against the daily limit of the signed-in account
    /// (sent to the account's own API host), or the anonymous limit when `login` is nil.
    public func download(fileID: Int, login: OpenSubtitlesLogin?) async throws -> SubtitleDownload {
        let request = try URLRequest.postJSON(apiURL(host: login?.host).appending(path: "download"), body: DownloadBody(fileId: fileID),
                                              headers: headers(token: login?.token))
        do {
            let response = try await http.decode(DownloadResponse.self, request, decoder: .snakeCase)
            guard let link = response.link.flatMap(URL.init(string:)) else {
                throw AppError.decoding(service: "opensubtitles", detail: "no link")
            }
            return SubtitleDownload(link: link, remaining: response.remaining)
        } catch AppError.http(_, let status) where status == 406 || status == 429 {
            throw OpenSubtitlesError.quotaReached
        }
    }

    /// The subtitle file itself (a plain CDN URL, no headers needed).
    public func text(at link: URL) async throws -> String {
        let data = try await http.data(URLRequest(url: link))
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// The default API URL, or the same path on the host the login named.
    func apiURL(host: String?) -> URL {
        guard let host = host?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
              host.hasSuffix("opensubtitles.com") || host.hasSuffix("opensubtitles.org"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        components.host = host.replacingOccurrences(of: "https://", with: "")
        return components.url ?? baseURL
    }

    private func headers(token: String?) -> [String: String] {
        var headers = ["Api-Key": apiKey, "User-Agent": userAgent]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    struct SearchResponse: Decodable {
        struct Item: Decodable { let attributes: Attributes? }
        struct Attributes: Decodable {
            let language: String?
            let release: String?
            let downloadCount: Int?
            let hearingImpaired: Bool?
            let aiTranslated: Bool?
            let machineTranslated: Bool?
            let fromTrusted: Bool?
            let moviehashMatch: Bool?
            let files: [File]?

            enum CodingKeys: String, CodingKey {
                case language, release, files
                case downloadCount = "download_count", hearingImpaired = "hearing_impaired", aiTranslated = "ai_translated"
                case machineTranslated = "machine_translated", fromTrusted = "from_trusted", moviehashMatch = "moviehash_match"
            }
        }
        struct File: Decodable {
            let fileId: Int?
            let fileName: String?
            enum CodingKeys: String, CodingKey { case fileId = "file_id", fileName = "file_name" }
        }
        let data: [Item]?
    }

    struct LoginResponse: Decodable {
        struct User: Decodable {
            let allowedDownloads: Int?
            let vip: Bool?
            enum CodingKeys: String, CodingKey { case allowedDownloads = "allowed_downloads", vip }
        }
        let token: String?
        let user: User?
        let baseUrl: String?
        enum CodingKeys: String, CodingKey { case token, user, baseUrl = "base_url" }
    }

    struct DownloadBody: Encodable {
        let fileId: Int
        enum CodingKeys: String, CodingKey { case fileId = "file_id" }
    }

    struct DownloadResponse: Decodable {
        let link: String?
        let remaining: Int?
    }
}
