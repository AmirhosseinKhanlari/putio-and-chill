import Foundation
import OSLog

public struct ProviderFailure: Sendable, Equatable {
    public let providerID: String
    public let error: AppError
    public init(providerID: String, error: AppError) { self.providerID = providerID; self.error = error }
}

public struct ReleaseSnapshot: Sendable, Equatable {
    public var releases: [Release] = []
    public var failures: [ProviderFailure] = []
    public var pendingProviders: Set<String> = []
    /// Every source answered and the file lists of the top releases are being read.
    public var isCheckingFiles = false
    /// How many releases were left out because they look fake.
    public var hiddenCount = 0
    public var isComplete: Bool { pendingProviders.isEmpty && !isCheckingFiles }
    public init() {}
}

/// Asks every source at once and merges what they find. Releases that look fake never come out of it: their names
/// and sizes are checked as they arrive (`ReleaseSafety`), releases downloaded before and found fake (`blocked`, by
/// info-hash or link) are dropped, and once every source has answered the file lists of the top releases are read
/// (`inspector`) before the search counts as complete.
public struct ReleaseAggregator: Sendable {
    private let providers: [any SourceProvider]
    private let timeout: Duration
    private let inspector: FileListInspector?
    private let blocked: @Sendable () async -> Set<String>

    static let log = Logger(subsystem: "app.amdb", category: "release-safety")

    public init(providers: [any SourceProvider], timeout: Duration = .seconds(12), inspector: FileListInspector? = nil,
                blocked: @escaping @Sendable () async -> Set<String> = { [] }) {
        self.providers = providers
        self.timeout = timeout
        self.inspector = inspector
        self.blocked = blocked
    }

    public func stream(for query: MediaQuery) -> AsyncStream<ReleaseSnapshot> {
        let providers = providers
        let timeout = timeout
        let inspector = inspector
        let blocked = blocked
        return AsyncStream { continuation in
            let task = Task {
                var snapshot = ReleaseSnapshot()
                snapshot.pendingProviders = Set(providers.map(\.id))
                continuation.yield(snapshot)
                let known = await blocked()
                await withTaskGroup(of: (String, Result<[Release], AppError>).self) { group in
                    for provider in providers {
                        group.addTask { (provider.id, await Self.run(provider, query, timeout)) }
                    }
                    for await (id, result) in group {
                        snapshot.pendingProviders.remove(id)
                        switch result {
                        case let .success(rows):
                            let kept = Self.screen(rows, query: query, blocked: known)
                            snapshot.hiddenCount += rows.count - kept.count
                            snapshot.releases = Self.merge(snapshot.releases, kept)
                        case let .failure(error): snapshot.failures.append(ProviderFailure(providerID: id, error: error))
                        }
                        // Held back for the file check when this was the last source.
                        snapshot.isCheckingFiles = snapshot.pendingProviders.isEmpty && inspector != nil
                        if !snapshot.isCheckingFiles { continuation.yield(snapshot) }
                    }
                }
                if let inspector, snapshot.isCheckingFiles {
                    continuation.yield(snapshot)
                    let rejected = await inspector.rejections(FileListInspector.candidates(snapshot.releases))
                    for (id, reason) in rejected {
                        Self.logRejection(snapshot.releases.first { $0.id == id }?.name ?? id, reason)
                    }
                    snapshot.releases.removeAll { rejected[$0.id] != nil }
                    snapshot.hiddenCount += rejected.count
                    snapshot.isCheckingFiles = false
                    continuation.yield(snapshot)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The rows that don't look fake by name or size and weren't found fake before.
    static func screen(_ rows: [Release], query: MediaQuery, blocked: Set<String>) -> [Release] {
        rows.filter { row in
            let reason: ReleaseRejection? = if Self.isBlocked(row, blocked) { .knownBad } else { ReleaseSafety.rejection(row, query: query) }
            guard let reason else { return true }
            logRejection(row.name, reason)
            return false
        }
    }

    /// Whether `release` is one of `blocked` (lowercased info-hashes and links).
    public static func isBlocked(_ release: Release, _ blocked: Set<String>) -> Bool {
        guard !blocked.isEmpty else { return false }
        return release.infoHash.map { blocked.contains($0.lowercased()) } == true || blocked.contains(release.link.lowercased())
    }

    static func logRejection(_ name: String, _ reason: ReleaseRejection) {
        #if DEBUG
        log.debug("Hid \(name, privacy: .public): \(reason.description, privacy: .public)")
        #endif
    }

    public func collect(for query: MediaQuery) async -> ReleaseSnapshot {
        var last = ReleaseSnapshot()
        for await snapshot in stream(for: query) { last = snapshot }
        return last
    }

    static func run(_ provider: any SourceProvider, _ query: MediaQuery, _ timeout: Duration) async -> Result<[Release], AppError> {
        do {
            let rows = try await withThrowingTaskGroup(of: [Release].self) { group in
                group.addTask { try await provider.releases(for: query) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw AppError.timeout(service: provider.id)
                }
                defer { group.cancelAll() }
                return try await group.next() ?? []
            }
            return .success(rows)
        } catch let error as AppError {
            return .failure(error)
        } catch {
            return .failure(.transport("\(provider.id): \(error.localizedDescription)"))
        }
    }

    public static func merge(_ existing: [Release], _ incoming: [Release]) -> [Release] {
        var order: [String] = []
        var byID: [String: Release] = [:]
        for row in existing + incoming {
            guard var current = byID[row.id] else {
                order.append(row.id)
                byID[row.id] = row
                continue
            }
            current.sources.formUnion(row.sources)
            if let seeders = row.seeders { current.seeders = max(current.seeders ?? 0, seeders) }
            if current.sizeBytes == nil { current.sizeBytes = row.sizeBytes }
            if !current.link.hasPrefix("magnet:"), row.link.hasPrefix("magnet:") { current.link = row.link }
            if current.files == nil { current.files = row.files }
            if current.fileListURL == nil { current.fileListURL = row.fileListURL }
            byID[row.id] = current
        }
        return order.compactMap { byID[$0] }
    }
}

public enum ReleaseSort: String, Sendable, CaseIterable { case seeders, size, quality }

extension Array where Element == Release {
    public func sorted(by sort: ReleaseSort) -> [Release] {
        switch sort {
        case .seeders:
            sorted { ($0.seeders ?? -1, $0.parsed.resolution) > ($1.seeders ?? -1, $1.parsed.resolution) }
        case .size:
            sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
        case .quality:
            sorted { ($0.parsed.resolution, $0.seeders ?? -1) > ($1.parsed.resolution, $1.seeders ?? -1) }
        }
    }

    public func filtered(resolution: Resolution?) -> [Release] {
        guard let resolution else { return self }
        return filter { $0.parsed.resolution == resolution }
    }
}
