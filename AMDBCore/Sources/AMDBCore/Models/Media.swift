import Foundation

public enum MediaQuery: Sendable, Hashable {
    case movie(imdbID: String, title: String, year: Int?)
    case episode(imdbID: String, title: String, season: Int, episode: Int)
    case season(imdbID: String, title: String, season: Int)
    case text(String)

    public var searchText: String {
        switch self {
        case let .movie(_, title, year): year.map { "\(title) \($0)" } ?? title
        case let .episode(_, title, season, episode): "\(title) S\(twoDigits(season))E\(twoDigits(episode))"
        case let .season(_, title, season): "\(title) S\(twoDigits(season))"
        case let .text(text): text
        }
    }

    public var imdbID: String? {
        switch self {
        case let .movie(id, _, _), let .episode(id, _, _, _), let .season(id, _, _): id
        case .text: nil
        }
    }
}

func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

public struct SourceTag: Hashable, Sendable, Comparable {
    public enum Kind: String, Sendable { case chill, direct }
    public let kind: Kind
    public let name: String
    public init(_ kind: Kind, _ name: String) { self.kind = kind; self.name = name }
    public var label: String { "\(kind.rawValue) · \(name)" }
    public static func < (a: SourceTag, b: SourceTag) -> Bool { a.label < b.label }
}

public enum Resolution: Int, Sendable, Comparable, CaseIterable {
    case unknown = 0, sd480 = 480, hd720 = 720, fhd1080 = 1080, uhd2160 = 2160, uhd4320 = 4320

    public init(label: String) {
        let digits = label.prefix { $0.isNumber }
        self = Int(digits).flatMap(Resolution.init(rawValue:))
            ?? (label.uppercased() == "4K" ? .uhd2160 : label.uppercased() == "8K" ? .uhd4320 : .unknown)
    }

    public var label: String {
        switch self {
        case .unknown: "?"
        case .sd480: "480p"
        case .hd720: "720p"
        case .fhd1080: "1080p"
        case .uhd2160: "2160p"
        case .uhd4320: "4320p"
        }
    }

    public static func < (a: Resolution, b: Resolution) -> Bool { a.rawValue < b.rawValue }
}

public struct ParsedRelease: Sendable, Hashable {
    public var title = ""
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var episodeEnd: Int?
    public var resolution: Resolution = .unknown
    public var source: String?
    public var codec: String?
    public var hdr: [String] = []
    public var audio: String?
    public var group: String?
    public var isProper = false
    public var isRepack = false
    public var isExtended = false
    public var isComplete = false

    public init() {}
    public var isSeasonPack: Bool { season != nil && episode == nil }
}

public struct Release: Sendable, Hashable, Identifiable {
    public var name: String
    public var link: String
    public var infoHash: String?
    public var sizeBytes: Int64?
    public var seeders: Int?
    public var sources: Set<SourceTag>
    public var parsed: ParsedRelease

    public init(name: String, link: String, infoHash: String? = nil, sizeBytes: Int64? = nil,
                seeders: Int? = nil, sources: Set<SourceTag>, parsed: ParsedRelease? = nil) {
        self.name = name
        self.link = link
        self.infoHash = infoHash ?? Magnet.infoHash(from: link)
        self.sizeBytes = sizeBytes
        self.seeders = seeders
        self.sources = sources
        self.parsed = parsed ?? ReleaseNameParser.parse(name)
    }

    /// Merge key: infohash when known, otherwise normalized name + size.
    public var id: String { infoHash ?? "\(name.lowercased())|\(sizeBytes ?? -1)" }
}
