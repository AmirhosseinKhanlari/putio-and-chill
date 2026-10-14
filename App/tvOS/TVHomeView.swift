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
                if let hero = model?.hero, !hero.isEmpty {
                    TVHeroCarousel(items: hero)
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
    /// Shown under the buttons (the slider's dots).
    var footer: AnyView?
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
            if let footer { footer.padding(.top, 6) }
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
            if model?.item.id != item.id { model = nil }
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
        let featured = Array((model?.rows.first?.items ?? []).filter { $0.backdropPath != nil }.prefix(6))
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 30) {
                if featured.isEmpty {
                    Text(kind == .tv ? "TV Shows" : "Movies")
                        .font(.system(size: 64, weight: .bold))
                        .padding(.horizontal, TVMetrics.edge).padding(.top, 20)
                } else {
                    TVHeroCarousel(items: featured)
                }
                let recent = app.library.recentlyAdded(kind)
                if !recent.isEmpty {
                    TVEntryShelf(title: "Recently Added to put.io", entries: recent)
                }
                let latest = kind == .tv ? app.chillFeed.shows : app.chillFeed.movies
                if !latest.isEmpty {
                    TVCatalogShelf(row: CatalogRow(id: "latest", title: kind == .tv ? "Latest Shows" : "Latest Movies", items: latest))
                }
                if model?.isLoading == true, model?.rows.isEmpty == true {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
                ForEach(model?.rows ?? []) { TVCatalogShelf(row: $0) }
            }
            .padding(.bottom, 90)
        }
        .ignoresSafeArea(edges: featured.isEmpty ? [] : .top)
        .tvPageBackground()
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let browse = BrowseModel(kind: kind, catalog: catalog)
            model = browse
            Task { await app.refreshChillFeed() }
            await browse.load()
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

/// Featured titles that slide by themselves (like the iPhone app). Pauses while you're on it; on the dots,
/// left and right flip through the slides.
struct TVHeroCarousel: View {
    let items: [CatalogItem]
    @State private var index = 0
    @State private var focusInside = false
    @FocusState private var pagerFocused: Bool

    var body: some View {
        if items.indices.contains(index) {
            // Same view for every slide (no .id), so focus stays on the pager while you swipe.
            TVFeatured(item: items[index], footer: AnyView(pager))
                .onPreferenceChange(TVFocusInsideKey.self) { focusInside = $0 }
                .task(id: items.map(\.id)) {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(9))
                        guard !Task.isCancelled, items.count > 1, !focusInside, !pagerFocused else { continue }
                        withAnimation(.easeInOut(duration: 0.7)) { index = (index + 1) % items.count }
                    }
                }
        }
    }

    /// One focusable page control: land on it, then swipe left / right.
    @ViewBuilder private var pager: some View {
        if items.count > 1 {
            HStack(spacing: 18) {
                HStack(spacing: 8) {
                    ForEach(items.indices, id: \.self) { dot in
                        Capsule().fill(.white.opacity(dot == index ? 1 : 0.35))
                            .frame(width: dot == index ? 34 : 12, height: 12)
                    }
                }
                if pagerFocused {
                    Text("Swipe left or right").font(.system(size: 20, weight: .medium)).foregroundStyle(TVMetrics.secondaryText)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Capsule().fill(.white.opacity(pagerFocused ? 0.18 : 0)))
            .scaleEffect(pagerFocused ? 1.08 : 1, anchor: .leading)
            .animation(.snappy, value: index)
            .animation(.easeOut(duration: 0.18), value: pagerFocused)
            .focusable()
            .focused($pagerFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left: withAnimation(.easeInOut(duration: 0.45)) { index = (index - 1 + items.count) % items.count }
                case .right: withAnimation(.easeInOut(duration: 0.45)) { index = (index + 1) % items.count }
                default: break
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Featured \(index + 1) of \(items.count)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: index = (index + 1) % items.count
                case .decrement: index = (index - 1 + items.count) % items.count
                @unknown default: break
                }
            }
            // The whole width catches focus moving down from any button.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
    }
}
