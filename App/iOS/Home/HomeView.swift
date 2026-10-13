import AMDBCore
import AMDBKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var model: HomeModel?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                if let model, !model.hero.isEmpty {
                    HeroCarousel(items: model.hero)
                } else {
                    Color.clear.frame(height: 160)
                }
                if !app.library.continueWatching.isEmpty {
                    EntryRowView(title: "Continue Watching", entries: app.library.continueWatching)
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
