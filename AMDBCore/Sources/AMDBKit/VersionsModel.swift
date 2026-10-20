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

    /// What to say when nothing was found.
    public var emptyHint: String {
        let advice = "Try again, turn on more sources in Settings, or use a VPN if some sites are blocked where you are."
        guard query.imdbID == nil, query.title != nil else { return advice }
        return "This title has no IMDb id yet, so sources were searched by name (\u{201C}\(query.searchText)\u{201D}). \(advice)"
    }

    /// "knaben and eztv didn't answer." when some sources failed, for screens that don't list each one.
    public var failureSummary: String? {
        let names = failures.map(\.providerID)
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "\(list) didn't answer."
    }

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
