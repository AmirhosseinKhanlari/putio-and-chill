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

public struct AppSettings: Codable, Sendable, Equatable {
    public var sources: [SourceConfig]
    /// Resolution raw value (2160, 1080, 720, 480) preselected in the Versions sheet; nil means "All".
    public var defaultResolution: Int?
    public var autoPlayCountdown: Bool

    public init(sources: [SourceConfig], defaultResolution: Int?, autoPlayCountdown: Bool) {
        self.sources = sources; self.defaultResolution = defaultResolution; self.autoPlayCountdown = autoPlayCountdown
    }

    public static let defaults = AppSettings(sources: [
        SourceConfig(id: "chill", name: "chill", enabled: true, baseURL: "https://api.chill.institute/v4"),
        SourceConfig(id: "yts", name: "YTS", enabled: true, baseURL: "https://movies-api.accel.li"),
        SourceConfig(id: "eztv", name: "EZTV", enabled: true, baseURL: "https://eztvx.to"),
        SourceConfig(id: "apibay", name: "The Pirate Bay (apibay)", enabled: true, baseURL: "https://apibay.org"),
        SourceConfig(id: "knaben", name: "Knaben", enabled: true, baseURL: "https://api.knaben.org"),
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
