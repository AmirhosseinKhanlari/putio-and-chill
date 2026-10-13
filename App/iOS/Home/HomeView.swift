import AMDBCore
import AMDBKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var model: HomeModel?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                if let model, !model.hero.isEmpty {
                    HeroCarousel(items: model.hero)
                } else {
                    Color.clear.frame(height: 160)
                }
                SurpriseCard()
                if !app.library.continueWatching.isEmpty {
                    EntryRowView(title: "Continue Watching", entries: app.library.continueWatching)
                }
                if !app.myList.items.isEmpty {
                    CatalogRowView(row: CatalogRow(id: "mylist", title: "My List", items: app.myList.items.map(\.catalogItem))) {
                        router.openMyList()
                    }
                }
                if !app.library.recentlyAdded.isEmpty {
                    EntryRowView(title: "Recently Added to put.io", entries: app.library.recentlyAdded)
                }
                ForEach(model?.rows ?? []) { CatalogRowView(row: $0) }
                if let error = model?.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Couldn't load the catalog").font(.headline)
                        Text(String(describing: error)).font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { Task { await model?.load() } }.buttonStyle(.glassPill)
                    }
                    .padding(20).glassRounded().padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 120)
        }
        .ignoresSafeArea(edges: .top)
        .ignoresSafeArea(.keyboard)
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            await model?.load()
            await app.library.refresh()
        }
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let home = HomeModel(catalog: catalog, store: app.store)
            model = home
            await home.load()
        }
    }
}

/// "Can't decide?" entry point for Surprise me.
private struct SurpriseCard: View {
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Button { router.showSurprise = true } label: {
            HStack(spacing: 14) {
                Text("🎲").font(.system(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can't decide?").font(.headline)
                    Text("Pick a mood and get a great movie or series").font(.footnote).foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 8)
                Text("Surprise me").font(.subheadline.weight(.bold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 9).background(.white, in: Capsule())
            }
            .padding(14)
            .glassRounded(18)
        }
        .buttonStyle(.lift)
        .frame(maxWidth: 640)
        .padding(.horizontal, Metrics.gutter(sizeClass))
    }
}
