import AMDBCore
import AMDBKit
import AppIntents
import CoreSpotlight

/// A movie or show from your put.io or My List, for Siri ("Play Severance in Putio & Chill") and Spotlight.
struct TitleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Movie or Show"
    static let defaultQuery = TitleEntityQuery()

    /// "movie-693134" / "tv-95396"
    let id: String
    let title: String
    let year: Int?
    let kind: MediaKind
    let tmdbID: Int
    let posterPath: String?
    let backdropPath: String?
    /// The poster itself, for Spotlight (it shows no artwork from a web address).
    var thumbnail: Data?

    init(_ item: CatalogItem) {
        id = item.id; title = item.title; year = item.year; kind = item.mediaType; tmdbID = item.tmdbID
        posterPath = item.posterPath; backdropPath = item.backdropPath
        thumbnail = SpotlightPosters.data(for: item.id)
    }

    private var subtitle: String {
        [kind == .tv ? "Series" : "Movie", year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    var item: CatalogItem {
        CatalogItem(tmdbID: tmdbID, mediaType: kind, title: title, posterPath: posterPath, backdropPath: backdropPath, year: year)
    }

    /// Spotlight and Siri draw results from this; they can't load a web address, so the poster is the image itself.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: thumbnail.map { .init(data: $0) })
    }
}

/// Titles Siri and Spotlight can name: everything in put.io (shows once) and on My List.
struct TitleEntityQuery: EntityStringQuery {
    @Dependency var app: AppModel

    @MainActor
    func entities(for identifiers: [TitleEntity.ID]) async throws -> [TitleEntity] {
        let all = Self.known(app)
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TitleEntity] {
        let wanted = string.lowercased().trimmingCharacters(in: .whitespaces)
        return Self.known(app).filter { $0.title.lowercased().contains(wanted) }
    }

    /// Also the titles Spotlight offers ("Severance" → Play), so not only a handful.
    @MainActor
    func suggestedEntities() async throws -> [TitleEntity] {
        Array(Self.known(app).prefix(300))
    }

    @MainActor
    static func known(_ app: AppModel) -> [TitleEntity] {
        var seen: Set<String> = []
        let library = app.library.entries.compactMap { entry in entry.match.map { TitleEntity(TVEntryItem.item($0)) } }
        let saved = app.myList.items.map { TitleEntity($0.catalogItem) }
        return (library + saved).filter { seen.insert($0.id).inserted }
    }
}

/// CatalogItem for a library match (same as the TV app's helper).
enum TVEntryItem {
    static func item(_ match: LibraryMatch) -> CatalogItem {
        CatalogItem(tmdbID: match.tmdbID, mediaType: match.mediaType, title: match.title, posterPath: match.posterPath,
                    backdropPath: match.backdropPath, year: match.year)
    }
}

/// Opens a title (Spotlight results and "Open … in Putio & Chill").
struct OpenTitleIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Title"
    static let description = IntentDescription("Opens a movie or show in Putio & Chill.")

    @Parameter(title: "Title") var target: TitleEntity
    @Dependency var router: Router

    @MainActor
    func perform() async throws -> some IntentResult {
        router.tab = .home
        router.open(target.item)
        return .result()
    }
}

/// "Play Severance in Putio & Chill": resumes the movie, or the show where you left off (else its first episode in put.io).
struct PlayTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Plays a movie or show from your put.io, resuming where you left off.")
    static let openAppWhenRun = true

    @Parameter(title: "Title") var target: TitleEntity
    @Dependency var app: AppModel
    @Dependency var router: Router

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if app.library.entries.isEmpty { await app.library.loadCached() }
        let entries = app.library.matching(tmdbID: target.tmdbID)
        // Where you are in it: the episode to resume, or the one up next after a watched one.
        let card = app.library.watchingCard(tmdbID: target.tmdbID)
        if let next = card?.upNext {
            if !next.isInPutio { router.tab = .home }
            router.open(next)
            return .result(dialog: next.isInPutio ? "Playing \(target.title), \(next.episodeLabel)."
                : "\(target.title) \(next.episodeLabel) isn't in your put.io yet. I opened it so you can get it.")
        }
        let first = entries.min { ($0.match?.season ?? 0, $0.match?.episode ?? 0) < ($1.match?.season ?? 0, $1.match?.episode ?? 0) }
        guard let entry = card?.resumeEntry ?? first else {
            router.tab = .home
            router.open(target.item)
            return .result(dialog: "\(target.title) isn't in your put.io yet. I opened it so you can get it.")
        }
        router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry))
        return .result(dialog: "Playing \(target.title).")
    }
}

/// "What's coming up in Putio & Chill" opens Coming Up.
struct OpenComingUpIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Coming Up"
    static let description = IntentDescription("Opens Coming Up: box office, cinemas and your upcoming episodes.")
    static let openAppWhenRun = true

    @Dependency var router: Router

    @MainActor
    func perform() async throws -> some IntentResult {
        router.tab = .upcoming
        return .result()
    }
}

/// Posters saved on the device for Spotlight and Siri (they show no artwork from a web address).
enum SpotlightPosters {
    nonisolated static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "SpotlightPosters", directoryHint: .isDirectory)

    nonisolated static func data(for id: String) -> Data? { try? Data(contentsOf: folder.appending(path: "\(id).jpg")) }

    nonisolated static func save(_ data: Data, for id: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appending(path: "\(id).jpg"), options: .atomic)
    }
}

/// Your put.io and My List titles in Spotlight, once each, with their posters. Spotlight lists a title through the
/// "Play" shortcut (tapping plays it, or opens it when it isn't in put.io). Nothing else may list titles, or each
/// shows twice: "Open" takes no title, and the separate Spotlight entries earlier builds made are removed.
@MainActor
enum SpotlightIndexer {
    static func index(_ app: AppModel) {
        let entities = TitleEntityQuery.known(app)
        Task.detached {
            // Entries earlier builds put in Spotlight themselves (some under the AMDB name); the app adds none now.
            try? await CSSearchableIndex.default().deleteAllSearchableItems()
            _ = await posters(for: entities)
            // Now that the posters are saved, Spotlight's results pick them up.
            AMDBShortcuts.updateAppShortcutParameters()
        }
    }

    /// Small posters (TMDB w154), saved on the device; six downloads at a time, each only once.
    nonisolated private static func posters(for entities: [TitleEntity]) async -> [TitleEntity] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            var result = entities
            var next = 0
            func add() {
                let index = next
                let id = entities[index].id
                let saved = entities[index].thumbnail
                let url = CatalogClient.imageURL(entities[index].posterPath, size: "w154")
                group.addTask {
                    if let saved { return (index, saved) }
                    guard let url, let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return (index, nil) }
                    SpotlightPosters.save(data, for: id)
                    return (index, data)
                }
                next += 1
            }
            while next < min(6, entities.count) { add() }
            while let (index, data) = await group.next() {
                result[index].thumbnail = data
                if next < entities.count { add() }
            }
            return result
        }
    }
}
