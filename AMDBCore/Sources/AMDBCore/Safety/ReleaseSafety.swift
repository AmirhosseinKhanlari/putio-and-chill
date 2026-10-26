import Foundation

/// One file inside a torrent, as a source lists it.
public struct TorrentFile: Sendable, Hashable {
    public let name: String
    public let sizeBytes: Int64?
    public init(name: String, sizeBytes: Int64?) { self.name = name; self.sizeBytes = sizeBytes }
}

/// Why a release was left out. `description` is the short reason written to the debug log.
public enum ReleaseRejection: Sendable, Hashable, CustomStringConvertible {
    /// The name ends in a program or installer ("….exe", "….apk").
    case program(String)
    /// The name ends in an archive (".zip", ".rar"): nothing in it can be streamed.
    case archive(String)
    /// A disc image that isn't named or sized like a real BluRay / DVD.
    case discImage
    /// Wording fakes use ("codec required", "keygen", a web address).
    case spam(String)
    case tooSmall(bytes: Int64, minimum: Int64)
    case tooLarge(bytes: Int64, maximum: Int64)
    /// From the file list: the biggest file isn't a video.
    case notVideo(largest: String)
    /// From the file list: a program is inside.
    case containsProgram(String)
    /// Downloaded before, and it turned out fake.
    case knownBad

    public var description: String {
        switch self {
        case let .program(ext): "program file (.\(ext))"
        case let .archive(ext): "archive (.\(ext))"
        case .discImage: "disc image that doesn't look like a real disc"
        case let .spam(marker): "fake wording \"\(marker)\""
        case let .tooSmall(bytes, minimum): "too small (\(Self.megabytes(bytes)) < \(Self.megabytes(minimum)))"
        case let .tooLarge(bytes, maximum): "too large (\(Self.megabytes(bytes)) > \(Self.megabytes(maximum)))"
        case let .notVideo(largest): "biggest file isn't a video (\(largest))"
        case let .containsProgram(name): "contains a program (\(name))"
        case .knownBad: "downloaded before and found fake"
        }
    }

    private static func megabytes(_ bytes: Int64) -> String { "\(bytes / ReleaseSafety.mb) MB" }
}

/// Spots fake and malware torrents: releases named like a video but carrying a program, an archive or a tiny file.
/// Kept tight on purpose, so real releases (whose names follow scene habits) never trip it; unknown sizes and file
/// lists are never held against a release.
public enum ReleaseSafety {
    static let mb: Int64 = 1_048_576
    static let gb: Int64 = 1_073_741_824

    /// Payloads that run code. ".com" is left out: plenty of real names end with a site ("…-www.Site.com").
    public static let programExtensions: Set<String> = [
        "exe", "scr", "bat", "cmd", "msi", "lnk", "pif", "vbs", "js", "jar", "apk", "dmg", "pkg",
    ]
    /// Programs that can also be named mid-name ("Movie.2025.1080p.exe [x]"). The rest stay end-only, because they
    /// read as words or tags elsewhere ("The.Bat.1959", "SCR" for screener).
    static let programsAnywhere = ["exe", "msi", "lnk", "vbs", "pif"]
    public static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz"]
    public static let discExtensions: Set<String> = ["iso", "img"]
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "wmv", "webm", "mpg", "mpeg", "vob", "divx", "flv",
    ]

    /// Phrases no real release uses.
    static let spamPhrases: [(pattern: String, marker: String)] = [
        (#"(?i)\bcodecs?[ .]*(?:required|needed|pack|download|install)"#, "codec required"),
        (#"(?i)\b(?:divx|xvid|video)[ .]+codec\b"#, "codec"),
        (#"(?i)\bplayer[ .]*required\b"#, "player required"),
        (#"(?i)\bwatch[ .]*online\b"#, "watch online"),
        (#"(?i)\bfull[ .]*movie[ .]*free\b"#, "full movie free"),
        (#"(?i)\b(?:free[ .]*download|download[ .]*free)\b"#, "free download"),
        (#"(?i)\bhttps?://"#, "web address"),
        (#"(?i)\b(?:bit\.ly|tinyurl\.com|goo\.gl|cutt\.ly|shorturl\.at)\b"#, "short link"),
        (#"(?i)\bvisit[ .]+(?:www\.|https?\b)"#, "web address"),
    ]

    /// Single words fakes use. They don't count when the title asked for has them ("Crack" (2024), "The Setup").
    static let spamWords = ["codec", "codecs", "password", "passwd", "keygen", "crack", "setup", "install", "installer"]

    /// Disc names: an ".iso" passes only when named like a real disc and big enough to be one.
    static let discName = #"(?i)\b(?:blu[ .-]?ray|bdmv|bd(?:25|50|66|100)|uhd[ .-]?bd|dvd(?:5|9|r)?|video[ ._]ts)\b"#
    static let discMinimum: Int64 = 3 * gb
    /// Names that are several titles at once, where any size goes ("Trilogy", "Complete Series").
    static let collectionName = #"(?i)\b(?:collection|trilogy|duology|quadrilogy|saga|anthology|pack|box[ .-]?set|filmography|complete)\b"#

    /// Why the release looks fake from its name and size, or nil when it looks fine. `query` exempts words of the
    /// title asked for from the fake-word list.
    public static func rejection(_ release: Release, query: MediaQuery? = nil) -> ReleaseRejection? {
        rejection(name: release.name, sizeBytes: release.sizeBytes, parsed: release.parsed, query: query)
    }

    public static func rejection(name raw: String, sizeBytes: Int64?, parsed: ParsedRelease,
                                 query: MediaQuery? = nil) -> ReleaseRejection? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = endingExtension(name)
        if let ext, programExtensions.contains(ext) { return .program(ext) }
        if let found = programsAnywhere.first(where: { matches(name, #"(?i)\.\#($0)(?![A-Za-z0-9])"#) }) {
            return .program(found)
        }
        if let ext, archiveExtensions.contains(ext) { return .archive(ext) }
        if let ext, discExtensions.contains(ext) {
            let sized = sizeBytes.map { $0 >= discMinimum } ?? true
            if !matches(name, discName) || !sized { return .discImage }
        }
        if let marker = spam(in: name, query: query) { return .spam(marker) }
        if let sizeBytes, sizeBytes > 0 {
            let limits = sizeLimits(parsed, name: name)
            if sizeBytes < limits.minimum { return .tooSmall(bytes: sizeBytes, minimum: limits.minimum) }
            if let maximum = limits.maximum, sizeBytes > maximum { return .tooLarge(bytes: sizeBytes, maximum: maximum) }
        }
        return nil
    }

    /// Why the files inside look fake: a program among them, or a biggest file that isn't a video (a real disc image
    /// is allowed). An empty list says nothing.
    public static func rejection(files: [TorrentFile]) -> ReleaseRejection? {
        guard !files.isEmpty else { return nil }
        if let program = files.first(where: { isProgram($0.name) }) { return .containsProgram(baseName(program.name)) }
        guard let largest = files.max(by: { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) }) else { return nil }
        if isVideo(largest.name) { return nil }
        if discExtensions.contains(fileExtension(largest.name)), (largest.sizeBytes ?? 0) >= discMinimum { return nil }
        return .notVideo(largest: baseName(largest.name))
    }

    public static func isVideo(_ fileName: String) -> Bool { videoExtensions.contains(fileExtension(fileName)) }
    public static func isProgram(_ fileName: String) -> Bool { programExtensions.contains(fileExtension(fileName)) }
    public static func isDiscImage(_ fileName: String) -> Bool { discExtensions.contains(fileExtension(fileName)) }

    /// Smallest and largest believable size for what the name says it is. Minimums: a 2160p movie 1 GB, 1080p
    /// 150 MB, 720p 80 MB, anything else 40 MB; an episode 40 MB (20 MB below 720p), times the episodes a range or
    /// season pack holds (a pack counts as at least two). Maximums: 150 GB for one movie, 60 GB for one episode;
    /// packs and collections have none.
    public static func sizeLimits(_ parsed: ParsedRelease, name: String) -> (minimum: Int64, maximum: Int64?) {
        let resolution = parsed.resolution
        if parsed.season != nil || parsed.episode != nil {
            let perEpisode = resolution >= .hd720 ? 40 * mb : 20 * mb
            if let first = parsed.episode {
                let count = Int64(max((parsed.episodeEnd ?? first) - first + 1, 1))
                return (perEpisode * count, count == 1 ? 60 * gb : nil)
            }
            return (perEpisode * 2, nil)
        }
        let minimum: Int64 = switch resolution {
        case .uhd2160, .uhd4320: gb
        case .fhd1080: 150 * mb
        case .hd720: 80 * mb
        default: 40 * mb
        }
        let isCollection = parsed.isComplete || matches(name, collectionName)
        return (minimum, isCollection ? nil : 150 * gb)
    }

    // MARK: Helpers

    static func spam(in name: String, query: MediaQuery?) -> String? {
        if let hit = spamPhrases.first(where: { matches(name, $0.pattern) }) { return hit.marker }
        let asked = Set(query.map { ReleaseRelevance.words($0.title ?? $0.searchText) } ?? [])
        let words = Set(name.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init))
        return spamWords.first { words.contains($0) && !asked.contains($0) }
    }

    /// "Movie.2025.1080p.mkv.exe" → "exe"; nil when the name doesn't end in a short extension.
    static func endingExtension(_ name: String) -> String? {
        guard let match = name.firstMatch(of: /\.([A-Za-z0-9]{1,4})$/) else { return nil }
        return String(match.1).lowercased()
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func fileExtension(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }
    static func baseName(_ path: String) -> String { (path as NSString).lastPathComponent }
}
