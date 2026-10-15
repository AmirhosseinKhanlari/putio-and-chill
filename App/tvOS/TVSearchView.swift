import AMDBCore
import AMDBKit
import SwiftUI

/// Netflix-style search: an on-screen keyboard on the left with suggestions or recent searches under it, and the
/// grid on the right (popular titles until you type, then results that page in as you scroll). The field at the top
/// opens Apple's keyboard, which also takes dictation.
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
    /// Focus lands on the keyboard (on "A") when coming down from the tab bar, not on the posters under it.
    @FocusState private var focusedKey: String?

    private static let keys = Array("abcdefghijklmnopqrstuvwxyz1234567890").map(String.init)

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            sidebar
                .frame(width: 500, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .focusSection()
            results
                .focusSection()
        }
        .padding(.horizontal, TVMetrics.edge)
        .padding(.top, 30)
        // Pinned to the top: a long suggestions list must never push the page up under the tab bar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($focusedKey, "a", priority: .userInitiated)
    }

    // MARK: Left: field, keyboard, suggestions

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            // Selecting the field opens Apple's keyboard (with dictation); the letters below type straight in.
            TextField("Movies, shows, people", text: $model.query)
                .onSubmit { Task { await model.commit() } }
                .font(.system(size: 28, weight: .semibold))
                .accessibilityLabel("Search")

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    key(label: Label("Space", systemImage: "space"), width: 245) { model.query += " " }
                    key(label: Label("Delete", systemImage: "delete.left"), width: 245) {
                        if !model.query.isEmpty { model.query.removeLast() }
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(74), spacing: 10), count: 6), spacing: 10) {
                    ForEach(Self.keys, id: \.self) { letter in
                        key(label: Text(letter.uppercased()), width: 74) { model.query += letter }
                            .focused($focusedKey, equals: letter)
                    }
                }
            }

            if model.query.isEmpty {
                if !model.recent.isEmpty {
                    sideList("Recent") {
                        ForEach(model.recent.prefix(4), id: \.self) { recent in
                            Button { model.query = recent } label: {
                                Label(recent, systemImage: "clock.arrow.circlepath").font(.system(size: 24)).lineLimit(1)
                            }
                            .tvRow()
                        }
                    }
                }
            } else if !model.suggestions.isEmpty {
                sideList("Top Suggestions") {
                    // As many as fit under the keyboard; the grid on the right has the rest.
                    ForEach(model.suggestions.prefix(4)) { item in
                        Button { open(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 24, weight: .medium)).lineLimit(1)
                                Text([item.year.map(String.init), item.mediaType == .tv ? "Series" : "Movie"].compactMap { $0 }
                                    .joined(separator: " · "))
                                    .font(.system(size: 19)).opacity(0.7)
                            }
                        }
                        .tvRow()
                    }
                }
            }
        }
    }

    private func key(label: some View, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label.labelStyle(.iconOnly).font(.system(size: 26, weight: .semibold))
                .frame(width: width, height: 64)
        }
        .buttonStyle(TVKeyStyle())
    }

    private func sideList<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(TVMetrics.secondaryText)
            content()
        }
    }

    // MARK: Right: popular or results

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
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.poster.width), spacing: 40), count: 4),
                          alignment: .leading, spacing: 50) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        TVPosterButton(item: item) { open(item) }
                            .onAppear {
                                if searching, index >= items.count - 4, model.canLoadMore { Task { await model.loadMore() } }
                            }
                    }
                }
                if model.isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.bottom, 90)
        }
        .scrollClipDisabled()
    }

    private func open(_ item: CatalogItem) {
        Task { await model.commit() }
        router.open(item)
    }
}

/// A keyboard key: dim at rest, white with black text when focused.
private struct TVKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration)
    }

    private struct KeyBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Color.black : .white)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(focused ? .white : .white.opacity(0.08)))
                .scaleEffect(configuration.isPressed ? 0.94 : (focused ? 1.1 : 1))
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}
