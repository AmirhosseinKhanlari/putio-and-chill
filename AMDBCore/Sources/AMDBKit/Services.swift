import AMDBCore
import Foundation

public protocol PutioService: Sendable {
    func accountInfo() async throws -> PutioAccount
    func addTransfer(url: String, saveParentID: Int64?) async throws -> PutioTransfer
    func transfer(id: Int64) async throws -> PutioTransfer
    func transfers() async throws -> [PutioTransfer]
    func cancelTransfers(ids: [Int64]) async throws
    func retryTransfer(id: Int64) async throws -> PutioTransfer
    func listFiles(parentID: Int64) async throws -> PutioFileList
    func file(id: Int64) async throws -> PutioFile
    func createFolder(name: String, parentID: Int64) async throws -> PutioFile
    func deleteFiles(ids: [Int64]) async throws
    func moveFiles(ids: [Int64], to parentID: Int64) async throws
    func startFrom(fileID: Int64) async throws -> Int
    func setStartFrom(fileID: Int64, seconds: Int) async throws
    func hlsURL(fileID: Int64, subtitles: Bool) -> URL
    func originalURL(fileID: Int64) async throws -> URL
    func subtitles(fileID: Int64) async throws -> [PutioSubtitle]
    func subtitleText(fileID: Int64, key: String) async throws -> String
}

extension PutioService {
    public func hlsURL(fileID: Int64) -> URL { hlsURL(fileID: fileID, subtitles: true) }
}

extension PutioClient: PutioService {}

public protocol CatalogService: CatalogSearching {
    func validate() async throws
    func searchMulti(_ query: String) async throws -> [CatalogItem]
    func searchMulti(_ query: String, page: Int) async throws -> CatalogPage
    func trending(_ kind: MediaKind?) async throws -> [CatalogItem]
    func popular(_ kind: MediaKind) async throws -> [CatalogItem]
    func topRated(_ kind: MediaKind) async throws -> [CatalogItem]
    func discover(_ kind: MediaKind, genreID: Int) async throws -> [CatalogItem]
    func detail(_ kind: MediaKind, id: Int) async throws -> TitleDetail
    func season(tvID: Int, number: Int) async throws -> [Episode]
    func item(_ kind: MediaKind, id: Int) async throws -> CatalogItem
    func person(id: Int) async throws -> PersonDetail
    func collection(id: Int) async throws -> CollectionDetail
    func discover(_ kind: MediaKind, genreIDs: [Int], minRating: Double, minVotes: Int, page: Int) async throws -> CatalogPage
    func findByIMDb(_ imdbID: String) async throws -> CatalogItem?
}

extension CatalogClient: CatalogService {}

extension CatalogService {
    /// TMDB title for an IMDb id; services that can't look one up return nil (callers fall back to search).
    public func findByIMDb(_ imdbID: String) async throws -> CatalogItem? { nil }
}

public protocol ReleaseSearching: Sendable {
    func stream(for query: MediaQuery) -> AsyncStream<ReleaseSnapshot>
}

extension ReleaseAggregator: ReleaseSearching {}

public protocol RatingsService: Sendable {
    func ratings(imdbID: String, kind: MediaKind) async throws -> Ratings
    func validate() async throws
}

extension RatingsClient: RatingsService {}

public protocol ChartsService: Sendable {
    func chart(_ chart: IMDbChart) async throws -> [ChartEntry]
}

extension TraktClient: ChartsService {}

public protocol TrailerService: Sendable {
    func trailer(imdbID: String) async throws -> TrailerVideo?
}

extension IMDbTrailerClient: TrailerService {}

public protocol EpisodeRatingsService: Sendable {
    func ratings(seriesIMDbID: String, season: Int) async throws -> [Int: EpisodeRating]
}

extension IMDbEpisodeRatingsClient: EpisodeRatingsService {}
