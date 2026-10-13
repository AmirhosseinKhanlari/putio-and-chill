import AMDBCore
import Foundation
import Observation

/// A ranked IMDb chart whose TMDB artwork is resolved lazily, title by title.
@Observable @MainActor
public final class ChartModel {
    public let chart: IMDbChart
    public private(set) var entries: [ChartEntry] = []
    public private(set) var items: [String: CatalogItem] = [:]
    public private(set) var isLoading = false
    public private(set) var error: AppError?

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let catalog: any CatalogService
    @ObservationIgnored private var inFlight: Set<String> = []

    public init(chart: IMDbChart, app: AppModel, catalog: any CatalogService) {
        self.chart = chart
        self.app = app
        self.catalog = catalog
    }

    public func load() async {
        guard entries.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await app.chart(chart)
            error = nil
        } catch let failure as AppError {
            error = failure
        } catch {
            self.error = .transport(error.localizedDescription)
        }
    }

    /// TMDB item for an entry (poster, backdrop), cached; nil when the entry has no TMDB id.
    @discardableResult
    public func item(for entry: ChartEntry) async -> CatalogItem? {
        if let cached = items[entry.id] { return cached }
        guard let tmdbID = entry.tmdbID, !inFlight.contains(entry.id) else { return nil }
        inFlight.insert(entry.id)
        defer { inFlight.remove(entry.id) }
        guard let found = try? await catalog.item(entry.kind, id: tmdbID) else { return nil }
        items[entry.id] = found
        return found
    }
}
