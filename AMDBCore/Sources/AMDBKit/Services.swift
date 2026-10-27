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
    func renameFile(id: Int64, name: String) async throws
    func fileStatus(id: Int64) async throws -> PutioFile
    func mp4Status(fileID: Int64) async throws -> PutioMp4Status
    func mediaInfo(fileID: Int64) async throws -> PutioMediaInfo
    func convertToMp4(fileID: Int64) async throws -> PutioMp4Status
    func copyFile(id: Int64, to parentID: Int64) async throws -> PutioFile
    func searchFiles(_ query: String) async throws -> [PutioFile]
    func trash() async throws -> PutioTrash
    func restoreFromTrash(ids: [Int64]) async throws
    func deleteFromTrash(ids: [Int64]) async throws
    func emptyTrash() async throws
    func startFrom(fileID: Int64) async throws -> Int
    func setStartFrom(fileID: Int64, seconds: Int) async throws
    func resetStartFrom(fileID: Int64) async throws
    func hlsURL(fileID: Int64, subtitles: Bool) -> URL
    /// The stream carrying one put.io subtitle track (AirPlay: the TV draws it).
    func hlsURL(fileID: Int64, subtitleKey: String) -> URL
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
    func discover(_ kind: MediaKind, query: DiscoverQuery) async throws -> [CatalogItem]
    func nowPlaying(region: String) async throws -> [CatalogItem]
    func upcomingMovies(region: String) async throws -> [DatedItem]
    func discoverDated(_ kind: MediaKind, query: DiscoverQuery) async throws -> [DatedItem]
    func nextEpisode(tvID: Int) async throws -> UpcomingEpisode?
    func keywordIDs(_ query: String) async throws -> [Int]
}

extension CatalogClient: CatalogService {}

extension CatalogService {
    /// TMDB title for an IMDb id; services that can't look one up return nil (callers fall back to search).
    public func findByIMDb(_ imdbID: String) async throws -> CatalogItem? { nil }
    /// Services without filtered discovery (fakes, demo) fall back to popular titles.
    public func discover(_ kind: MediaKind, query: DiscoverQuery) async throws -> [CatalogItem] { try await popular(kind) }
    public func nowPlaying(region: String) async throws -> [CatalogItem] { try await popular(.movie) }
    public func upcomingMovies(region: String) async throws -> [DatedItem] {
        try await popular(.movie).map { DatedItem(item: $0, date: nil) }
    }
    public func discoverDated(_ kind: MediaKind, query: DiscoverQuery) async throws -> [DatedItem] {
        try await discover(kind, query: query).map { DatedItem(item: $0, date: nil) }
    }
    public func nextEpisode(tvID: Int) async throws -> UpcomingEpisode? { nil }
    public func keywordIDs(_ query: String) async throws -> [Int] { [] }
}

public protocol ReleaseSearching: Sendable {
    func stream(for query: MediaQuery) -> AsyncStream<ReleaseSnapshot>
}

extension ReleaseAggregator: ReleaseSearching {}

public protocol RatingsService: Sendable {
    func ratings(imdbID: String?, tmdbID: Int?, kind: MediaKind) async throws -> Ratings
    func validate() async throws
}

extension RatingsClient: RatingsService {}

public protocol ChartsService: Sendable {
    func chart(_ chart: IMDbChart) async throws -> [ChartEntry]
    func boxOffice() async throws -> [BoxOfficeEntry]
    /// Trakt's own 0–10 score for a title.
    func rating(imdbID: String?, tmdbID: Int?, kind: MediaKind) async throws -> Double?
}

extension ChartsService {
    public func boxOffice() async throws -> [BoxOfficeEntry] { [] }
    public func rating(imdbID: String?, tmdbID: Int?, kind: MediaKind) async throws -> Double? { nil }
}

extension TraktClient: ChartsService {}

/// MDBList's charts and lists (Movies and TV tabs).
public protocol ListsService: Sendable {
    func chart(_ chart: MDBListChart, kind: MediaKind) async throws -> [MDBListTitle]
    func popularLists() async throws -> [MDBList]
    func curatedLists() async throws -> [MDBList]
    func items(of list: Int, offset: Int, limit: Int) async throws -> MDBListPage
}

extension MDBListClient: ListsService {}

public protocol TrailerService: Sendable {
    func trailer(imdbID: String) async throws -> TrailerVideo?
}

extension IMDbTrailerClient: TrailerService {}

public protocol EpisodeRatingsService: Sendable {
    func ratings(seriesIMDbID: String, season: Int) async throws -> [Int: EpisodeRating]
}

extension IMDbEpisodeRatingsClient: EpisodeRatingsService {}

/// A public IMDb watchlist or list.
public protocol IMDbListService: Sendable {
    func titles(_ ref: IMDbListRef, limit: Int) async throws -> [IMDbListTitle]
}

extension IMDbWatchlistClient: IMDbListService {}
