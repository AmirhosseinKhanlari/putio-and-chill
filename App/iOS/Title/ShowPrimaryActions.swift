import AMDBCore
import AMDBKit
import SwiftUI

/// A show's main button, from where you are in it (its Continue Watching card): resume the episode you're watching,
/// or play the one up next after a watched one ("Play S2 E5"), never resume a finished one. Up next but not in
/// put.io: Get & Watch for that episode. Nothing watched yet: no button (the episodes are below).
struct ShowPrimaryActions: View {
    let model: TitleModel
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        switch app.library.watchingCard(tmdbID: model.item.tmdbID) {
        case let .resume(entry)?:
            let seconds = app.library.resumeSeconds(for: entry)
            Button { router.play(entry, resumeFrom: seconds) } label: {
                Label("Resume \(Self.episodeLabel(entry))", systemImage: "play.fill")
            }
            .buttonStyle(.primaryPill)
            .playSourceMenu(entry: entry, resumeFrom: seconds)
        case let .upNext(card)?:
            if let entry = card.entry {
                Button { router.open(card) } label: { Label("Play \(card.episodeLabel)", systemImage: "play.fill") }
                    .buttonStyle(.primaryPill)
                    .playSourceMenu(entry: entry, resumeFrom: 0)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(card.label)\(card.name.map { " · \($0)" } ?? "")")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                    PrimaryActions(model: model, season: card.season, episode: card.episode)
                }
            }
        case nil:
            EmptyView()
        }
    }

    static func episodeLabel(_ entry: LibraryEntry) -> String {
        guard let season = entry.match?.season else { return "" }
        return "S\(season)" + (entry.match?.episode.map { " E\($0)" } ?? "")
    }
}
