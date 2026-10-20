import AMDBCore
import Foundation
import Observation

/// The Fix Match screen: search TMDB for the right movie or show, for shows optionally say which season the files
/// are, choose what it applies to, then apply (or undo with Match Automatically).
@Observable @MainActor
public final class FixMatchModel {
    /// What can be fixed, broadest last (e.g. this file, its folder, every file named like it).
    public let targets: [FixMatchTarget]
    /// A file the screen is about, for the hints ("named season 3").
    public let sampleName: String
    public var query: String
    public private(set) var results: [CatalogItem] = []
    public private(set) var isSearching = false
    public private(set) var searchFailed = false
    public private(set) var chosen: CatalogItem?
    /// The chosen show's seasons (empty while loading, or for a movie).
    public private(set) var seasons: [SeasonSummary] = []
    /// The season the files are; nil keeps the season in each file name.
    public var season: Int?
    public var target: FixMatchTarget
    /// Whether Match Automatically has a choice to undo.
    public let canUndo: Bool

    @ObservationIgnored private let catalog: any CatalogService
    @ObservationIgnored private let library: LibraryIndex
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    public init(targets: [FixMatchTarget], sampleName: String, catalog: any CatalogService, library: LibraryIndex,
                folderID: Int64? = nil) {
        self.targets = targets
        self.target = targets.first ?? .files([])
        self.sampleName = sampleName
        self.catalog = catalog
        self.library = library
        let files = targets.compactMap { if case let .files(files) = $0 { files } else { nil } }.flatMap { $0 }
        self.canUndo = library.hasOverride(files, folderID: folderID)
        self.query = Self.suggestedQuery(sampleName)
    }

    /// "Monster.2022.S03E01.1080p.mkv" → "Monster"; a folder name like "Monster (2022)" → "Monster".
    public static func suggestedQuery(_ name: String) -> String {
        let title = ReleaseNameParser.parse(name).title
        return title.isEmpty ? (name as NSString).deletingPathExtension : title
    }

    /// The season the file names carry, for "As named (season 3)".
    public var namedSeason: Int? { ReleaseNameParser.parse(sampleName).season }

    public func search() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = []; return }
        isSearching = true
        searchFailed = false
        searchTask = Task {
            let found = try? await catalog.searchMulti(text)
            guard !Task.isCancelled else { return }
            results = (found ?? []).filter { $0.mediaType == .movie || $0.mediaType == .tv }
            searchFailed = found == nil
            isSearching = false
        }
    }

    /// Picks a result; for a show its seasons are loaded so one can be chosen.
    public func choose(_ item: CatalogItem) async {
        chosen = item
        season = nil
        seasons = []
        guard item.mediaType == .tv, let detail = try? await catalog.detail(.tv, id: item.tmdbID),
              chosen?.tmdbID == item.tmdbID else { return }
        seasons = detail.seasons
        // A one-season show (a miniseries) is that season whatever the names say ("S03" of the anthology).
        if seasons.count == 1, let only = seasons.first?.number, namedSeason != only { season = only }
    }

    public func clearChoice() {
        chosen = nil
        seasons = []
        season = nil
    }

    /// Saves the choice. Returns the confirmation to show.
    public func apply() async -> String? {
        guard let chosen else { return nil }
        await library.fixMatch(target, as: MatchOverride(item: chosen, season: season))
        return "Matched to \(chosen.title)"
    }

    /// Match Automatically. Returns the confirmation to show.
    public func undo(files: [PutioFile], folderID: Int64? = nil) async -> String {
        await library.matchAutomatically(files, folderID: folderID)
        return "Matching automatically again"
    }
}

/// What Fix Match was opened on, with the choices of what to apply it to.
public struct FixMatchRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The videos it's about (empty for a folder).
    public let files: [PutioFile]
    /// The folder it's about, when opened on one.
    public let folderID: Int64?
    public let sampleName: String
    public let targets: [FixMatchTarget]

    init(files: [PutioFile], folderID: Int64?, sampleName: String, targets: [FixMatchTarget]) {
        id = UUID(); self.files = files; self.folderID = folderID; self.sampleName = sampleName; self.targets = targets
    }

    /// One video: just it, everything in its folder, or every file named like it.
    public static func video(_ file: PutioFile, folderName: String?) -> FixMatchRequest {
        var targets: [FixMatchTarget] = [.files([file])]
        if let parent = file.parentId, parent != 0 { targets.append(.folder(id: parent, name: folderName ?? "its folder")) }
        if MatchOverrides.nameKey(file.name) != nil { targets.append(.sameName(file.name)) }
        return FixMatchRequest(files: [file], folderID: nil, sampleName: file.name, targets: targets)
    }

    /// Every file of a Library card (a show's episodes).
    public static func entries(_ entries: [LibraryEntry]) -> FixMatchRequest {
        guard entries.count > 1 else {
            return entries.first.map { video($0.file, folderName: $0.folderName) }
                ?? FixMatchRequest(files: [], folderID: nil, sampleName: "", targets: [])
        }
        let files = entries.map(\.file)
        return FixMatchRequest(files: files, folderID: nil, sampleName: files[0].name, targets: [.files(files)])
    }

    /// Every video below a folder.
    public static func folder(_ folder: PutioFile) -> FixMatchRequest {
        FixMatchRequest(files: [], folderID: folder.id, sampleName: folder.name, targets: [.folder(id: folder.id, name: folder.name)])
    }

    @MainActor
    public func model(catalog: any CatalogService, library: LibraryIndex) -> FixMatchModel {
        FixMatchModel(targets: targets, sampleName: sampleName, catalog: catalog, library: library, folderID: folderID)
    }
}
