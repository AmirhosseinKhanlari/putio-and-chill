import AMDBCore
import AMDBKit
import SwiftUI

/// The connected IMDb watchlist as a grid (movies / shows), each opening its title page.
struct IMDbWatchlistPage: View {
    enum Filter: String, CaseIterable { case all = "All", movies = "Movies", shows = "Shows" }

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var filter: Filter = .all

    var body: some View {
        let regular = sizeClass != .compact
        let width = Metrics.poster(sizeClass)
        let watchlist = app.imdbWatchlist
        let items = watchlist.items.filter { item in
            switch filter {
            case .all: true
            case .movies: item.mediaType == .movie
            case .shows: item.mediaType == .tv
            }
        }
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FROM IMDB").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.65))
                    Text("Watchlist").font(.system(size: regular ? 54 : 38, weight: .ultraLight)).tracking(3)
                    HStack(spacing: 8) {
                        Text("\(watchlist.items.count) title\(watchlist.items.count == 1 ? "" : "s")")
                        if watchlist.isLoading { ProgressView().controlSize(.mini).tint(.white) }
                    }
                    .font(.footnote).foregroundStyle(.white.opacity(0.55))
                    if let problem = watchlist.problem {
                        Text(problem).font(.footnote).foregroundStyle(Theme.okay)
                    }
                }
                .padding(.top, regular ? 64 : 56)

                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 30), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(items) { item in
                        Button { router.open(item) } label: { PosterCard(item: item, width: width) }
                            .buttonStyle(.lift)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, 120)
        }
        .refreshable { await app.imdbWatchlist.load(force: true) }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
    }
}
