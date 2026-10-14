import AMDBCore
import AMDBKit
import SwiftUI

/// Home: a featured title on full-screen art, then what you're watching, Surprise Me, My List, trending,
/// new in put.io, and catalog rows.
struct TVHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var model: HomeModel?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 36) {
                if let featured = model?.hero.first {
                    TVFeatured(item: featured)
                }
                if !app.library.continueWatching.isEmpty {
                    TVEntryShelf(title: "Continue Watching", entries: app.library.continueWatching)
                }
                TVShelf(title: "Can't decide?") {
                    Button { router.open(.surprise) } label: {
                        HStack(spacing: 24) {
                            Image(systemName: "dice").font(.system(size: 54, weight: .light))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Surprise Me").font(.system(size: 32, weight: .bold))
                                Text("Pick a mood. Get a great movie or series.").font(.system(size: 22)).foregroundStyle(TVMetrics.secondaryText)
                            }
                        }
                        .padding(.horizontal, 40)
                        .frame(width: 700, height: 180, alignment: .leading)
                        .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .buttonStyle(.card)
                }
                if !app.myList.items.isEmpty {
                    TVShelf(title: "My List", trailing: AnyView(Text("\(app.myList.items.count) saved").font(.system(size: 22)).foregroundStyle(TVMetrics.secondaryText))) {
                        ForEach(app.myList.items.map(\.catalogItem)) { item in TVPosterButton(item: item) { router.open(item) } }
                        Button { router.open(.myList) } label: {
                            VStack(spacing: 14) {
                                Image(systemName: "square.grid.2x2").font(.system(size: 44, weight: .light))
                                Text("See All").font(.system(size: 24, weight: .semibold))
                            }
                            .frame(width: TVMetrics.poster.width, height: TVMetrics.poster.height)
                            .background(Color(white: 0.12))
                        }
                        .buttonStyle(.card)
                    }
                }
                if let hero = model?.hero, hero.count > 1 {
                    TVShelf(title: "Trending") {
                        ForEach(hero.dropFirst()) { item in
                            TVWideCard(title: item.title, subtitle: item.year.map(String.init), imagePath: item.backdropPath) { router.open(item) }
                        }
                    }
                }
                if !app.library.recentlyAdded.isEmpty {
                    TVEntryShelf(title: "Recently Added to put.io", entries: app.library.recentlyAdded)
                }
                ForEach(model?.rows ?? []) { TVCatalogShelf(row: $0) }
                if model?.error != nil {
                    Text("Couldn't load the catalog.").foregroundStyle(TVMetrics.secondaryText).padding(.horizontal, TVMetrics.edge)
                }
            }
            .padding(.bottom, 90)
        }
        // The featured art runs up behind the floating tab bar.
        .ignoresSafeArea(edges: .top)
        .tvPageBackground()
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let home = HomeModel(catalog: catalog, store: app.store)
            model = home
            await home.load()
        }
    }
}

/// Full-screen art with logo, details, scores and the title's actions.
struct TVFeatured: View {
    let item: CatalogItem
    @Environment(AppModel.self) private var app
    @State private var model: TitleModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TVTitleArt(item: item, logoPath: model?.detail?.logoPath)
            TVMetaLine(item: item, detail: model?.detail)
            TVRatingsLine(ratings: model?.ratings, tmdb: item.voteAverage)
            if !item.overview.isEmpty {
                Text(item.overview).font(.system(size: 26)).foregroundStyle(.white.opacity(0.86)).lineLimit(2)
                    .frame(maxWidth: 900, alignment: .leading)
            }
            if let model { TVTitleActions(model: model, item: item, showsDetails: true).padding(.top, 14) }
        }
        .padding(.horizontal, TVMetrics.edge)
        .padding(.bottom, 30)
        .containerRelativeFrame(.vertical, alignment: .bottomLeading) { height, _ in height * 0.84 }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            ZStack {
                RemoteImage(path: item.backdropPath, size: "original", seed: item.title)
                LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.22),
                                       .init(color: .clear, location: 0.5), .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center)
            }
            .padding(.horizontal, -TVMetrics.edge)
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
        .focusSection()
        .task(id: item.id) {
            guard let catalog = app.catalog else { return }
            let title = TitleModel(item: item, catalog: catalog, library: app.library, transfers: app.transfers,
                                   ratings: { [app] imdbID, kind in await app.ratings(imdbID: imdbID, kind: kind) })
            model = title
            await title.load()
        }
    }
}

/// Movies / TV Shows tab: catalog rows for that kind.
struct TVBrowseView: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @State private var model: BrowseModel?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 30) {
                Text(kind == .tv ? "TV Shows" : "Movies")
                    .font(.system(size: 64, weight: .bold))
                    .padding(.horizontal, TVMetrics.edge).padding(.top, 20)
                if model?.isLoading == true, model?.rows.isEmpty == true {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
                ForEach(model?.rows ?? []) { TVCatalogShelf(row: $0) }
            }
            .padding(.bottom, 90)
        }
        .tvPageBackground()
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let browse = BrowseModel(kind: kind, catalog: catalog)
            model = browse
            await browse.load()
        }
    }
}

/// Search with the TV keyboard; results as a poster grid that pages in more as you scroll.
struct TVSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var model: SearchModel?
    @State private var text = ""

    var body: some View {
        ScrollView(.vertical) {
            if let model {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.poster.width), spacing: 40), count: 6), spacing: 50) {
                    ForEach(model.grid) { item in
                        TVPosterButton(item: item) { router.open(item) }
                            .onAppear {
                                if item.id == model.grid.last?.id, model.canLoadMore { Task { await model.loadMore() } }
                            }
                    }
                }
                .padding(TVMetrics.edge)
                if model.isSearching || model.isLoadingMore { ProgressView().padding() }
                if !text.isEmpty, model.grid.isEmpty, !model.isSearching {
                    Text("No results for \u{201C}\(text)\u{201D}").foregroundStyle(TVMetrics.secondaryText).padding(.top, 40)
                }
            }
        }
        .searchable(text: $text, prompt: "Movies, shows, people")
        .onChange(of: text) { _, value in model?.query = value }
        .tvPageBackground()
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            model = SearchModel(catalog: catalog, store: app.store)
        }
    }
}

/// Everything saved with ＋ My List.
struct TVMyListView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                Text("My List").font(.system(size: 64, weight: .bold))
                if app.myList.items.isEmpty {
                    Text("Nothing saved yet. Choose ＋ on any movie or show.").foregroundStyle(TVMetrics.secondaryText)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.poster.width), spacing: 40), count: 6), spacing: 50) {
                    ForEach(app.myList.items.map(\.catalogItem)) { item in TVPosterButton(item: item) { router.open(item) } }
                }
            }
            .padding(TVMetrics.edge)
        }
        .tvPageBackground()
    }
}
