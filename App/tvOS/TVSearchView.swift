import AMDBCore
import AMDBKit
import SwiftUI

/// Apple's own TV search: the system search field and keyboard row at the top, which take dictation from the Siri
/// Remote's microphone, with recent searches or top suggestions next to it. Under it, the grid: popular titles until
/// you type, then results that page in as you scroll.
struct TVSearchView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SearchModel?
    @State private var popular: [CatalogItem] = []

    var body: some View {
        Group {
            if let model { TVSearchContent(model: model, popular: popular) } else { Color.clear }
        }
        .tvPageBackground()
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let search = SearchModel(catalog: catalog, store: app.store)
            model = search
            await search.loadRecent()
            popular = ((try? await catalog.trending(nil)) ?? []).filter { $0.mediaType != .person }
        }
    }
}

private struct TVSearchContent: View {
    @Bindable var model: SearchModel
    let popular: [CatalogItem]
    @Environment(TVRouter.self) private var router

    var body: some View {
        results
            .searchable(text: $model.query, prompt: "Movies, shows, people")
            .searchSuggestions { suggestions }
            .onSubmit(of: .search) { Task { await model.commit() } }
    }

    // MARK: Next to the keyboard: recent searches, or top suggestions

    @ViewBuilder private var suggestions: some View {
        if model.query.isEmpty {
            ForEach(model.recent.prefix(6), id: \.self) { recent in
                Label(recent, systemImage: "clock.arrow.circlepath").searchCompletion(recent)
            }
        } else {
            // Picking one fills in its full title; the grid then leads with it.
            ForEach(model.suggestions) { item in
                Text(item.title).searchCompletion(item.title)
            }
        }
    }

    // MARK: Under the keyboard: popular or results

    private var results: some View {
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        let items = searching ? model.grid : popular
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 24) {
                    Text(searching ? "Results" : "Popular Searches").font(.system(size: 34, weight: .bold))
                    if model.isSearching { ProgressView() }
                    Spacer()
                    if let releaseQuery = model.releaseQuery {
                        Button {
                            Task { await model.commit() }
                            router.open(.versions(TVVersionsRequest(query: releaseQuery, target: nil, playNow: [])))
                        } label: {
                            Label("Search Releases", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .tvPill()
                    }
                }
                if searching, items.isEmpty, !model.isSearching {
                    Text("No titles match \u{201C}\(model.query)\u{201D}. Try Search Releases for anything TMDB doesn't know.")
                        .font(.system(size: 24)).foregroundStyle(TVMetrics.secondaryText)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: TVMetrics.poster.width), spacing: 40, alignment: .leading)],
                          alignment: .leading, spacing: 50) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        TVPosterButton(item: item) { open(item) }
                            .onAppear {
                                if searching, index >= items.count - 6, model.canLoadMore { Task { await model.loadMore() } }
                            }
                    }
                }
                if model.isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.top, 30)
            .padding(.bottom, 90)
        }
        .scrollClipDisabled()
    }

    private func open(_ item: CatalogItem) {
        Task { await model.commit() }
        router.open(item)
    }
}
