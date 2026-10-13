import Foundation

public struct PutioClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.put.io/v2")!
    private let token: String
    private let baseURL: URL
    private let http: HTTPRequester

    public init(token: String, transport: any HTTPTransport, baseURL: URL = PutioClient.defaultBaseURL) {
        self.token = token
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "putio", transport: transport)
    }

    // MARK: Auth

    public static func authorizeURL(clientID: String, redirectURI: String) -> URL {
        URL(string: "\(defaultBaseURL.absoluteString)/oauth2/authenticate?client_id=\(clientID)&response_type=token&redirect_uri=\(redirectURI)")!
    }

    public static func token(fromCallback url: URL) -> String? {
        guard let fragment = url.fragment else { return nil }
        var components = URLComponents()
        components.query = fragment
        return components.queryItems?.first { $0.name == "access_token" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Account

    public func accountInfo() async throws -> PutioAccount {
        try await get("account/info", as: InfoEnvelope.self).info
    }

    // MARK: Transfers

    public func addTransfer(url: String, saveParentID: Int64?) async throws -> PutioTransfer {
        var fields = [("url", url)]
        if let saveParentID { fields.append(("save_parent_id", String(saveParentID))) }
        return try await post("transfers/add", fields, as: TransferEnvelope.self).transfer
    }

    public func transfer(id: Int64) async throws -> PutioTransfer {
        try await get("transfers/\(id)", as: TransferEnvelope.self).transfer
    }

    public func transfers() async throws -> [PutioTransfer] {
        try await get("transfers/list", as: TransfersEnvelope.self).transfers
    }

    public func cancelTransfers(ids: [Int64]) async throws {
        _ = try await http.data(form("transfers/cancel", [("transfer_ids", ids.map(String.init).joined(separator: ","))]))
    }

    public func retryTransfer(id: Int64) async throws -> PutioTransfer {
        try await post("transfers/retry", [("id", String(id))], as: TransferEnvelope.self).transfer
    }

    // MARK: Files

    public func listFiles(parentID: Int64) async throws -> PutioFileList {
        try await get("files/list", query: [("parent_id", String(parentID)), ("per_page", "1000")], as: PutioFileList.self)
    }

    public func file(id: Int64) async throws -> PutioFile {
        try await get("files/\(id)", as: FileEnvelope.self).file
    }

    public func deleteFiles(ids: [Int64]) async throws {
        _ = try await http.data(form("files/delete", [("file_ids", ids.map(String.init).joined(separator: ","))]))
    }

    public func createFolder(name: String, parentID: Int64) async throws -> PutioFile {
        try await post("files/create-folder", [("name", name), ("parent_id", String(parentID))], as: FileEnvelope.self).file
    }

    public func startFrom(fileID: Int64) async throws -> Int {
        try await get("files/\(fileID)/start-from", as: StartFromEnvelope.self).startFrom ?? 0
    }

    public func setStartFrom(fileID: Int64, seconds: Int) async throws {
        _ = try await http.data(form("files/\(fileID)/start-from/set", [("time", String(seconds))]))
    }

    public func originalURL(fileID: Int64) async throws -> URL {
        let envelope = try await get("files/\(fileID)/url", as: URLEnvelope.self)
        guard let url = URL(string: envelope.url) else { throw AppError.decoding(service: "putio", detail: "bad url") }
        return url
    }

    public func subtitles(fileID: Int64) async throws -> [PutioSubtitle] {
        try await get("files/\(fileID)/subtitles", as: SubtitlesEnvelope.self).subtitles
    }

    public func hlsURL(fileID: Int64) -> URL {
        URL(string: "\(baseURL.absoluteString)/files/\(fileID)/hls/media.m3u8?subtitle_key=all&oauth_token=\(formEncode(token))")!
    }

    // MARK: Plumbing

    private var authHeaders: [String: String] { ["Authorization": "token \(token)"] }

    private func get<T: Decodable>(_ path: String, query: [(String, String)] = [], as: T.Type) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return try await http.decode(T.self, .get(components.url!, headers: authHeaders), decoder: .snakeCase)
    }

    private func form(_ path: String, _ fields: [(String, String)]) -> URLRequest {
        .postForm(baseURL.appending(path: path), fields: fields, headers: authHeaders)
    }

    private func post<T: Decodable>(_ path: String, _ fields: [(String, String)], as: T.Type) async throws -> T {
        try await http.decode(T.self, form(path, fields), decoder: .snakeCase)
    }

    struct InfoEnvelope: Decodable { let info: PutioAccount }
    struct TransferEnvelope: Decodable { let transfer: PutioTransfer }
    struct TransfersEnvelope: Decodable { let transfers: [PutioTransfer] }
    struct FileEnvelope: Decodable { let file: PutioFile }
    struct StartFromEnvelope: Decodable { let startFrom: Int? }
    struct URLEnvelope: Decodable { let url: String }
    struct SubtitlesEnvelope: Decodable { let subtitles: [PutioSubtitle] }
}
