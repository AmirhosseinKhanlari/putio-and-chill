import AMDBCore
import AMDBKit
import AppIntents
import CoreSpotlight

/// A movie or show from your put.io or My List, for Siri ("Play Severance in AMDB") and Spotlight.
struct TitleEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Title"
    static let defaultQuery = TitleEntityQuery()

    /// "movie-693134" / "tv-95396"
    let id: String
    let title: String
    let year: Int?
    let kind: MediaKind
    let tmdbID: Int
    let posterPath: String?
    let backdropPath: String?

    init(_ item: CatalogItem) {
        id = item.id; title = item.title; year = item.year; kind = item.mediaType; tmdbID = item.tmdbID
        posterPath = item.posterPath; backdropPath = item.backdropPath
    }

    var item: CatalogItem {
        CatalogItem(tmdbID: tmdbID, mediaType: kind, title: title, posterPath: posterPath, backdropPath: backdropPath, year: year)
    }

    var displayRepresentation: DisplayRepresentation {
        let subtitle = [kind == .tv ? "Series" : "Movie", year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)",
                                     image: CatalogClient.imageURL(posterPath, size: "w185").map { .init(url: $0) })
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

    @MainActor
    func suggestedEntities() async throws -> [TitleEntity] {
        Array(Self.known(app).prefix(20))
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

/// Opens a title (Spotlight results and "Open … in AMDB").
struct OpenTitleIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Title"
    static let description = IntentDescription("Opens a movie or show in AMDB.")

    @Parameter(title: "Title") var target: TitleEntity
    @Dependency var router: Router

    @MainActor
    func perform() async throws -> some IntentResult {
        router.tab = .home
        router.open(target.item)
        return .result()
    }
}

/// "Play Severance in AMDB": resumes the movie, or the show where you left off (else its first episode in put.io).
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
        let resumable = app.library.continueWatching.first { $0.match?.tmdbID == target.tmdbID }
        let first = entries.min { ($0.match?.season ?? 0, $0.match?.episode ?? 0) < ($1.match?.season ?? 0, $1.match?.episode ?? 0) }
        guard let entry = resumable ?? first else {
            router.tab = .home
            router.open(target.item)
            return .result(dialog: "\(target.title) isn't in your put.io yet. I opened it so you can get it.")
        }
        router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry))
        return .result(dialog: "Playing \(target.title).")
    }
}

/// "What's coming up in AMDB" opens Coming Up.
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

/// Puts your put.io and My List titles into Spotlight.
@MainActor
enum SpotlightIndexer {
    static func index(_ app: AppModel) {
        guard #available(iOS 18.0, *) else { return }
        let entities = TitleEntityQuery.known(app)
        Task.detached {
            try? await CSSearchableIndex.default().deleteAppEntities(ofType: TitleEntity.self)
            try? await CSSearchableIndex.default().indexAppEntities(entities)
        }
    }
}
