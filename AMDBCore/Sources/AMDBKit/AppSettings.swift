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

    public init(sources: [SourceConfig], defaultResolution: Int?, autoPlayCountdown: Bool) {
        self.sources = sources; self.defaultResolution = defaultResolution; self.autoPlayCountdown = autoPlayCountdown
    }

    enum CodingKeys: String, CodingKey {
        case sources, defaultResolution, autoPlayCountdown, autoPlayNextEpisode, oneTapGet, smartGet, audioLanguage, subtitleLanguage
        case autoCleanDays, autoCleanConfirmed, downloadDataSaver
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
    }

    public static let defaults = AppSettings(sources: [
        SourceConfig(id: "chill", name: "chill", enabled: true, baseURL: "https://api.chill.institute/v4"),
        SourceConfig(id: "yts", name: "YTS", enabled: true, baseURL: "https://movies-api.accel.li"),
        SourceConfig(id: "eztv", name: "EZTV", enabled: true, baseURL: "https://eztvx.to"),
        SourceConfig(id: "apibay", name: "The Pirate Bay (apibay)", enabled: true, baseURL: "https://apibay.org"),
        SourceConfig(id: "knaben", name: "Knaben", enabled: true, baseURL: "https://api.knaben.org"),
        SourceConfig(id: "torrentscsv", name: "Torrents.csv", enabled: true, baseURL: "https://torrents-csv.com"),
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

    public func save(to userDefaults: UserDefaults) {
        userDefaults.set(try? JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
