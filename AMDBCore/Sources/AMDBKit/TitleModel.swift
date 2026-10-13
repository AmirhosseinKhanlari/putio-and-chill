import AMDBCore
import Foundation
import Observation

public enum TitleAction: Equatable, Sendable {
    case get
    case play(LibraryEntry)
    case resume(LibraryEntry, seconds: Int)
    case downloading(TrackedTransfer)
    case failed(TrackedTransfer)
}

@Observable @MainActor
public final class TitleModel {
    public let item: CatalogItem
    public private(set) var detail: TitleDetail?
    public private(set) var episodes: [Episode] = []
    public private(set) var selectedSeason: Int?
    public private(set) var error: AppError?

    private let catalog: any CatalogService
    private let library: LibraryIndex
    private let transfers: TransferMonitor

    public init(item: CatalogItem, catalog: any CatalogService, library: LibraryIndex, transfers: TransferMonitor) {
        self.item = item
        self.catalog = catalog
        self.library = library
        self.transfers = transfers
    }

    public func load() async {
        do {
            let loaded = try await catalog.detail(item.mediaType, id: item.tmdbID)
            detail = loaded
            error = nil
            if item.mediaType == .tv, let first = loaded.seasons.first?.number {
                await selectSeason(first)
            }
        } catch let failure as AppError {
            error = failure
        } catch {
            self.error = .transport(error.localizedDescription)
        }
    }

    public func selectSeason(_ number: Int) async {
        selectedSeason = number
        episodes = (try? await catalog.season(tvID: item.tmdbID, number: number)) ?? []
    }

    public func action(season: Int? = nil, episode: Int? = nil) -> TitleAction {
        if let transfer = transfers.latest(tmdbID: item.tmdbID, season: season, episode: episode) {
            switch transfer.phase {
            case .failed: return .failed(transfer)
            case .completed where transfer.playableFile != nil: break
            default: return .downloading(transfer)
            }
        }
        let hits = library.matching(tmdbID: item.tmdbID, season: season, episode: episode)
        guard let best = hits.max(by: { library.resumeSeconds(for: $0) < library.resumeSeconds(for: $1) }) else { return .get }
        let seconds = library.resumeSeconds(for: best)
        return seconds >= 30 ? .resume(best, seconds: seconds) : .play(best)
    }

    public func query(season: Int? = nil, episode: Int? = nil) -> MediaQuery? {
        guard let detail, let imdbID = detail.imdbID else { return nil }
        let title = detail.item.title
        switch (item.mediaType, season, episode) {
        case (.tv, let season?, let episode?): return .episode(imdbID: imdbID, title: title, season: season, episode: episode)
        case (.tv, let season?, nil): return .season(imdbID: imdbID, title: title, season: season)
        case (.movie, _, _): return .movie(imdbID: imdbID, title: title, year: detail.item.year)
        default: return nil
        }
    }

    public func target(season: Int? = nil, episode: Int? = nil) -> TransferTarget {
        TransferTarget(tmdbID: item.tmdbID, kind: item.mediaType, title: detail?.item.title ?? item.title,
                       posterPath: item.posterPath, backdropPath: item.backdropPath, season: season, episode: episode)
    }
}
