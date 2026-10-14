import AMDBCore
import AMDBKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Ask AMDB": Apple Intelligence turns a sentence into search filters; TMDB does the rest.
enum AskAMDB {
    /// Apple Intelligence is on and its model is ready (iOS 26+, supported iPhone/iPad).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    static func request(for text: String) async throws -> AskRequest {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(to: text, generating: AskPlan.self)
            return response.content.request
        }
        #endif
        return AskRequest()
    }

    private static let instructions = """
        You turn a person's request for something to watch into search filters for a movie database. \
        Only fill in what the request says or clearly implies; leave everything else empty. \
        Decades mean year ranges (the 90s are 1990 to 1999). "Short" means under 100 minutes. \
        Words like "acclaimed", "great" or "best" mean a minimum rating of 7.5. \
        Countries or languages become an ISO 639-1 original language code (Korean is ko, French is fr). \
        If they name a specific title to be like, put it in similarTo.
        """
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct AskPlan {
    @Guide(description: "movie, tv, or any. Use tv for series or shows, movie for films; any if not said.")
    var kind: String
    @Guide(description: "Genres, only from: Action, Adventure, Animation, Comedy, Crime, Documentary, Drama, Family, Fantasy, History, Horror, Music, Mystery, Romance, Science Fiction, Thriller, War, Western.", .maximumCount(3))
    var genres: [String]
    @Guide(description: "Earliest release year, only if the request implies one.")
    var yearFrom: Int?
    @Guide(description: "Latest release year, only if the request implies one.")
    var yearTo: Int?
    @Guide(description: "Maximum length in minutes, only if length is mentioned.")
    var maxRuntimeMinutes: Int?
    @Guide(description: "Minimum rating from 0 to 10, only if quality is mentioned.")
    var minRating: Double?
    @Guide(description: "A specific movie or show title the person wants something similar to.")
    var similarTo: String?
    @Guide(description: "Up to three short topic words, like heist, time travel, space, revenge.", .maximumCount(3))
    var keywords: [String]
    @Guide(description: "ISO 639-1 original language code if a language or country is asked for.")
    var language: String?
    @Guide(description: "popular, rating, or newest.")
    var sort: String

    var request: AskRequest {
        AskRequest(kind: AskRequest.Kind(rawValue: kind.lowercased()) ?? .any,
                   genres: genres.filter { name in AskRequest.genreNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } },
                   yearFrom: yearFrom, yearTo: yearTo, maxRuntime: maxRuntimeMinutes.flatMap { $0 > 0 ? $0 : nil },
                   minRating: minRating.flatMap { (1...10).contains($0) ? $0 : nil },
                   similarTo: similarTo.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
                   keywords: keywords.filter { !$0.isEmpty }, language: language.flatMap { $0.count == 2 ? $0.lowercased() : nil },
                   sort: AskRequest.Sort(rawValue: sort.lowercased()) ?? .popular)
    }
}
#endif
