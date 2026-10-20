import Foundation

public struct SourceConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var baseURL: String

    public init(id: String, name: String, enabled: Bool, baseURL: String) {
        self.id = id; self.name = name; self.enabled = enabled; self.baseURL = baseURL
    }
}

/// Smart one-tap Get: preferred resolution and size cap (nil = no limit).
public struct SmartGetRule: Codable, Sendable, Equatable, Hashable {
    public var resolution: Int?
    public var maxSizeGB: Double?

    public init(resolution: Int?, maxSizeGB: Double?) { self.resolution = resolution; self.maxSizeGB = maxSizeGB }

    public static let recommended = SmartGetRule(resolution: 1080, maxSizeGB: 10)
}

/// A put.io folder picked by the user, with its path for display ("Media/Movies").
public struct PutioFolderRef: Codable, Sendable, Hashable {
    public var id: Int64
    public var path: String

    public init(id: Int64, path: String) { self.id = id; self.path = path }
}

/// How the app draws subtitles: size, background box, text color and typeface.
public struct SubtitleStyle: Codable, Sendable, Hashable {
    public enum Size: String, Codable, Sendable, CaseIterable { case small, medium, large, extraLarge }
    public enum Background: String, Codable, Sendable, CaseIterable { case none, translucent, solid }
    public enum TextColor: String, Codable, Sendable, CaseIterable { case white, yellow, cyan, green }
    public enum Typeface: String, Codable, Sendable, CaseIterable { case standard, rounded, serif, monospaced }

    public var size: Size
    public var background: Background
    public var color: TextColor
    public var typeface: Typeface

    public init(size: Size = .medium, background: Background = .translucent, color: TextColor = .white,
                typeface: Typeface = .standard) {
        self.size = size; self.background = background; self.color = color; self.typeface = typeface
    }

    public static let standard = SubtitleStyle()

    /// Unknown or missing values fall back to the defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = (try? c.decodeIfPresent(Size.self, forKey: .size)) ?? .medium
        background = (try? c.decodeIfPresent(Background.self, forKey: .background)) ?? .translucent
        color = (try? c.decodeIfPresent(TextColor.self, forKey: .color)) ?? .white
        typeface = (try? c.decodeIfPresent(Typeface.self, forKey: .typeface)) ?? .standard
    }

    enum CodingKeys: String, CodingKey { case size, background, color, typeface }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var sources: [SourceConfig]
    /// Resolution raw value (2160, 1080, 720, 480) preselected in the Versions sheet; nil means "All".
    public var defaultResolution: Int?
    public var autoPlayCountdown: Bool
    public var autoPlayNextEpisode = true
    /// "Get & Watch" sends the best release by `smartGet` instead of opening Versions.
    public var oneTapGet = true
    public var smartGet = SmartGetRule.recommended
    /// ISO 639-1 codes; nil audio = original track, nil subtitles = off.
    public var audioLanguage: String?
    public var subtitleLanguage: String?
    /// Delete movies finished in AMDB after this many days; nil = off.
    public var autoCleanDays: Int?
    /// The user has reviewed the first auto-clean list.
    public var autoCleanConfirmed = false
    /// Offline downloads: highest quality, or a smaller data-saver stream.
    public var downloadDataSaver = false
    public var subtitleStyle = SubtitleStyle.standard
    /// Keep the put.io library up to date on its own (while open, and in the background).
    public var libraryAutoUpdate = true
    /// How often the automatic library update runs.
    public var libraryUpdateMinutes = 60
    /// Where movies and shows are saved in put.io; nil = Movies and TV Series at the top of put.io.
    public var moviesFolder: PutioFolderRef?
    public var tvFolder: PutioFolderRef?
    /// Episodes go into "Season N" folders inside the show's folder.
    public var seasonFolders = true
    /// Play the copy on this device when there is one (otherwise always stream).
    public var preferDownloads = true
    /// Notify about new episodes of followed shows, on release day at `episodeAlertHour` (0–23, local time).
    public var episodeAlerts = true
    public var episodeAlertHour = 9
    /// A video Apple's player can't play: the built-in player plays the original file, or put.io converts it.
    public var unsupportedVideoPlayer = UnsupportedVideoPlayer.builtIn

    public init(sources: [SourceConfig], defaultResolution: Int?, autoPlayCountdown: Bool) {
        self.sources = sources; self.defaultResolution = defaultResolution; self.autoPlayCountdown = autoPlayCountdown
    }

    enum CodingKeys: String, CodingKey {
        case sources, defaultResolution, autoPlayCountdown, autoPlayNextEpisode, oneTapGet, smartGet, audioLanguage, subtitleLanguage
        case autoCleanDays, autoCleanConfirmed, downloadDataSaver, subtitleStyle, libraryAutoUpdate, libraryUpdateMinutes
        case moviesFolder, tvFolder, seasonFolders, preferDownloads, episodeAlerts, episodeAlertHour, unsupportedVideoPlayer
    }

    /// Settings saved by older versions keep their values and pick up defaults for new options.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([SourceConfig].self, forKey: .sources) ?? AppSettings.defaults.sources
        defaultResolution = try c.decodeIfPresent(Int.self, forKey: .defaultResolution)
        autoPlayCountdown = try c.decodeIfPresent(Bool.self, forKey: .autoPlayCountdown) ?? true
        autoPlayNextEpisode = try c.decodeIfPresent(Bool.self, forKey: .autoPlayNextEpisode) ?? true
        oneTapGet = try c.decodeIfPresent(Bool.self, forKey: .oneTapGet) ?? true
        smartGet = try c.decodeIfPresent(SmartGetRule.self, forKey: .smartGet) ?? .recommended
        audioLanguage = try c.decodeIfPresent(String.self, forKey: .audioLanguage)
        subtitleLanguage = try c.decodeIfPresent(String.self, forKey: .subtitleLanguage)
        autoCleanDays = try c.decodeIfPresent(Int.self, forKey: .autoCleanDays)
        autoCleanConfirmed = try c.decodeIfPresent(Bool.self, forKey: .autoCleanConfirmed) ?? false
        downloadDataSaver = try c.decodeIfPresent(Bool.self, forKey: .downloadDataSaver) ?? false
        subtitleStyle = (try? c.decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle)) ?? .standard
        libraryAutoUpdate = try c.decodeIfPresent(Bool.self, forKey: .libraryAutoUpdate) ?? true
        libraryUpdateMinutes = max(try c.decodeIfPresent(Int.self, forKey: .libraryUpdateMinutes) ?? 60, 5)
        moviesFolder = try? c.decodeIfPresent(PutioFolderRef.self, forKey: .moviesFolder)
        tvFolder = try? c.decodeIfPresent(PutioFolderRef.self, forKey: .tvFolder)
        seasonFolders = try c.decodeIfPresent(Bool.self, forKey: .seasonFolders) ?? true
        preferDownloads = try c.decodeIfPresent(Bool.self, forKey: .preferDownloads) ?? true
        episodeAlerts = try c.decodeIfPresent(Bool.self, forKey: .episodeAlerts) ?? true
        episodeAlertHour = min(max(try c.decodeIfPresent(Int.self, forKey: .episodeAlertHour) ?? 9, 0), 23)
        unsupportedVideoPlayer = (try? c.decodeIfPresent(UnsupportedVideoPlayer.self, forKey: .unsupportedVideoPlayer)) ?? .builtIn
    }

    public static let defaults = AppSettings(sources: [
        SourceConfig(id: "chill", name: "chill", enabled: true, baseURL: "https://api.chill.institute/v4"),
        SourceConfig(id: "yts", name: "YTS", enabled: true, baseURL: "https://movies-api.accel.li"),
        SourceConfig(id: "eztv", name: "EZTV", enabled: true, baseURL: "https://eztvx.to"),
        SourceConfig(id: "apibay", name: "The Pirate Bay (apibay)", enabled: true, baseURL: "https://apibay.org"),
        SourceConfig(id: "knaben", name: "Knaben", enabled: true, baseURL: "https://api.knaben.org"),
        SourceConfig(id: "torrentscsv", name: "Torrents.csv", enabled: true, baseURL: "https://torrents-csv.com"),
        SourceConfig(id: "torrentgalaxy", name: "TorrentGalaxy", enabled: true, baseURL: "https://torrentgalaxy.info"),
    ], defaultResolution: nil, autoPlayCountdown: true)

    public func source(_ id: String) -> SourceConfig? { sources.first { $0.id == id } }

    static let storageKey = "amdb.settings"

    public static func load(from userDefaults: UserDefaults) -> AppSettings {
        guard let data = userDefaults.data(forKey: storageKey),
              var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else { return .defaults }
        for source in AppSettings.defaults.sources where decoded.source(source.id) == nil {
            decoded.sources.append(source)
        }
        return decoded
    }

    /// The same settings with any folder pick that is the old AMDB/Movies or AMDB/TV set back to the default (those
    /// folders are merged into Movies and TV Series and then removed).
    public func withoutOldFolderPicks(oldIDs: Set<Int64> = []) -> AppSettings {
        var settings = self
        if let movies = moviesFolder, DefaultFolders.isOldFolder(movies, oldIDs: oldIDs) { settings.moviesFolder = nil }
        if let tv = tvFolder, DefaultFolders.isOldFolder(tv, oldIDs: oldIDs) { settings.tvFolder = nil }
        return settings
    }

    public func save(to userDefaults: UserDefaults) {
        userDefaults.set(try? JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
