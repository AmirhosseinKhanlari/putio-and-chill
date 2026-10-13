import AMDBCore
import AMDBKit
import SwiftUI

/// Home: a featured title up top, then what you're watching, My List, new in put.io, and catalog rows.
struct TVHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @Environment(AmbientController.self) private var ambient
    @State private var model: HomeModel?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 50) {
                if let featured = model?.hero.first {
                    TVFeatured(item: featured)
                }
                if !app.library.continueWatching.isEmpty {
                    TVEntryShelf(title: "Continue Watching", entries: app.library.continueWatching)
                }
                if !app.myList.items.isEmpty {
                    TVShelf(title: "My List") {
                        ForEach(app.myList.items.map(\.catalogItem)) { item in TVPosterButton(item: item) { router.open(item) } }
                        Button { router.open(.myList) } label: {
                            VStack(spacing: 12) {
                                Image(systemName: "square.grid.2x2").font(.title)
                                Text("See All")
                            }
                            .frame(width: TVMetrics.poster.width, height: TVMetrics.poster.height)
                        }
                        .buttonStyle(.card)
                    }
                }
                if let hero = model?.hero, hero.count > 1 {
                    TVShelf(title: "Trending") {
                        ForEach(hero.dropFirst()) { item in
                            TVWideCard(title: item.title, subtitle: item.year.map(String.init), imagePath: item.backdropPath,
                                       progress: nil, tintItem: item) { router.open(item) }
                        }
                    }
                }
                if !app.library.recentlyAdded.isEmpty {
                    TVEntryShelf(title: "Recently Added to put.io", entries: app.library.recentlyAdded)
                }
                ForEach(model?.rows ?? []) { TVCatalogShelf(row: $0) }
                if model?.error != nil {
                    Text("Couldn't load the catalog.").foregroundStyle(.secondary).padding(.horizontal, TVMetrics.edge)
                }
            }
            .padding(.bottom, 80)
        }
        .ambientBackground()
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let home = HomeModel(catalog: catalog, store: app.store)
            model = home
            await home.load()
            if let first = home.hero.first { ambient.focus(first) }
        }
    }
}

/// Big backdrop with the title, scores and actions.
struct TVFeatured: View {
    let item: CatalogItem
    @Environment(TVRouter.self) private var router

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(path: item.backdropPath, size: "original", seed: item.title)
                .frame(height: 620)
                .frame(maxWidth: .infinity)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .overlay(LinearGradient(colors: [Theme.background.opacity(0.85), .clear], startPoint: .leading, endPoint: .center))
                .padding(.horizontal, -TVMetrics.edge)
                .ignoresSafeArea(edges: [.horizontal, .top])
            VStack(alignment: .leading, spacing: 18) {
                Text("FEATURED · \(item.mediaType == .tv ? "SERIES" : "FILM")")
                    .font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.7))
                Text(item.title.uppercased())
                    .font(.system(size: 76, weight: .ultraLight)).tracking(6)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .frame(maxWidth: 1100, alignment: .leading)
                if !item.overview.isEmpty {
                    Text(item.overview).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
                        .frame(maxWidth: 900, alignment: .leading)
                }
                HStack(spacing: 24) {
                    Button { router.open(item) } label: { Label("More Info", systemImage: "info.circle") }
                    TVMyListButton(item: item)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.bottom, 20)
        }
        .focusSection()
    }
}

/// ＋ My List / ✓ In My List.
struct TVMyListButton: View {
    let item: CatalogItem
    @Environment(AppModel.self) private var app

    var body: some View {
        let saved = app.myList.contains(item)
        Button { Task { await app.myList.toggle(item) } } label: {
            Label(saved ? "In My List" : "My List", systemImage: saved ? "checkmark" : "plus")
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
            LazyVStack(alignment: .leading, spacing: 40) {
                Text(kind == .tv ? "TV Shows" : "Movies")
                    .font(.system(size: 64, weight: .ultraLight)).tracking(5)
                    .padding(.horizontal, TVMetrics.edge).padding(.top, 20)
                if model?.isLoading == true, model?.rows.isEmpty == true {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
                ForEach(model?.rows ?? []) { TVCatalogShelf(row: $0) }
            }
            .padding(.bottom, 80)
        }
        .ambientBackground()
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
                    Text("No results for \u{201C}\(text)\u{201D}").foregroundStyle(.secondary).padding(.top, 40)
                }
            }
        }
        .searchable(text: $text, prompt: "Movies, shows, people")
        .onChange(of: text) { _, value in model?.query = value }
        .ambientBackground()
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
                Text("My List").font(.system(size: 64, weight: .ultraLight)).tracking(5)
                if app.myList.items.isEmpty {
                    Text("Nothing saved yet. Choose My List on any movie or show.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.poster.width), spacing: 40), count: 6), spacing: 50) {
                    ForEach(app.myList.items.map(\.catalogItem)) { item in TVPosterButton(item: item) { router.open(item) } }
                }
            }
            .padding(TVMetrics.edge)
        }
        .ambientBackground()
    }
}

/// Your put.io: movies, shows and other videos.
struct TVLibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @State private var filter: LibraryFilter = .all

    var body: some View {
        let cards = LibraryCard.cards(from: app.library.entries, filter: filter)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline, spacing: 30) {
                    Text("Library").font(.system(size: 64, weight: .ultraLight)).tracking(5)
                    if app.library.isRefreshing {
                        ProgressView()
                        Text("Updating from put.io…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Picker("Show", selection: $filter) {
                    Text("All").tag(LibraryFilter.all)
                    Text("Movies").tag(LibraryFilter.movies)
                    Text("TV Shows").tag(LibraryFilter.tv)
                    Text("Other").tag(LibraryFilter.other)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 900)
                if cards.isEmpty {
                    Text(app.library.isRefreshing ? "Reading your put.io…" : "Nothing here yet.").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.poster.width), spacing: 40), count: 6), spacing: 50) {
                    ForEach(cards) { card in cardView(card) }
                }
            }
            .padding(TVMetrics.edge)
        }
        .ambientBackground()
    }

    @ViewBuilder private func cardView(_ card: LibraryCard) -> some View {
        switch card {
        case let .movie(entry):
            if let match = entry.match {
                TVPosterButton(item: TVEntryShelf.item(match)) { router.open(TVEntryShelf.item(match)) }
            }
        case let .show(tmdbID, title, posterPath, _):
            let item = CatalogItem(tmdbID: tmdbID, mediaType: .tv, title: title, posterPath: posterPath)
            TVPosterButton(item: item) { router.open(item) }
        case let .file(entry):
            Button { router.play(entry, from: app.library.resumeSeconds(for: entry)) } label: {
                VStack(spacing: 12) {
                    Image(systemName: "film").font(.largeTitle)
                    Text(entry.displayTitle).font(.caption).multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 12)
                }
                .frame(width: TVMetrics.poster.width, height: TVMetrics.poster.height)
            }
            .buttonStyle(.card)
        }
    }
}
