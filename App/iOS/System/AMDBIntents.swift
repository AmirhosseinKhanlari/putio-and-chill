import AMDBCore
import AMDBKit
import AppIntents

/// "Hey Siri, get a movie with AMDB" → asks for the title → sends the best version to put.io.
struct GetOnPutioIntent: AppIntent {
    static let title: LocalizedStringResource = "Get a Movie"
    static let description = IntentDescription("Finds a movie and sends the best version to put.io.")

    @Parameter(title: "Movie", requestValueDialog: "Which movie?")
    var query: String

    @Dependency var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let catalog = app.catalog,
              let item = try await catalog.searchMulti(query).first(where: { $0.mediaType == .movie }) else {
            return .result(dialog: "I couldn't find a movie called “\(query)”.")
        }
        let name = item.year.map { "\(item.title) (\($0))" } ?? item.title
        guard let imdbID = try await catalog.detail(.movie, id: item.tmdbID).imdbID else {
            return .result(dialog: "I found \(name), but couldn't look up its versions.")
        }
        let target = TransferTarget(tmdbID: item.tmdbID, kind: .movie, title: item.title, posterPath: item.posterPath,
                                    backdropPath: item.backdropPath, season: nil, episode: nil)
        switch await app.smartGet(.movie(imdbID: imdbID, title: item.title, year: item.year), target: target) {
        case let .sent(release):
            return .result(dialog: "Sending \(name) to put.io in \(release.parsed.resolution.label). I'll let you know when it's ready.")
        case .noMatch:
            return .result(dialog: "There's no good version of \(name) right now.")
        case .failed:
            return .result(dialog: "put.io didn't accept \(name). Try again in AMDB.")
        }
    }
}

/// "Continue watching in AMDB" → opens the app and resumes the most recent title.
struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Resumes the last thing you were watching.")
    static let openAppWhenRun = true

    @Dependency var app: AppModel
    @Dependency var router: Router

    @MainActor
    func perform() async throws -> some IntentResult {
        if app.library.entries.isEmpty { await app.library.refresh() }
        if let entry = app.library.continueWatching.first {
            router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry))
        }
        return .result()
    }
}

struct AMDBShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetOnPutioIntent(), phrases: [
            "Get a movie with \(.applicationName)",
            "Send a movie to put.io with \(.applicationName)",
        ], shortTitle: "Get a Movie", systemImageName: "arrow.down.circle")
        AppShortcut(intent: ContinueWatchingIntent(), phrases: [
            "Continue watching in \(.applicationName)",
            "Resume \(.applicationName)",
        ], shortTitle: "Continue Watching", systemImageName: "play.fill")
    }
}
