import AMDBCore
import Foundation

/// Episode numbers for files in a season pack, and repair of matches that only knew the season.
public enum EpisodeNumbering {
    /// The season and episode a file name carries. Inside a season pack, "01 - Pilot.mkv", "Episode 3.mkv",
    /// "E04.mkv" and "1x05.mkv" count too (the season then comes from the pack).
    public static func episode(in fileName: String) -> (season: Int?, episode: Int)? {
        let parsed = ReleaseNameParser.parse(fileName)
        if let episode = parsed.episode { return (parsed.season, episode) }
        let base = (fileName as NSString).deletingPathExtension
        if let groups = first(#"(?i)\b(\d{1,2})x(\d{1,3})\b"#, in: base), groups.count == 2 {
            return (Int(groups[0]), Int(groups[1]) ?? 0)
        }
        for pattern in [#"(?i)\bepisode[ ._-]*(\d{1,3})\b"#, #"(?i)\bep?[ ._-]?(\d{1,3})\b"#, #"^\s*(\d{1,3})\s*[-._ )]"#] {
            if let groups = first(pattern, in: base), let number = Int(groups[0]), number > 0 { return (nil, number) }
        }
        return nil
    }

    /// A TV match that knows the season but not the episode (what earlier builds saved for one file of a season
    /// pack), completed from the file name. nil when there's nothing to fix.
    public static func repaired(_ match: LibraryMatch?, fileName: String) -> LibraryMatch? {
        guard let match, match.mediaType == .tv, let season = match.season, match.episode == nil,
              let found = episode(in: fileName) else { return nil }
        return LibraryMatch(tmdbID: match.tmdbID, mediaType: .tv, season: found.season ?? season, episode: found.episode,
                            confidence: match.confidence, title: match.title, year: match.year,
                            posterPath: match.posterPath, backdropPath: match.backdropPath)
    }

    /// Every video in a finished season pack, each matched to its episode. Files without an episode number are left
    /// for the library's own matching.
    public static func packEpisodes(_ videos: [PutioFile], target: PendingTransfer) -> [(file: PutioFile, match: LibraryMatch)] {
        guard target.kind == .tv, let season = target.season else { return [] }
        return videos.compactMap { file in
            guard let found = episode(in: file.name) else { return nil }
            return (file, LibraryMatch(tmdbID: target.tmdbID, mediaType: .tv, season: found.season ?? season,
                                       episode: found.episode, confidence: 1, title: target.title,
                                       posterPath: target.posterPath, backdropPath: target.backdropPath))
        }
        .sorted { ($0.match.season ?? 0, $0.match.episode ?? 0) < ($1.match.season ?? 0, $1.match.episode ?? 0) }
    }

    private static func first(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let hit = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<hit.numberOfRanges).compactMap { Range(hit.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
