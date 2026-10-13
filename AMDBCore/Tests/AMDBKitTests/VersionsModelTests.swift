import AMDBCore
import Testing
@testable import AMDBKit

@MainActor @Suite struct VersionsModelTests {
    static let releases = [
        makeRelease("a", seeders: 5, name: "X.2024.2160p.WEB"),
        makeRelease("b", seeders: 50, name: "X.2024.720p.WEB"),
        makeRelease("c", seeders: 20, name: "X.2024.1080p.WEB"),
    ]

    static func searcher() -> FakeSearcher {
        var pending = ReleaseSnapshot()
        pending.pendingProviders = ["yts", "tpb"]
        var done = ReleaseSnapshot()
        done.releases = releases
        done.failures = [ProviderFailure(providerID: "yts", error: .timeout(service: "yts"))]
        return FakeSearcher(snapshots: [pending, done])
    }

    @Test func streamsUntilComplete() async throws {
        let model = VersionsModel(query: .text("x"), searcher: Self.searcher(), playNow: [], completedHashes: [], defaultResolution: nil)
        model.start()
        #expect(model.isLoading)
        try await waitUntil { !model.isLoading }
        #expect(model.rows.map(\.name) == ["X.2024.720p.WEB", "X.2024.1080p.WEB", "X.2024.2160p.WEB"])
        #expect(model.failures.map(\.providerID) == ["yts"])
        #expect(model.availableResolutions == [.uhd2160, .fhd1080, .hd720])
    }

    @Test func filterAndSort() async throws {
        let model = VersionsModel(query: .text("x"), searcher: Self.searcher(), playNow: [], completedHashes: [], defaultResolution: .fhd1080)
        model.start()
        try await waitUntil { !model.isLoading }
        #expect(model.rows.map(\.name) == ["X.2024.1080p.WEB"])
        model.resolution = nil
        model.sort = .quality
        #expect(model.rows.first?.name == "X.2024.2160p.WEB")
    }

    @Test func flagsReleasesAlreadyInPutio() {
        let model = VersionsModel(query: .text("x"), searcher: Self.searcher(), playNow: [],
                                  completedHashes: [String(repeating: "c", count: 40)], defaultResolution: nil)
        #expect(model.isInPutio(Self.releases[2]))
        #expect(!model.isInPutio(Self.releases[0]))
    }
}
