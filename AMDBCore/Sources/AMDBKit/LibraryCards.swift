import AMDBCore

public enum LibraryFilter: String, CaseIterable, Sendable {
    case all, movies, tv, other

    func includes(_ card: LibraryCard) -> Bool {
        switch (self, card) {
        case (.all, _), (.movies, .movie), (.tv, .show), (.other, .file): true
        default: false
        }
    }
}

public enum LibraryCard: Identifiable, Sendable, Hashable {
    case movie(LibraryEntry)
    case show(tmdbID: Int, title: String, posterPath: String?, episodes: [LibraryEntry])
    case file(LibraryEntry)

    public var id: String {
        switch self {
        case let .movie(entry): "m-\(entry.id)"
        case let .show(tmdbID, _, _, _): "s-\(tmdbID)"
        case let .file(entry): "f-\(entry.id)"
        }
    }

    public static func cards(from entries: [LibraryEntry], filter: LibraryFilter) -> [LibraryCard] {
        var cards: [LibraryCard] = []
        var showIndex: [Int: Int] = [:]
        for entry in entries {
            guard let match = entry.match else {
                cards.append(.file(entry))
                continue
            }
            switch match.mediaType {
            case .movie:
                cards.append(.movie(entry))
            case .tv:
                if let index = showIndex[match.tmdbID], case let .show(id, title, poster, episodes) = cards[index] {
                    cards[index] = .show(tmdbID: id, title: title, posterPath: poster, episodes: episodes + [entry])
                } else {
                    showIndex[match.tmdbID] = cards.count
                    cards.append(.show(tmdbID: match.tmdbID, title: match.title, posterPath: match.posterPath, episodes: [entry]))
                }
            case .person:
                cards.append(.file(entry))
            }
        }
        return cards.filter(filter.includes)
    }
}
