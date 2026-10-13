import AMDBCore
import AVFoundation
import Foundation

let env = ProcessInfo.processInfo.environment
guard let putioToken = env["PUTIO_TOKEN"], let tmdbToken = env["TMDB_TOKEN"] else {
    print("Set PUTIO_TOKEN and TMDB_TOKEN (CHILL_TOKEN optional).")
    exit(1)
}
let outPath = ".spike-out"
try? FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)

/// Records every raw body so inline test JSON can be compared with reality.
struct DumpingTransport: HTTPTransport {
    let inner = URLSessionTransport()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await inner.send(request)
        let slug = (request.url?.host() ?? "x") + (request.url?.path ?? "")
        let name = slug.replacingOccurrences(of: "/", with: "_").prefix(120)
        try? data.write(to: URL(fileURLWithPath: ".spike-out/\(name).json"))
        return (data, response)
    }
}

let transport = DumpingTransport()
@MainActor func record(_ check: String, _ result: String) {
    print("• \(check): \(result)")
}
@MainActor func attempt(_ check: String, _ body: () async throws -> String) async {
    do { record(check, try await body()) } catch { record(check, "FAILED — \(error)") }
}

let putio = PutioClient(token: putioToken, transport: transport)
let tmdb = CatalogClient(accessToken: tmdbToken, transport: transport)

// 1. put.io auth header
await attempt("put.io auth (Authorization: token …)") { "OK as \(try await putio.accountInfo().username)" }

// 2–3. Files, start_from exposure, HLS playability
await attempt("put.io start_from in files/list") {
    let root = try await putio.listFiles(parentID: 0)
    let videos = root.files.filter(\.isVideo)
    let withStart = videos.filter { $0.startFrom != nil }.count
    return "\(videos.count) videos at root, \(withStart) carry start_from"
}
await attempt("put.io HLS playable in AVPlayer") {
    let root = try await putio.listFiles(parentID: 0)
    var queue = root.files
    var video: PutioFile?
    var visited = 0
    while video == nil, !queue.isEmpty, visited < 30 {
        let next = queue.removeFirst()
        visited += 1
        if next.isVideo { video = next } else if next.isFolder { queue += try await putio.listFiles(parentID: next.id).files }
    }
    guard let video else { return "no video file found to test" }
    let start = try await putio.startFrom(fileID: video.id)
    let asset = AVURLAsset(url: putio.hlsURL(fileID: video.id))
    let playable = try await asset.load(.isPlayable)
    return "\(video.name): playable=\(playable), start-from endpoint=\(start)s, files/{id} start_from=\(String(describing: try await putio.file(id: video.id).startFrom))"
}

// 4. TMDB
await attempt("TMDB token") { try await tmdb.validate(); return "OK" }
await attempt("TMDB search/multi 'dune'") { "\(try await tmdb.searchMulti("dune").count) results" }

// 5. Providers
let furiosa = MediaQuery.movie(imdbID: "tt12037194", title: "Furiosa A Mad Max Saga", year: 2024)
let severance = MediaQuery.episode(imdbID: "tt11280740", title: "Severance", season: 2, episode: 4)
let directProviders: [any SourceProvider] = [
    YTSProvider(transport: transport), EZTVProvider(transport: transport),
    ApibayProvider(transport: transport), KnabenProvider(transport: transport),
]
for provider in directProviders {
    await attempt("\(provider.id) movie") { "\(try await provider.releases(for: furiosa).count) releases" }
    await attempt("\(provider.id) episode") { "\(try await provider.releases(for: severance).count) releases" }
}

// 6. chill
if let chillToken = env["CHILL_TOKEN"] {
    let chill = ChillProvider(token: chillToken, transport: transport)
    await attempt("chill indexers") { try await chill.indexers().map(\.name).joined(separator: ", ") }
    await attempt("chill movie search") { "\(try await chill.releases(for: furiosa).count) releases" }
    await attempt("chill episode download") { "\(try await chill.releases(for: severance).count) releases" }
    for method in ["ResolvePlayback", "GetTransfer"] {
        await attempt("chill \(method) exists") {
            var request = try URLRequest.postJSON(
                URL(string: "https://api.chill.institute/v4/chill.v4.UserService/\(method)")!,
                body: ["fileId": "1"], headers: ["Authorization": "Bearer \(chillToken)", "Connect-Protocol-Version": "1"])
            request.timeoutInterval = 15
            let (data, response) = try await URLSessionTransport().send(request)
            return "HTTP \(response.statusCode) \(String(decoding: data.prefix(160), as: UTF8.self))"
        }
    }
} else {
    record("chill", "skipped (no CHILL_TOKEN)")
}

// 7. Aggregate end-to-end
await attempt("aggregate Furiosa") {
    let snapshot = await ReleaseAggregator(providers: directProviders).collect(for: furiosa)
    let top = snapshot.releases.sorted(by: .seeders).prefix(3).map { "\($0.parsed.resolution.label) \($0.seeders ?? 0)s \($0.sources.map(\.label).sorted())" }
    return "\(snapshot.releases.count) merged, failures=\(snapshot.failures.map(\.providerID)), top=\(top)"
}

print("\nRaw responses saved in \(outPath)/")
