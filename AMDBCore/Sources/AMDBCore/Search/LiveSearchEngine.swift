import Foundation

/// Debounced, cancel-on-newer search with per-query caching and a one-word-shorter retry.
public actor LiveSearchEngine<Item: Sendable> {
    private let debounce: Duration
    private let search: @Sendable (String) async throws -> [Item]
    private var generation = 0
    private var cache: [String: [Item]] = [:]

    public init(debounce: Duration = .milliseconds(250), search: @escaping @Sendable (String) async throws -> [Item]) {
        self.debounce = debounce
        self.search = search
    }

    /// Returns nil when a newer call superseded this one.
    public func results(for raw: String) async throws -> [Item]? {
        generation += 1
        let mine = generation
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = query.lowercased()
        guard !query.isEmpty else { return [] }
        if let hit = cache[key] { return hit }

        if debounce > .zero { try await Task.sleep(for: debounce) }
        guard mine == generation else { return nil }

        var items = try await search(query)
        guard mine == generation else { return nil }
        if items.isEmpty, let shorter = Self.dropLastWord(query) {
            items = try await search(shorter)
            guard mine == generation else { return nil }
        }
        cache[key] = items
        return items
    }

    static func dropLastWord(_ text: String) -> String? {
        let words = text.split(separator: " ")
        guard words.count > 1 else { return nil }
        return words.dropLast().joined(separator: " ")
    }
}
