import Foundation
import Testing
@testable import AMDBCore

struct FakeProvider: SourceProvider {
    let id: String
    var result: Result<[Release], AppError>
    var delay: Duration = .zero

    func releases(for query: MediaQuery) async throws -> [Release] {
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

func release(_ hash: Character, seeders: Int?, size: Int64? = nil, tag: SourceTag, name: String = "X.2024.1080p", link: String? = nil) -> Release {
    let h = String(repeating: hash, count: 40)
    return Release(name: name, link: link ?? "magnet:?xt=urn:btih:\(h)", sizeBytes: size, seeders: seeders, sources: [tag])
}

@Suite struct ReleaseAggregatorTests {
    let yts = SourceTag(.direct, "YTS")
    let knaben = SourceTag(.direct, "Knaben")
    let tpb = SourceTag(.direct, "TPB")

    @Test func mergeUnionsTagsAndKeepsMaxSeeders() {
        let merged = ReleaseAggregator.merge(
            [release("a", seeders: 10, tag: yts)],
            [release("a", seeders: 50, size: 99, tag: knaben), release("b", seeders: 1, tag: tpb)])
        #expect(merged.count == 2)
        #expect(merged[0].sources == [yts, knaben])
        #expect(merged[0].seeders == 50)
        #expect(merged[0].sizeBytes == 99)
    }

    @Test func mergePrefersMagnetLink() {
        let torrent = Release(name: "N", link: "https://x/t.torrent", infoHash: String(repeating: "c", count: 40), sources: [tpb])
        let merged = ReleaseAggregator.merge([torrent], [release("c", seeders: 1, tag: yts)])
        #expect(merged[0].link.hasPrefix("magnet:"))
    }

    @Test func collectsResultsAndFailures() async {
        let aggregator = ReleaseAggregator(providers: [
            FakeProvider(id: "yts", result: .success([release("a", seeders: 5, tag: yts)])),
            FakeProvider(id: "eztv", result: .failure(.http(service: "eztv", status: 503))),
        ])
        let snapshot = await aggregator.collect(for: .text("x"))
        #expect(snapshot.isComplete)
        #expect(snapshot.releases.count == 1)
        #expect(snapshot.failures == [ProviderFailure(providerID: "eztv", error: .http(service: "eztv", status: 503))])
    }

    @Test func slowProviderTimesOut() async {
        let aggregator = ReleaseAggregator(providers: [
            FakeProvider(id: "slow", result: .success([]), delay: .seconds(5)),
        ], timeout: .milliseconds(50))
        let snapshot = await aggregator.collect(for: .text("x"))
        #expect(snapshot.failures == [ProviderFailure(providerID: "slow", error: .timeout(service: "slow"))])
    }

    @Test func streamYieldsInitialPendingSnapshot() async {
        let aggregator = ReleaseAggregator(providers: [FakeProvider(id: "yts", result: .success([]))])
        var snapshots: [ReleaseSnapshot] = []
        for await s in aggregator.stream(for: .text("x")) { snapshots.append(s) }
        #expect(snapshots.first?.pendingProviders == ["yts"])
        #expect(snapshots.last?.isComplete == true)
    }

    @Test func sortingAndFiltering() {
        var a = release("a", seeders: 5, size: 300, tag: yts, name: "A.2024.2160p")
        var b = release("b", seeders: 50, size: 100, tag: yts, name: "B.2024.720p")
        let c = release("c", seeders: 20, size: 200, tag: yts, name: "C.2024.1080p")
        a.parsed.resolution = .uhd2160
        b.parsed.resolution = .hd720
        let rows = [a, b, c]
        #expect(rows.sorted(by: .seeders).map(\.name) == ["B.2024.720p", "C.2024.1080p", "A.2024.2160p"])
        #expect(rows.sorted(by: .size).map(\.name) == ["A.2024.2160p", "C.2024.1080p", "B.2024.720p"])
        #expect(rows.sorted(by: .quality).map(\.name) == ["A.2024.2160p", "C.2024.1080p", "B.2024.720p"])
        #expect(rows.filtered(resolution: .fhd1080).map(\.name) == ["C.2024.1080p"])
        #expect(rows.filtered(resolution: nil).count == 3)
    }
}
