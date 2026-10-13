import AMDBCore
import Foundation
import Observation

@Observable @MainActor
public final class SearchModel {
    public var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    public private(set) var results: [CatalogItem] = []
    public private(set) var isSearching = false
    public private(set) var recent: [String] = []

    @ObservationIgnored private let engine: LiveSearchEngine<CatalogItem>
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(catalog: any CatalogService, store: LocalStore, debounce: Duration = .milliseconds(250)) {
        self.store = store
        engine = LiveSearchEngine(debounce: debounce) { query in try await catalog.searchMulti(query) }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var suggestions: [CatalogItem] { Array(results.filter { $0.mediaType != .person }.prefix(6)) }

    public var grid: [CatalogItem] {
        var seen = Set<String>()
        var items: [CatalogItem] = []
        for item in results {
            let expanded = item.mediaType == .person ? item.knownFor.filter { $0.mediaType != .person } : [item]
            for candidate in expanded where seen.insert(candidate.id).inserted { items.append(candidate) }
        }
        return items
    }

    public var releaseQuery: MediaQuery? { trimmed.isEmpty ? nil : .text(trimmed) }

    public func loadRecent() async { recent = await store.snapshot.recentSearches }

    public func commit() async {
        await store.addRecentSearch(trimmed)
        await loadRecent()
    }

    private func schedule() {
        task?.cancel()
        let text = trimmed
        guard !text.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let engine = engine
        task = Task {
            guard let found = try? await engine.results(for: text), !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}
