import Foundation

/// Reads what's inside the releases worth checking, to catch a fake whose name looks right: a file list that holds a
/// program, or whose biggest file isn't a video. Lists come with the release (TorrentGalaxy) or are fetched from its
/// `fileListURL` (apibay), a few at a time with a short timeout, and remembered for the session. A list that can't be
/// read counts as fine: only a list that shows a fake rejects.
public struct FileListInspector: Sendable {
    private let http: HTTPRequester
    private let timeout: TimeInterval
    private let parallel: Int
    private let cache = Cache()

    public init(transport: any HTTPTransport, timeout: TimeInterval = 5, parallel: Int = 4) {
        self.http = HTTPRequester(service: "file list", transport: transport)
        self.timeout = timeout
        self.parallel = max(parallel, 1)
    }

    /// The release's files, or nil when unknown.
    public func files(for release: Release) async -> [TorrentFile]? {
        if let files = release.files { return files }
        guard let url = release.fileListURL else { return nil }
        if let cached = await cache.lists[url] { return cached }
        var request = URLRequest.get(url)
        request.timeoutInterval = timeout
        let files = (try? await http.data(request)).flatMap(Self.apibayFiles)
        // A failed read isn't remembered, so the next search tries again.
        if let files { await cache.store(files, for: url) }
        return files
    }

    /// Why the release's files look fake, or nil (also when they can't be read).
    public func rejection(for release: Release) async -> ReleaseRejection? {
        guard let files = await files(for: release) else { return nil }
        return ReleaseSafety.rejection(files: files)
    }

    /// Checks `releases`, `parallel` at a time; release id → why it's fake, for those that are.
    public func rejections(_ releases: [Release]) async -> [String: ReleaseRejection] {
        await withTaskGroup(of: (String, ReleaseRejection?).self) { group in
            var queue = releases.makeIterator()
            for _ in 0..<parallel {
                guard let next = queue.next() else { break }
                group.addTask { (next.id, await rejection(for: next)) }
            }
            var found: [String: ReleaseRejection] = [:]
            for await (id, rejection) in group {
                if let rejection { found[id] = rejection }
                if !Task.isCancelled, let next = queue.next() { group.addTask { (next.id, await self.rejection(for: next)) } }
            }
            return found
        }
    }

    /// Which releases to check after a search: every one whose list came with it (free), plus the ones a fetch is
    /// worth for: the `limit` most seeded and the two most seeded of each resolution. That covers what Smart Get
    /// picks and the first screen of Versions under any quality filter.
    public static func candidates(_ releases: [Release], limit: Int = 10) -> [Release] {
        let inline = releases.filter { $0.files != nil }
        let fetchable = releases.filter { $0.files == nil && $0.fileListURL != nil }
            .sorted { ($0.seeders ?? -1) > ($1.seeders ?? -1) }
        var picked = Array(fetchable.prefix(limit))
        for resolution in Resolution.allCases {
            for release in fetchable.filter({ $0.parsed.resolution == resolution }).prefix(2)
            where !picked.contains(where: { $0.id == release.id }) {
                picked.append(release)
            }
        }
        return inline + picked
    }

    /// apibay's `f.php` answer: `[{"name": ["a.mkv"], "size": [123]}]`; "no list" comes back as one row whose name
    /// is "Filelist not found", which reads as unknown.
    static func apibayFiles(_ data: Data) -> [TorrentFile]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let files = rows.compactMap { row -> TorrentFile? in
            guard let name = (row["name"] as? [Any])?.first as? String, !name.isEmpty else { return nil }
            let size = (row["size"] as? [Any])?.first
            let bytes = (size as? NSNumber)?.int64Value ?? (size as? String).flatMap { Int64($0) }
            return TorrentFile(name: name, sizeBytes: bytes)
        }
        return files.isEmpty ? nil : files
    }

    actor Cache {
        var lists: [URL: [TorrentFile]] = [:]
        func store(_ files: [TorrentFile], for url: URL) { lists[url] = files }
    }
}
