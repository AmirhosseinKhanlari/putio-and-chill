import Foundation

public protocol SourceProvider: Sendable {
    var id: String { get }
    func releases(for query: MediaQuery) async throws -> [Release]
}

public enum ReleaseRelevance {
    /// Filters free-text search hits down to what the query actually asked for.
    public static func matches(_ p: ParsedRelease, _ query: MediaQuery) -> Bool {
        switch query {
        case let .episode(_, title, season, episode):
            guard p.season == season, let first = p.episode, sameShow(p.title, title) else { return false }
            return first == episode || (p.episodeEnd.map { episode >= first && episode <= $0 } ?? false)
        case let .season(_, title, season):
            return p.season == season && p.episode == nil && sameShow(p.title, title)
        case let .movie(_, title, year):
            guard p.season == nil, sameMovie(p.title, title) else { return false }
            if let year, let found = p.year { return abs(found - year) <= 1 }
            return true
        case .text:
            return true
        }
    }

    /// Whether a release's title names the show asked for. A text search for "Monster The Ed Gein Story S01E01" also
    /// finds other shows' S01E01, so the words have to agree: punctuation, case, accents and a leading "The" / "A" don't
    /// count, and one extra word after the title is allowed when it's a country or a year ("The Office US",
    /// "Doctor Who 2005"). An empty title on either side can't be checked and passes.
    public static func sameShow(_ releaseTitle: String, _ showTitle: String) -> Bool {
        let wanted = words(showTitle), found = words(withoutSitePrefix(releaseTitle))
        guard !wanted.isEmpty, !found.isEmpty else { return true }
        if found.joined() == wanted.joined() { return true }
        guard found.count == wanted.count + 1, Array(found.prefix(wanted.count)) == wanted, let extra = found.last else {
            return false
        }
        let isYear = extra.count == 4 && Int(extra).map { (1900...2100).contains($0) } == true
        return isYear || (extra.count == 2 && extra.allSatisfy(\.isLetter))
    }

    /// Whether a release's title names the movie asked for: the same words, the words before the title's colon
    /// ("Glass Onion" for "Glass Onion: A Knives Out Mystery"), or the title's words with more after them ("Dune Part
    /// One" for "Dune"). Search sites also return look-alikes ("Wellwood" for "Wildwood"); those don't count. Sequels
    /// with the same name are told apart by the year. An empty title on either side can't be checked and passes.
    public static func sameMovie(_ releaseTitle: String, _ movieTitle: String) -> Bool {
        let wanted = words(movieTitle), found = words(withoutSitePrefix(releaseTitle))
        guard !wanted.isEmpty, !found.isEmpty else { return true }
        if found.joined() == wanted.joined() || found.starts(with: wanted) { return true }
        guard let main = movieTitle.split(separator: ":").first, main.count < movieTitle.count else { return false }
        return found.joined() == words(String(main)).joined()
    }

    /// "www.UIndex.org - Severance" → "Severance": some uploads lead with the site they came from.
    static func withoutSitePrefix(_ title: String) -> String {
        title.replacingOccurrences(of: #"^\s*(?:www\.)?[A-Za-z0-9-]+\.(?:org|com|net|to|io|me|cc|tv|xyz|se)\s*[-–]+\s*"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Lowercased words without accents or punctuation, "&" as "and", apostrophes joined, a leading article dropped.
    static func words(_ title: String) -> [String] {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
            .replacingOccurrences(of: #"['’]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: " and ")
        var words = folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        if words.count > 1, ["the", "a", "an"].contains(words[0]) { words.removeFirst() }
        return words
    }
}
