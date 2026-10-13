import Foundation

public struct ProviderFailure: Sendable, Equatable {
    public let providerID: String
    public let error: AppError
    public init(providerID: String, error: AppError) { self.providerID = providerID; self.error = error }
}

public struct ReleaseSnapshot: Sendable, Equatable {
    public var releases: [Release] = []
    public var failures: [ProviderFailure] = []
    public var pendingProviders: Set<String> = []
    public var isComplete: Bool { pendingProviders.isEmpty }
    public init() {}
}

public struct ReleaseAggregator: Sendable {
    private let providers: [any SourceProvider]
    private let timeout: Duration

    public init(providers: [any SourceProvider], timeout: Duration = .seconds(12)) {
        self.providers = providers
        self.timeout = timeout
    }

    public func stream(for query: MediaQuery) -> AsyncStream<ReleaseSnapshot> {
        let providers = providers
        let timeout = timeout
        return AsyncStream { continuation in
            let task = Task {
                var snapshot = ReleaseSnapshot()
                snapshot.pendingProviders = Set(providers.map(\.id))
                continuation.yield(snapshot)
                await withTaskGroup(of: (String, Result<[Release], AppError>).self) { group in
                    for provider in providers {
                        group.addTask { (provider.id, await Self.run(provider, query, timeout)) }
                    }
                    for await (id, result) in group {
                        snapshot.pendingProviders.remove(id)
                        switch result {
                        case let .success(rows): snapshot.releases = Self.merge(snapshot.releases, rows)
                        case let .failure(error): snapshot.failures.append(ProviderFailure(providerID: id, error: error))
                        }
                        continuation.yield(snapshot)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
