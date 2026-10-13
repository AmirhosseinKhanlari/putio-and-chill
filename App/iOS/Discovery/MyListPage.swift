import AMDBCore
import AMDBKit
import SwiftUI

/// Everything saved with ＋ My List, as a grid: filter movies / shows, sort, remove with a long press.
struct MyListPage: View {
    enum Filter: String, CaseIterable { case all = "All", movies = "Movies", shows = "Shows" }
    enum Sort: String, CaseIterable { case recent = "Recently added", title = "Title", year = "Year" }

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var filter: Filter = .all
    @State private var sort: Sort = .recent

    var body: some View {
        let regular = sizeClass != .compact
        let width = Metrics.poster(sizeClass)
        let items = visibleItems
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SAVED FOR LATER").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.65))
                    Text("My List").font(.system(size: regular ? 54 : 38, weight: .ultraLight)).tracking(3)
                    Text(countText).font(.footnote).foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, regular ? 64 : 56)

                if !app.myList.items.isEmpty {
                    HStack(spacing: 12) {
                        Picker("Show", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                        Spacer(minLength: 0)
                        Menu {
                            Picker("Sort", selection: $sort) {
                                ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) }
                            }
                        } label: {
                            Label(regular ? sort.rawValue : "Sort", systemImage: "arrow.up.arrow.down")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).frame(height: 34)
                                .glassCapsule()
                        }
                        .tint(.white)
                        .accessibilityLabel("Sort by \(sort.rawValue)")
                    }
                }

                if app.myList.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing saved yet").font(.title3.weight(.semibold))
                        Text("Tap ＋ My List on any movie or show to keep it here for later.")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.top, 30)
                } else if items.isEmpty {
                    Text("No \(filter == .movies ? "movies" : "shows") in your list.").foregroundStyle(.secondary).padding(.top, 20)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 30), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(items) { item in
                        Button { router.open(item) } label: { PosterCard(item: item, width: width) }
                            .buttonStyle(.lift)
                            .contextMenu {
                                Button { router.open(item) } label: { Label("Open", systemImage: "info.circle") }
                                Button(role: .destructive) { Task { await app.myList.toggle(item) } } label: {
                                    Label("Remove from My List", systemImage: "minus.circle")
                                }
                            }
                    }
                }
                .animation(.snappy, value: items.map(\.id))
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, 120)
        }
        .ambientBackground()
    }

    private var visibleItems: [CatalogItem] {
        var items = app.myList.items.map(\.catalogItem)
        switch filter {
        case .all: break
        case .movies: items = items.filter { $0.mediaType == .movie }
        case .shows: items = items.filter { $0.mediaType == .tv }
        }
        switch sort {
        case .recent: break
        case .title: items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .year: items.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        }
        return items
    }

    private var countText: String {
        let all = app.myList.items
        let movies = all.filter { $0.kind == .movie }.count
        let shows = all.count - movies
        guard !all.isEmpty else { return "Empty" }
        return [movies > 0 ? "\(movies) movie\(movies == 1 ? "" : "s")" : nil, shows > 0 ? "\(shows) show\(shows == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
