import Foundation
import Testing
@testable import AMDBCore

actor CallLog {
    var queries: [String] = []
    func add(_ q: String) { queries.append(q) }
}

@Suite struct LiveSearchEngineTests {
    @Test func newerQuerySupersedesOlder() async throws {
        let log = CallLog()
        let engine = LiveSearchEngine<String>(debounce: .milliseconds(200)) { q in
            await log.add(q)
            return [q]
        }
        let first = Task { try await engine.results(for: "du") }
        try await Task.sleep(for: .milliseconds(30))
        let second = try await engine.results(for: "dune")
        #expect(try await first.value == nil)
        #expect(second == ["dune"])
        #expect(await log.queries == ["dune"])
    }

    @Test func cachesByNormalizedQuery() async throws {
        let log = CallLog()
        let engine = LiveSearchEngine<String>(debounce: .zero) { q in
            await log.add(q)
            return [q]
        }
        _ = try await engine.results(for: "Dune ")
        _ = try await engine.results(for: "dune")
        #expect(await log.queries == ["Dune"])
    }

    @Test func retriesWithoutLastWord() async throws {
        let log = CallLog()
        let engine = LiveSearchEngine<String>(debounce: .zero) { q in
            await log.add(q)
            return q == "dune part" ? ["hit"] : []
        }
        let result = try await engine.results(for: "dune part twoo")
        #expect(result == ["hit"])
        #expect(await log.queries == ["dune part twoo", "dune part"])
    }

    @Test func emptyQueryReturnsEmptyWithoutSearching() async throws {
        let log = CallLog()
        let engine = LiveSearchEngine<String>(debounce: .zero) { q in await log.add(q); return [q] }
        #expect(try await engine.results(for: "   ") == [])
        #expect(await log.queries.isEmpty)
    }
}
