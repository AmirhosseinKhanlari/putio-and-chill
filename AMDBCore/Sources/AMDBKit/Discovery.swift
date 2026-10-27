import AMDBCore
import Foundation
import Observation

/// Watchlist, newest first, the same on every device signed in to the same iCloud: each save and removal goes into a
/// synced Keychain item (`MyListLog`), and the list is what that log says. Kept on this device too (`LocalStore`),
/// which is all there is without `synced` (demo mode, tests).
@Observable @MainActor
public final class MyList {
    public private(set) var items: [SavedTitle] = []
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let synced: (any WatchLogStore)?
    @ObservationIgnored private let now: () -> Date

    public init(store: LocalStore, synced: (any WatchLogStore)? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.synced = synced
        self.now = now
    }

    public func load() async {
        items = await store.snapshot.myList
        await sync()
    }

    public func contains(_ item: CatalogItem) -> Bool { items.contains { $0.id == SavedTitle(item).id } }

    public func toggle(_ item: CatalogItem) async {
        let saved = SavedTitle(item)
        let removing = items.contains { $0.id == saved.id }
        if removing {
            items.removeAll { $0.id == saved.id }
        } else {
            items.insert(saved, at: 0)
        }
        await save(MyListChange(title: saved, at: now(), removed: removing))
    }

    /// Reads what the other devices saved and removed (launch, the app coming back).
    public func sync() async { await save(nil) }

    /// Merges this device's list and `change` with the shared log, writes the log back if that changed it, and makes
    /// the list (here and in `LocalStore`) what the log says.
    private func save(_ change: MyListChange?) async {
        guard let synced else {
            let snapshot = items
            await store.update { $0.myList = snapshot }
            return
        }
        let stored = MyListLog.decode(synced.read(account: MyListLog.account))
        let log = MyListLog.merged(stored, MyListLog.untracked(items, in: stored) + (change.map { [$0] } ?? []), now: now())
        if log != stored, let data = MyListLog.encode(log) { synced.write(data, account: MyListLog.account) }
        items = MyListLog.titles(log)
        let snapshot = items
        await store.update { $0.myList = snapshot }
    }
}

/// One save to or removal from My List, as the user's devices tell each other about it.
public struct MyListChange: Codable, Sendable, Equatable {
    public var title: SavedTitle
    public var at: Date
    public var removed: Bool
    public init(title: SavedTitle, at: Date, removed: Bool) { self.title = title; self.at = at; self.removed = removed }
}

/// The shared My List: the newest change per title. Removals are kept for `keepRemovals`, so another device's older
/// copy of the list can't bring a removed title back.
public enum MyListLog {
    public static let account = "mylist"
    static let keepRemovals: TimeInterval = 90 * 86_400

    /// Newest change per title, newest first, without removals older than `keepRemovals`.
    public static func merged(_ a: [MyListChange], _ b: [MyListChange], now: Date) -> [MyListChange] {
        var newest: [String: MyListChange] = [:]
        for change in a + b where (newest[change.title.id]?.at ?? .distantPast) < change.at { newest[change.title.id] = change }
        return newest.values.filter { !$0.removed || now.timeIntervalSince($0.at) < keepRemovals }
            .sorted { ($0.at, $0.title.id) > ($1.at, $1.title.id) }
    }

    /// Saved titles, newest first.
    static func titles(_ log: [MyListChange]) -> [SavedTitle] { log.filter { !$0.removed }.map(\.title) }

    /// Titles on this device the log has never heard of (saved before syncing, or the item was reset): they join as
    /// saves from long ago, in their order, so any removal made since wins over them.
    static func untracked(_ items: [SavedTitle], in log: [MyListChange]) -> [MyListChange] {
        let known = Set(log.map(\.title.id))
        return items.enumerated().filter { !known.contains($0.element.id) }.map { index, title in
            MyListChange(title: title, at: Date(timeIntervalSince1970: TimeInterval(items.count - index)), removed: false)
        }
    }

    static func encode(_ log: [MyListChange]) -> Data? { try? JSONEncoder().encode(log) }
    static func decode(_ data: Data?) -> [MyListChange] {
        data.flatMap { try? JSONDecoder().decode([MyListChange].self, from: $0) } ?? []
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

/// Random well-rated pick (TMDB rating ≥ 6.5 with ≥ 500 votes) for a mood, avoiding recent repeats.
@Observable @MainActor
public final class SurpriseModel {
    /// Lowest TMDB rating a pick can have, and the votes needed for that rating to count.
    public static let minRating = 6.5
    public static let minVotes = 500

    public private(set) var pick: CatalogItem?
    /// Other good matches for the same mood, offered as "not feeling it?" options.
    public private(set) var alternatives: [CatalogItem] = []
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
        guard let first = try? await catalog.discover(kind, genreIDs: genres, minRating: Self.minRating, minVotes: Self.minVotes, page: 1) else {
            pick = nil
            isEmpty = true
            return
        }
        var items = first.items
        let page = random(1..<(min(first.totalPages, 10) + 1))
        if page > 1, let other = try? await catalog.discover(kind, genreIDs: genres, minRating: Self.minRating, minVotes: Self.minVotes, page: page),
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
        alternatives = sample(candidates.filter { $0.id != chosen.id && $0.backdropPath != nil }, count: 6)
        isEmpty = false
    }

    /// Swaps in one of the alternatives; the current pick takes its place in the list.
    public func choose(_ item: CatalogItem) {
        guard let current = pick, item.id != current.id, let index = alternatives.firstIndex(where: { $0.id == item.id }) else { return }
        alternatives[index] = current
        recent = Array((recent + [item.id]).suffix(20))
        pick = item
    }

    private func sample(_ items: [CatalogItem], count: Int) -> [CatalogItem] {
        var pool = items
        var result: [CatalogItem] = []
        while result.count < count, !pool.isEmpty {
            result.append(pool.remove(at: random(0..<pool.count)))
        }
        return result
    }
}
