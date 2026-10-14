import AMDBCore
import AMDBKit
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SearchModel?
    @State private var trending: [CatalogItem] = []

    var body: some View {
        Group {
            if let model { SearchContent(model: model, trending: trending) } else { Color.clear }
        }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let search = SearchModel(catalog: catalog, store: app.store)
            model = search
            await search.loadRecent()
            trending = ((try? await catalog.trending(nil)) ?? []).filter { $0.mediaType != .person }
        }
    }
}

private struct SearchContent: View {
    @Bindable var model: SearchModel
    let trending: [CatalogItem]
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    /// Ask AMDB: results for the sentence in the field, and how it was understood.
    @State private var askResults: [CatalogItem]?
    @State private var askSummary = ""
    @State private var asking = false
    @State private var askFailed = false

    var body: some View {
        let compact = sizeClass == .compact
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                    TextField("Movies, shows, people", text: $model.query)
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await model.commit() } }
                        .font(.title3)
                    if model.isSearching { ProgressView() }
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .glassRounded(22)

                if AskAMDB.isAvailable, !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { Task { await ask() } } label: {
                        Label(asking ? "Thinking…" : "Ask AMDB", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassPill)
                    .disabled(asking)
                }

                if let askResults {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Ask AMDB", systemImage: "sparkles").font(.headline)
                        if !askSummary.isEmpty { Text(askSummary).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if askResults.isEmpty {
                        Text("Nothing matched all of that. Try saying it a little differently.").font(.footnote).foregroundStyle(.secondary)
                    }
                    grid(askResults)
                } else if askFailed {
                    Text("Apple Intelligence couldn't answer that right now.").font(.footnote).foregroundStyle(.secondary)
                }

                if askResults == nil, let releaseQuery = model.releaseQuery {
                    Button {
                        Task { await model.commit() }
                        router.versions = VersionsRequest(query: releaseQuery, target: nil, playNow: [])
                    } label: {
                        Label("Search releases for “\(model.query.trimmingCharacters(in: .whitespaces))”", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassPill)

                    if compact {
                        suggestions
                        grid(model.grid, paged: true)
                    } else {
                        HStack(alignment: .top, spacing: 28) {
                            suggestions.frame(width: 260)
                            grid(model.grid, paged: true)
                        }
                    }
                    if model.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    if model.results.isEmpty && !model.isSearching {
                        Text("No titles match. Try “Search releases” for anything TMDB doesn't know.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    if !model.recent.isEmpty {
                        Text("Recent").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.recent, id: \.self) { recent in
                                    Button(recent) { model.query = recent }
                                        .font(.subheadline)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(.white.opacity(0.1), in: Capsule())
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !trending.isEmpty {
                        Text("Popular searches").font(.headline)
                        grid(trending)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focused = true }
        .onChange(of: model.query) { _, _ in askResults = nil; askFailed = false }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top suggestions").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(model.suggestions) { item in
                Button { open(item) } label: {
                    HStack(spacing: 10) {
                        RemoteImage(path: item.posterPath, size: "w92", seed: item.title)
                            .frame(width: 30, height: 45).clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text([item.year.map(String.init), item.mediaType == .tv ? "Series" : "Film"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func grid(_ items: [CatalogItem], paged: Bool = false) -> some View {
        let width = Metrics.poster(sizeClass)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 30), spacing: 12, alignment: .top)],
                         alignment: .leading, spacing: 18) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { open(item) } label: { PosterCard(item: item, width: width) }
                    .buttonStyle(.lift)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .onAppear {
                        // Infinite scroll: fetch the next TMDB page as the last row comes into view.
                        if paged, index >= items.count - 6 { Task { await model.loadMore() } }
                    }
            }
        }
        .animation(.snappy(duration: 0.25), value: items.map(\.id))
    }

    /// Apple Intelligence reads the sentence; TMDB finds the titles.
    private func ask() async {
        guard let catalog = app.catalog else { return }
        asking = true
        askFailed = false
        defer { asking = false }
        focused = false
        do {
            let request = try await AskAMDB.request(for: model.query)
            askSummary = request.summary
            askResults = await AskSearch.run(request, catalog: catalog)
            await model.commit()
        } catch {
            askFailed = true
        }
    }

    private func open(_ item: CatalogItem) {
        Task { await model.commit() }
        router.open(item)
    }
}
