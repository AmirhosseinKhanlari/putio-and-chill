import AMDBCore
import AMDBKit
import SwiftUI

/// Coming Up on the TV: Movies (box office, in cinemas, coming soon) or TV Shows (your next episodes, premieres,
/// returning this week).
struct TVComingUpView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var model: ComingUpModel?
    @State private var kind: MediaKind = .movie
    /// Coming down from the tab bar lands on the Movies / TV Shows chips, not the posters under the tab.
    @FocusState private var focusedChip: MediaKind?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 24) {
                    TVPageHeader(title: "Coming Up", subtitle: kind == .movie ? "Box office and cinemas, US" : "Your shows and what's new on TV")
                    HStack(spacing: 16) {
                        Button("Movies") { kind = .movie }.tvChip(selected: kind == .movie)
                            .focused($focusedChip, equals: .movie)
                        Button("TV Shows") { kind = .tv }.tvChip(selected: kind == .tv)
                            .focused($focusedChip, equals: .tv)
                    }
                    .focusSection()
                }
                .padding(.horizontal, TVMetrics.edge)
                .padding(.top, 20)

                if let model {
                    if kind == .movie { movies(model) } else { shows(model) }
                    if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .padding(.bottom, 90)
        }
        .defaultFocus($focusedChip, kind, priority: .userInitiated)
        .tvPageBackground()
        .task(id: kind) {
            if model == nil, let catalog = app.catalog { model = ComingUpModel(app: app, catalog: catalog) }
            if kind == .movie { await model?.loadMovies() } else { await model?.loadShows() }
        }
    }

    @ViewBuilder private func movies(_ model: ComingUpModel) -> some View {
        if !model.boxOffice.isEmpty {
            TVShelf(title: "Box Office This Weekend") {
                ForEach(model.boxOffice) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        TVPosterButton(item: entry.item, badge: "#\(entry.entry.rank)") { router.open(entry.item) }
                        Text(entry.item.title).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                        if let gross = entry.entry.revenueText {
                            Text("\(gross) weekend").font(.system(size: 19)).foregroundStyle(TVMetrics.secondaryText)
                        }
                    }
                    .frame(width: TVMetrics.poster.width, alignment: .leading)
                }
            }
        }
        if !model.inCinemas.isEmpty {
            TVCatalogShelf(row: CatalogRow(id: "cinemas", title: "In Cinemas Now", items: model.inCinemas))
        }
        if !model.comingSoon.isEmpty { datedShelf("Coming Soon to Cinemas", model.comingSoon) }
    }

    @ViewBuilder private func shows(_ model: ComingUpModel) -> some View {
        let episodes = model.yourEpisodes.flatMap { day in day.episodes.map { (day.label, $0) } }
        if episodes.isEmpty, !model.isLoading {
            Text("Nothing scheduled in the next 30 days for shows in your put.io or My List.")
                .font(.system(size: 24)).foregroundStyle(TVMetrics.secondaryText).padding(.horizontal, TVMetrics.edge)
        } else if !episodes.isEmpty {
            TVShelf(title: "Your Upcoming Episodes") {
                ForEach(episodes, id: \.1.id) { label, episode in
                    TVWideCard(title: episode.show.title,
                               subtitle: "\(label) · S\(episode.season) E\(episode.episode) · \(episode.name)",
                               imagePath: episode.stillPath ?? episode.show.backdropPath) {
                        router.open(episode.show)
                    }
                }
            }
        }
        if !model.premieringSoon.isEmpty { datedShelf("Premiering Soon", model.premieringSoon) }
        if !model.returning.isEmpty {
            TVCatalogShelf(row: CatalogRow(id: "returning", title: "Returning This Week", items: model.returning))
        }
    }

    private func datedShelf(_ title: String, _ items: [DatedItem]) -> some View {
        TVShelf(title: title) {
            ForEach(items) { dated in
                TVPosterButton(item: dated.item, badge: ComingUpModel.shortDate(dated.date)) { router.open(dated.item) }
            }
        }
    }
}
