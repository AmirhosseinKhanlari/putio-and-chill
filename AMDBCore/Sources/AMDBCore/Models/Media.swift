import Foundation

/// What to look for. The IMDb id is optional: TMDB has shows without one (e.g. "Monster: The Ed Gein Story"), and those
/// are searched by title. Sources that only work by IMDb id skip such queries or fall back to their text search.
public enum MediaQuery: Sendable, Hashable {
    case movie(imdbID: String?, title: String, year: Int?)
    case episode(imdbID: String?, title: String, season: Int, episode: Int)
    case season(imdbID: String?, title: String, season: Int)
    case text(String)

    /// What free-text sources are asked: the title without punctuation, then the year or SxxEyy.
    public var searchText: String {
        switch self {
        case let .movie(_, title, year): year.map { "\(Self.searchTitle(title)) \($0)" } ?? Self.searchTitle(title)
        case let .episode(_, title, season, episode): "\(Self.searchTitle(title)) S\(twoDigits(season))E\(twoDigits(episode))"
        case let .season(_, title, season): "\(Self.searchTitle(title)) S\(twoDigits(season))"
        case let .text(text): text
        }
    }

    public var imdbID: String? {
        switch self {
        case let .movie(id, _, _), let .episode(id, _, _, _), let .season(id, _, _): id.flatMap { $0.isEmpty ? nil : $0 }
        case .text: nil
        }
    }

    /// The movie or show title asked for (nil for free text).
    public var title: String? {
        switch self {
        case let .movie(_, title, _), let .episode(_, title, _, _), let .season(_, title, _): title
        case .text: nil
        }
    }

    /// Release names leave punctuation out ("Monster: The Ed Gein Story" → "Monster The Ed Gein Story"), and so must
    /// the search, or sites that match every word find nothing. Apostrophes join ("Grey's" → "Greys").
    public static func searchTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"['’]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
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
    /// The files inside, when the source listed them with the result (TorrentGalaxy's detail page).
    public var files: [TorrentFile]?
    /// Where the file list can be read on request (apibay), for the few releases worth checking.
    public var fileListURL: URL?

    public init(name: String, link: String, infoHash: String? = nil, sizeBytes: Int64? = nil,
                seeders: Int? = nil, sources: Set<SourceTag>, parsed: ParsedRelease? = nil,
                files: [TorrentFile]? = nil, fileListURL: URL? = nil) {
        self.name = name
        self.link = link
        self.infoHash = infoHash ?? Magnet.infoHash(from: link)
        self.sizeBytes = sizeBytes
        self.seeders = seeders
        self.sources = sources
        self.parsed = parsed ?? ReleaseNameParser.parse(name)
        self.files = files
        self.fileListURL = fileListURL
    }

    /// Merge key: infohash when known, otherwise normalized name + size.
    public var id: String { infoHash ?? "\(name.lowercased())|\(sizeBytes ?? -1)" }
}
