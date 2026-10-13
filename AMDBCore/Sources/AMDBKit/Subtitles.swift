import AMDBCore
import Foundation
import Observation

public protocol SubtitleService: Sendable {
    func search(_ search: SubtitleSearch) async throws -> [SubtitleResult]
    func download(fileID: Int, login: OpenSubtitlesLogin?) async throws -> SubtitleDownload
    func text(at link: URL) async throws -> String
    func login(username: String, password: String) async throws -> OpenSubtitlesLogin
}

extension OpenSubtitlesClient: SubtitleService {}

/// The video a subtitle is for.
public struct SubtitleContext: Sendable, Hashable {
    public let fileID: Int64
    public let fileName: String
    public let title: String
    public let tmdbID: Int?
    public let kind: MediaKind?
    public let season: Int?
    public let episode: Int?

    public init(fileID: Int64, fileName: String, title: String, tmdbID: Int?, kind: MediaKind?, season: Int?, episode: Int?) {
        self.fileID = fileID; self.fileName = fileName; self.title = title
        self.tmdbID = tmdbID; self.kind = kind; self.season = season; self.episode = episode
    }
}

/// The OpenSubtitles file picked for one put.io file, with the user's timing shift.
public struct SubtitleChoice: Codable, Sendable, Hashable {
    public let subtitleFileID: Int
    public let language: String
    public let release: String
    /// Seconds; positive shows subtitles later.
    public var offset: Double

    public init(subtitleFileID: Int, language: String, release: String, offset: Double = 0) {
        self.subtitleFileID = subtitleFileID; self.language = language; self.release = release; self.offset = offset
    }
}

/// Downloaded subtitle files on disk (nil directory = memory only, for tests), keyed by OpenSubtitles file ID.
/// Kept so re-watching never spends another download.
public final class SubtitleFileCache: @unchecked Sendable {
    private let directory: URL?
    private let lock = NSLock()
    private var memory: [Int: String] = [:]

    public init(directory: URL?) { self.directory = directory }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "AMDB/Subtitles")
    }

    public func read(_ id: Int) -> String? {
        if let cached = lock.withLock({ memory[id] }) { return cached }
        guard let directory else { return nil }
        return try? String(contentsOf: directory.appending(path: "\(id).srt"), encoding: .utf8)
    }

    public func write(_ text: String, for id: Int) {
        lock.withLock { memory[id] = text }
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: directory.appending(path: "\(id).srt"), atomically: true, encoding: .utf8)
    }
}

/// Find-and-show subtitles from OpenSubtitles for one video: search, download, remember, shift timing.
@Observable @MainActor
public final class SubtitleFinder {
    public let context: SubtitleContext
    public var language: String
    public private(set) var results: [SubtitleResult] = []
    public private(set) var isSearching = false
    public private(set) var searched = false
    public private(set) var downloadingID: Int?
    public private(set) var message: String?
    public private(set) var choice: SubtitleChoice?
    public private(set) var track: SubtitleTrack?
    public private(set) var remainingDownloads: Int?

    public var isAvailable: Bool { service != nil }

    @ObservationIgnored private let service: (any SubtitleService)?
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let cache: SubtitleFileCache
    @ObservationIgnored private let session: @MainActor () async -> OpenSubtitlesLogin?
    @ObservationIgnored private let hasher: (@Sendable () async -> String?)?
    @ObservationIgnored private let signedIn: Bool
    @ObservationIgnored private var movieHash: String??

    public init(context: SubtitleContext, service: (any SubtitleService)?, store: LocalStore, cache: SubtitleFileCache,
                language: String, signedIn: Bool = false, session: @escaping @MainActor () async -> OpenSubtitlesLogin? = { nil },
                hasher: (@Sendable () async -> String?)? = nil) {
        self.context = context
        self.service = service
        self.store = store
        self.cache = cache
        self.language = Self.openSubtitlesCode(language)
        self.signedIn = signedIn
        self.session = session
        self.hasher = hasher
    }

    /// OpenSubtitles uses regional codes for a few languages.
    public static func openSubtitlesCode(_ code: String) -> String {
        switch code.lowercased() {
        case "pt": "pt-pt"
        case "zh": "zh-cn"
        default: code.lowercased()
        }
    }

    /// Re-applies the subtitle chosen for this file last time (from disk, no download).
    public func restore() async {
        guard let saved = await store.snapshot.subtitleChoices[context.fileID],
              let text = cache.read(saved.subtitleFileID) else { return }
        choice = saved
        track = SubtitleParser.parse(text)
    }

    /// Text to draw at `time`, with the timing shift applied.
    public func text(at time: Double) -> String? {
        guard let track else { return nil }
        return track.text(at: time - (choice?.offset ?? 0))
    }

    public func search() async {
        guard let service else {
            message = "Add an OpenSubtitles API key in Settings to search for subtitles."
            return
        }
        isSearching = true
        message = nil
        defer { isSearching = false; searched = true }
        if movieHash == nil { movieHash = .some(await hasher?()) }
        let parsed = ReleaseNameParser.parse(context.fileName)
        let season = context.season ?? parsed.season
        let episode = context.episode ?? parsed.episode
        let byID = SubtitleSearch(tmdbID: context.tmdbID, kind: context.kind ?? (season != nil ? .tv : .movie), season: season,
                                  episode: episode, query: nil, languages: [language], movieHash: movieHash ?? nil)
        do {
            var found = context.tmdbID == nil ? [] : try await service.search(byID)
            if found.isEmpty {
                // No TMDB match (or nothing listed under it): fall back to the title text.
                let query = parsed.title.isEmpty ? context.title : parsed.title
                found = try await service.search(SubtitleSearch(tmdbID: nil, kind: nil, season: season, episode: episode, query: query,
                                                                languages: [language], movieHash: movieHash ?? nil))
            }
            results = found
        } catch {
            results = []
            message = "Couldn't reach OpenSubtitles. Try again in a moment."
        }
    }

    public func choose(_ result: SubtitleResult) async {
        guard let service, downloadingID == nil else { return }
        downloadingID = result.fileID
        message = nil
        defer { downloadingID = nil }
        do {
            let text: String
            if let cached = cache.read(result.fileID) {
                text = cached
            } else {
                let download = try await service.download(fileID: result.fileID, login: await session())
                remainingDownloads = download.remaining
                text = try await service.text(at: download.link)
                cache.write(text, for: result.fileID)
            }
            let parsed = SubtitleParser.parse(text)
            guard !parsed.cues.isEmpty else {
                message = "That subtitle file couldn't be read. Try another one."
                return
            }
            let picked = SubtitleChoice(subtitleFileID: result.fileID, language: result.language, release: result.release)
            choice = picked
            track = parsed
            await save(picked)
        } catch OpenSubtitlesError.quotaReached {
            message = signedIn
                ? "You've used today's OpenSubtitles downloads. Subtitles you already picked still work."
                : "You've used today's free OpenSubtitles downloads. Sign in to OpenSubtitles in Settings for more."
        } catch {
            message = "Couldn't download that subtitle. Try again or pick another."
        }
    }

    public func shiftTiming(by delta: Double) async {
        guard var current = choice else { return }
        current.offset = (current.offset + delta).rounded(toPlaces: 1)
        choice = current
        await save(current)
    }

    public func turnOff() async {
        choice = nil
        track = nil
        let fileID = context.fileID
        await store.update { $0.subtitleChoices[fileID] = nil }
    }

    private func save(_ choice: SubtitleChoice) async {
        let fileID = context.fileID
        await store.update { $0.subtitleChoices[fileID] = choice }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
