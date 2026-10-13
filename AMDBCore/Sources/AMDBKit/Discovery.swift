import AMDBCore
import Foundation
import Observation

/// Local watchlist, newest first.
@Observable @MainActor
public final class MyList {
    public private(set) var items: [SavedTitle] = []
    @ObservationIgnored private let store: LocalStore

    public init(store: LocalStore) { self.store = store }

    public func load() async { items = await store.snapshot.myList }

    public func contains(_ item: CatalogItem) -> Bool { items.contains { $0.id == SavedTitle(item).id } }

    public func toggle(_ item: CatalogItem) async {
        let saved = SavedTitle(item)
        if let index = items.firstIndex(where: { $0.id == saved.id }) {
            items.remove(at: index)
        } else {
            items.insert(saved, at: 0)
        }
        let snapshot = items
        await store.update { $0.myList = snapshot }
    }
}

public enum Mood: String, CaseIterable, Sendable, Identifiable {
    case anything, laugh, thrill, feelGood, mindBending, cry, scare

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .anything: "Anything"
        case .laugh: "Laugh"
        case .thrill: "Thrill"
        case .feelGood: "Feel good"
        case .mindBending: "Mind-bending"
        case .cry: "Cry"
        case .scare: "Scare me"
        }
    }

    public var emoji: String {
        switch self {
        case .anything: "🎲"
        case .laugh: "😂"
        case .thrill: "⚡️"
        case .feelGood: "🥰"
        case .mindBending: "🌀"
        case .cry: "😢"
        case .scare: "👻"
        }
    }

    /// TMDB genre ids (OR-ed); movie and TV genre lists differ.
    public func genreIDs(for kind: MediaKind) -> [Int] {
        switch (self, kind) {
        case (.anything, _): []
        case (.laugh, _): [35]
        case (.thrill, .tv): [10759, 80]
        case (.thrill, _): [53, 28]
        case (.feelGood, .tv): [10751, 16]
        case (.feelGood, _): [10751, 10749, 16]
        case (.mindBending, .tv): [10765, 9648]
        case (.mindBending, _): [878, 9648]
        case (.cry, _): [18]
        case (.scare, .tv): [9648]
        case (.scare, _): [27]
        }
    }
}

/// Random well-rated pick (TMDB rating ≥ 7 with ≥ 500 votes) for a mood, avoiding recent repeats.
@Observable @MainActor
public final class SurpriseModel {
    public private(set) var pick: CatalogItem?
    public private(set) var isRolling = false
    public private(set) var isEmpty = false

    @ObservationIgnored private let catalog: any CatalogService
    @ObservationIgnored private let random: (Range<Int>) -> Int
    @ObservationIgnored private var recent: [String] = []

    public init(catalog: any CatalogService, random: @escaping (Range<Int>) -> Int = { Int.random(in: $0) }) {
        self.catalog = catalog
        self.random = random
    }

    public func roll(kind: MediaKind, mood: Mood) async {
        isRolling = true
        defer { isRolling = false }
        let genres = mood.genreIDs(for: kind)
        guard let first = try? await catalog.discover(kind, genreIDs: genres, minRating: 7, minVotes: 500, page: 1) else {
            pick = nil
            isEmpty = true
            return
        }
        var items = first.items
        let page = random(1..<(min(first.totalPages, 10) + 1))
        if page > 1, let other = try? await catalog.discover(kind, genreIDs: genres, minRating: 7, minVotes: 500, page: page),
           !other.items.isEmpty {
            items = other.items
        }
        let fresh = items.filter { !recent.contains($0.id) }
        let candidates = fresh.isEmpty ? items : fresh
        guard !candidates.isEmpty else {
            pick = nil
            isEmpty = true
            return
        }
        let chosen = candidates[random(0..<candidates.count)]
        recent = Array((recent + [chosen.id]).suffix(20))
        pick = chosen
        isEmpty = false
    }
}
