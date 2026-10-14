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

/// What's shown for one put.io file: a put.io track, an OpenSubtitles file, or explicitly nothing; plus the timing shift.
public struct SubtitleChoice: Codable, Sendable, Hashable {
    /// OpenSubtitles file ID (0 for put.io tracks and "off").
    public let subtitleFileID: Int
    /// put.io subtitle key, when the choice is one of put.io's tracks.
    public let putioKey: String?
    public let language: String
    public let release: String
    /// Seconds; positive shows subtitles later.
    public var offset: Double
    /// The user turned subtitles off for this file (beats the preferred-language default).
    public let isOff: Bool

    public init(subtitleFileID: Int, language: String, release: String, offset: Double = 0, putioKey: String? = nil,
                isOff: Bool = false) {
        self.subtitleFileID = subtitleFileID; self.language = language; self.release = release; self.offset = offset
        self.putioKey = putioKey; self.isOff = isOff
    }

    static let off = SubtitleChoice(subtitleFileID: 0, language: "", release: "", isOff: true)

    enum CodingKeys: String, CodingKey { case subtitleFileID, putioKey, language, release, offset, isOff }

    /// Fields added later are optional on disk.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtitleFileID = try c.decodeIfPresent(Int.self, forKey: .subtitleFileID) ?? 0
        putioKey = try c.decodeIfPresent(String.self, forKey: .putioKey)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        release = try c.decodeIfPresent(String.self, forKey: .release) ?? ""
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        isOff = try c.decodeIfPresent(Bool.self, forKey: .isOff) ?? false
    }
}

/// put.io's subtitles for the file being played (embedded tracks, files next to it, put.io's own OpenSubtitles fetches).
public struct PutioSubtitleSource: Sendable {
    public let list: @Sendable () async throws -> [PutioSubtitle]
    public let text: @Sendable (_ key: String) async throws -> String

    public init(list: @escaping @Sendable () async throws -> [PutioSubtitle],
                text: @escaping @Sendable (_ key: String) async throws -> String) {
        self.list = list
        self.text = text
    }
}

/// Subtitle files on disk (nil directory = memory only, for tests). OpenSubtitles files are kept so re-watching never
/// spends another download; put.io tracks so offline copies keep their subtitles.
public final class SubtitleFileCache: @unchecked Sendable {
    private let directory: URL?
    private let lock = NSLock()
    private var memory: [String: String] = [:]

    public init(directory: URL?) { self.directory = directory }

    public static func defaultDirectory() -> URL {
        StorageLocation.directory.appending(path: "Subtitles")
    }

    public func read(_ id: Int) -> String? { read(name: "\(id).srt") }
    public func write(_ text: String, for id: Int) { write(text, name: "\(id).srt") }

    public func readPutio(fileID: Int64, key: String) -> String? { read(name: Self.putioName(fileID, key)) }
    public func writePutio(_ text: String, fileID: Int64, key: String) { write(text, name: Self.putioName(fileID, key)) }

    public func readPutioList(fileID: Int64) -> [PutioSubtitle]? {
        read(name: "putio-\(fileID)-list.json").flatMap { try? JSONDecoder().decode([PutioSubtitle].self, from: Data($0.utf8)) }
    }

    public func writePutioList(_ tracks: [PutioSubtitle], fileID: Int64) {
        guard let data = try? JSONEncoder().encode(tracks), let text = String(data: data, encoding: .utf8) else { return }
        write(text, name: "putio-\(fileID)-list.json")
    }

    private static func putioName(_ fileID: Int64, _ key: String) -> String {
        "putio-\(fileID)-\(key.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }).srt"
    }

    private func read(name: String) -> String? {
        if let cached = lock.withLock({ memory[name] }) { return cached }
        guard let directory else { return nil }
        return try? String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }

    private func write(_ text: String, name: String) {
        lock.withLock { memory[name] = text }
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
    }
}

/// Every subtitle option for one video in one place: put.io's tracks plus an OpenSubtitles search.
/// Picks are remembered per file with their timing; the preferred language from Settings is applied when nothing was picked.
@Observable @MainActor
public final class SubtitleFinder {
    public let context: SubtitleContext
    /// OpenSubtitles search language.
    public var language: String
    public private(set) var putioTracks: [PutioSubtitle] = []
    public private(set) var results: [SubtitleResult] = []
    public private(set) var isSearching = false
    public private(set) var searched = false
    public private(set) var downloadingID: Int?
    public private(set) var loadingPutioKey: String?
    public private(set) var message: String?
    public private(set) var choice: SubtitleChoice?
    public private(set) var track: SubtitleTrack?
    public private(set) var remainingDownloads: Int?

    /// OpenSubtitles search is set up (API key present).
    public var canSearch: Bool { service != nil }
    public var isShowing: Bool { track != nil }

    @ObservationIgnored private let service: (any SubtitleService)?
    @ObservationIgnored private let putio: PutioSubtitleSource?
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let cache: SubtitleFileCache
    @ObservationIgnored private let preferredLanguage: String?
    @ObservationIgnored private let session: @MainActor () async -> OpenSubtitlesLogin?
    @ObservationIgnored private let hasher: (@Sendable () async -> String?)?
    @ObservationIgnored private let signedIn: Bool
    @ObservationIgnored private var movieHash: String??

    public init(context: SubtitleContext, service: (any SubtitleService)?, putio: PutioSubtitleSource? = nil, store: LocalStore,
                cache: SubtitleFileCache, language: String, preferredLanguage: String? = nil, signedIn: Bool = false,
                session: @escaping @MainActor () async -> OpenSubtitlesLogin? = { nil },
                hasher: (@Sendable () async -> String?)? = nil) {
        self.context = context
        self.service = service
        self.putio = putio
        self.store = store
        self.cache = cache
        self.language = Self.openSubtitlesCode(language)
        self.preferredLanguage = preferredLanguage
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

    /// Loads put.io's tracks, then shows what was picked for this file last time, or else put.io's track in the
    /// preferred language from Settings.
    public func restore() async {
        await loadPutioTracks()
        let saved = await store.snapshot.subtitleChoices[context.fileID]
        if let saved {
            guard !saved.isOff else { choice = saved; return }
            if let key = saved.putioKey {
                if let text = await putioText(key) { show(text, as: saved) }
            } else if let text = cache.read(saved.subtitleFileID) {
                show(text, as: saved)
            }
            return
        }
        guard let preferredLanguage, let match = Self.bestTrack(putioTracks, for: preferredLanguage),
              let text = await putioText(match.key) else { return }
        // Not saved: changing the language in Settings later still applies to this file.
        show(text, as: Self.choice(for: match))
    }

    /// Text to draw at `time`, with the timing shift applied.
    public func text(at time: Double) -> String? {
        guard let track else { return nil }
        return track.text(at: time - (choice?.offset ?? 0))
    }

    // MARK: put.io

    public func choose(_ putioTrack: PutioSubtitle) async {
        guard loadingPutioKey == nil else { return }
        loadingPutioKey = putioTrack.key
        message = nil
        defer { loadingPutioKey = nil }
        guard let text = await putioText(putioTrack.key), !SubtitleParser.parse(text).cues.isEmpty else {
            message = "Couldn't load that subtitle from put.io."
            return
        }
        let picked = Self.choice(for: putioTrack, offset: choice?.putioKey == putioTrack.key ? choice?.offset ?? 0 : 0)
        show(text, as: picked)
        await save(picked)
    }

    /// The track in `language`, preferring ones inside the file, then files next to it, then put.io's own fetches.
    public static func bestTrack(_ tracks: [PutioSubtitle], for language: String) -> PutioSubtitle? {
        let wanted = LanguageMatcher.normalize(language)
        let englishName = Locale(identifier: "en_US").localizedString(forLanguageCode: wanted)?.lowercased()
        let matching = tracks.filter { track in
            if let code = track.languageCode, LanguageMatcher.normalize(code) == wanted { return true }
            return track.language?.lowercased() == englishName
        }
        let rank = ["mkv": 0, "folder": 1]
        return matching.min { (rank[$0.source ?? ""] ?? 2) < (rank[$1.source ?? ""] ?? 2) }
    }

    static func choice(for track: PutioSubtitle, offset: Double = 0) -> SubtitleChoice {
        SubtitleChoice(subtitleFileID: 0, language: track.languageCode ?? track.language ?? "",
                       release: track.name ?? track.language ?? "put.io subtitle", offset: offset, putioKey: track.key)
    }

    private func loadPutioTracks() async {
        guard let putio else { return }
        if let tracks = try? await putio.list() {
            putioTracks = tracks
            cache.writePutioList(tracks, fileID: context.fileID)
        } else {
            putioTracks = cache.readPutioList(fileID: context.fileID) ?? []
        }
    }

    private func putioText(_ key: String) async -> String? {
        if let cached = cache.readPutio(fileID: context.fileID, key: key) { return cached }
        guard let putio, let text = try? await putio.text(key) else { return nil }
        cache.writePutio(text, fileID: context.fileID, key: key)
        return text
    }

    // MARK: OpenSubtitles

    public func search() async {
        guard let service else {
            message = "Add an OpenSubtitles API key in Settings to search for more subtitles."
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
            guard !SubtitleParser.parse(text).cues.isEmpty else {
                message = "That subtitle file couldn't be read. Try another one."
                return
            }
            let picked = SubtitleChoice(subtitleFileID: result.fileID, language: result.language, release: result.release)
            show(text, as: picked)
            await save(picked)
        } catch OpenSubtitlesError.quotaReached {
            message = signedIn
                ? "You've used today's OpenSubtitles downloads. Subtitles you already picked still work."
                : "You've used today's free OpenSubtitles downloads. Sign in to OpenSubtitles in Settings for more."
        } catch {
            message = "Couldn't download that subtitle. Try again or pick another."
        }
    }

    // MARK: Both

    public func shiftTiming(by delta: Double) async {
        guard var current = choice, !current.isOff else { return }
        current.offset = (current.offset + delta).rounded(toPlaces: 1)
        choice = current
        await save(current)
    }

    public func turnOff() async {
        choice = .off
        track = nil
        await save(.off)
    }

    private func show(_ text: String, as picked: SubtitleChoice) {
        choice = picked
        track = SubtitleParser.parse(text)
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
