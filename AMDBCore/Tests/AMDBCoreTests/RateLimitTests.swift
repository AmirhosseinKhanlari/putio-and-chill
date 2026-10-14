import Foundation
import Testing
@testable import AMDBCore

@Suite struct RateLimitTests {
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        func next() -> Int { lock.withLock { calls += 1; return calls } }
    }

    /// "429 Too Many Requests" waits and tries again instead of failing.
    @Test func retriesAfterTooManyRequests() async throws {
        let counter = Counter()
        let stub = StubTransport { _ in
            counter.next() <= 2 ? (429, Data()) : (200, Data(#"{"ok":true}"#.utf8))
        }
        let http = HTTPRequester(service: "tmdb", transport: stub, rateLimitBackoff: .milliseconds(1))
        let data = try await http.data(URLRequest(url: URL(string: "https://example.test")!))
        #expect(String(decoding: data, as: UTF8.self).contains("ok"))
        #expect(counter.calls == 3)
    }

    @Test func givesUpAfterThreeRetries() async {
        let counter = Counter()
        let stub = StubTransport { _ in _ = counter.next(); return (429, Data()) }
        let http = HTTPRequester(service: "tmdb", transport: stub, rateLimitBackoff: .milliseconds(1))
        await #expect(throws: AppError.http(service: "tmdb", status: 429)) {
            _ = try await http.data(URLRequest(url: URL(string: "https://example.test")!))
        }
        #expect(counter.calls == 4)
    }
}
