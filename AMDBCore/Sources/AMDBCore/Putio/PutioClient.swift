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

    /// TV sign-in: a short code the user enters at put.io/link (or scans as a QR code) on another device.
    public static func requestDeviceCode(appID: String, transport: any HTTPTransport,
                                         baseURL: URL = defaultBaseURL) async throws -> PutioDeviceCode {
        var components = URLComponents(url: baseURL.appending(path: "oauth2/oob/code"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "app_id", value: appID)]
        let response = try await HTTPRequester(service: "putio", transport: transport)
            .decode(DeviceCodeResponse.self, .get(components.url!), decoder: .snakeCase)
        return PutioDeviceCode(code: response.code, qrCodeURL: response.qrCodeUrl.flatMap(URL.init(string:)))
    }

    /// The account token once the user has entered the code, nil while still waiting.
    public static func deviceToken(code: String, transport: any HTTPTransport, baseURL: URL = defaultBaseURL) async throws -> String? {
        let url = baseURL.appending(path: "oauth2/oob/code/\(code)")
        let response = try await HTTPRequester(service: "putio", transport: transport)
            .decode(DeviceTokenResponse.self, .get(url), decoder: .snakeCase)
        return response.oauthToken.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Where the user enters a device code.
    public static let linkURL = URL(string: "https://put.io/link")!

    struct DeviceCodeResponse: Decodable { let code: String; let qrCodeUrl: String? }
    struct DeviceTokenResponse: Decodable { let oauthToken: String? }

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

    /// Moves files or folders into `parentID`.
    public func moveFiles(ids: [Int64], to parentID: Int64) async throws {
        _ = try await http.data(form("files/move", [("file_ids", ids.map(String.init).joined(separator: ",")),
                                                    ("parent_id", String(parentID))]))
    }

    public func deleteFiles(ids: [Int64]) async throws {
        _ = try await http.data(form("files/delete", [("file_ids", ids.map(String.init).joined(separator: ","))]))
    }

    /// The file with its conversion status (whether Apple devices need an MP4 of it, and whether that's ready).
    public func fileStatus(id: Int64) async throws -> PutioFile {
        try await get("files/\(id)", query: [("mp4_status", "1")], as: FileEnvelope.self).file
    }

    public func mp4Status(fileID: Int64) async throws -> PutioMp4Status {
        try await get("files/\(fileID)/mp4", as: Mp4Envelope.self).mp4
    }

    /// Asks put.io to convert the video to MP4 (it's then streamed and downloaded from the MP4).
    public func convertToMp4(fileID: Int64) async throws -> PutioMp4Status {
        try await post("files/\(fileID)/mp4", [], as: Mp4Envelope.self).mp4
    }

    public func renameFile(id: Int64, name: String) async throws {
        _ = try await http.data(form("files/rename", [("file_id", String(id)), ("name", name)]))
    }

    /// Copies one file or folder into `parentID`; returns the copy.
    public func copyFile(id: Int64, to parentID: Int64) async throws -> PutioFile {
        try await post("files/copy", [("file_id", String(id)), ("parent_id", String(parentID))], as: FileEnvelope.self).file
    }

    /// Files and folders anywhere in the account whose name matches.
    public func searchFiles(_ query: String) async throws -> [PutioFile] {
        try await get("files/search", query: [("query", query), ("per_page", "200")], as: SearchEnvelope.self).files
    }

    // MARK: Trash (deleted files stay here until emptied or they expire)

    public func trash() async throws -> PutioTrash {
        try await get("trash/list", query: [("per_page", "1000")], as: PutioTrash.self)
    }

    public func restoreFromTrash(ids: [Int64]) async throws {
        _ = try await http.data(form("trash/restore", [("file_ids", ids.map(String.init).joined(separator: ","))]))
    }

    public func deleteFromTrash(ids: [Int64]) async throws {
        _ = try await http.data(form("trash/delete", [("file_ids", ids.map(String.init).joined(separator: ","))]))
    }

    public func emptyTrash() async throws {
        _ = try await http.data(form("trash/empty", []))
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

    /// One subtitle file as SRT text.
    public func subtitleText(fileID: Int64, key: String) async throws -> String {
        var components = URLComponents(url: baseURL.appending(path: "files/\(fileID)/subtitles/\(key)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "srt")]
        let data = try await http.data(.get(components.url!, headers: authHeaders))
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// The HLS stream. With `subtitles`, put.io muxes every subtitle track into it (used for offline copies);
    /// streaming leaves them out because the app draws subtitles itself.
    public func hlsURL(fileID: Int64, subtitles: Bool) -> URL {
        let subtitleParam = subtitles ? "subtitle_key=all&" : ""
        return URL(string: "\(baseURL.absoluteString)/files/\(fileID)/hls/media.m3u8?\(subtitleParam)oauth_token=\(formEncode(token))")!
    }

    public func hlsURL(fileID: Int64) -> URL { hlsURL(fileID: fileID, subtitles: true) }

    // MARK: Plumbing

    private var authHeaders: [String: String] { ["Authorization": "token \(token)"] }

    private func get<T: Decodable>(_ path: String, query: [(String, String)] = [], as: T.Type) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        // Always fresh: free space, folders and trash change between calls.
        var request = URLRequest.get(components.url!, headers: authHeaders)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await http.decode(T.self, request, decoder: .snakeCase)
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
    struct SearchEnvelope: Decodable { let files: [PutioFile] }
    struct Mp4Envelope: Decodable { let mp4: PutioMp4Status }
}
