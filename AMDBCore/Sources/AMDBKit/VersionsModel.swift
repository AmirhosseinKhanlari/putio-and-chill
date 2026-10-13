import AMDBCore
import Foundation
import Observation

@Observable @MainActor
public final class VersionsModel {
    public let query: MediaQuery
    public let playNow: [LibraryEntry]
    public private(set) var snapshot = ReleaseSnapshot()
    public private(set) var isLoading = false
    public var resolution: Resolution?
    public var sort: ReleaseSort = .seeders

    @ObservationIgnored private let searcher: any ReleaseSearching
    @ObservationIgnored private let completedHashes: Set<String>
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(query: MediaQuery, searcher: any ReleaseSearching, playNow: [LibraryEntry],
                completedHashes: Set<String>, defaultResolution: Resolution?) {
        self.query = query
        self.searcher = searcher
        self.playNow = playNow
        self.completedHashes = completedHashes
        self.resolution = defaultResolution
    }

    public var rows: [Release] { snapshot.releases.filtered(resolution: resolution).sorted(by: sort) }
    public var failures: [ProviderFailure] { snapshot.failures }

    public var availableResolutions: [Resolution] {
        Set(snapshot.releases.map(\.parsed.resolution)).filter { $0 != .unknown }.sorted(by: >)
    }

    public func isInPutio(_ release: Release) -> Bool {
        release.infoHash.map(completedHashes.contains) ?? false
    }

    public func start() {
        task?.cancel()
        snapshot = ReleaseSnapshot()
        isLoading = true
        let stream = searcher.stream(for: query)
        task = Task {
            for await next in stream {
                snapshot = next
                isLoading = !next.isComplete
            }
            isLoading = false
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        isLoading = false
    }
}
