import AMDBCore
import AMDBKit
import SwiftUI

/// A chart shelf on the Movies or TV page (Top 10 on Streaming Today, Trending, Most Anticipated): the Top 10 has big
/// rank numbers, every poster shows how far it moved, and a longer chart ends with See All.
struct TVMDBChartShelf: View {
    let chart: MDBListChart
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router

    var body: some View {
        let titles = app.lists.titles(chart, kind)
        if !titles.isEmpty {
            TVShelf(title: chart.title, trailing: AnyView(Text(chart.credit).font(.system(size: 20)).foregroundStyle(TVMetrics.secondaryText))) {
                ForEach(titles.prefix(20)) { title in
                    HStack(alignment: .bottom, spacing: chart == .streamingTop10 ? -30 : 0) {
                        if chart == .streamingTop10, let rank = title.rank {
                            Text("\(rank)")
                                .font(.system(size: 190, weight: .heavy, design: .rounded))
                                .foregroundStyle(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                                .frame(minWidth: 110)
                                .offset(y: 30)
                        }
                        TVPosterButton(item: title.catalogItem, badge: TVMDBRankChange.text(title.rankChange)) { router.open(title.catalogItem) }
                            .accessibilityLabel(title.rank.map { "Number \($0), \(title.title)" } ?? title.title)
                    }
                }
                if titles.count > 10 {
                    TVListCard(name: "See All", detail: "\(titles.count) titles", symbol: "chevron.right", size: TVMetrics.poster) {
                        router.open(.mdbChart(chart, kind))
                    }
                }
            }
        }
    }
}

enum TVMDBRankChange {
    /// "▲ 3" / "▼ 2" on a poster; nothing when it didn't move.
    static func text(_ change: Int?) -> String? {
        guard let change, change != 0 else { return nil }
        return change > 0 ? "▲ \(change)" : "▼ \(-change)"
    }
}

/// The Lists shelf at the bottom of the Movies and TV pages: MDBList's other charts, then popular and curated lists.
struct TVMDBListsShelf: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router

    var body: some View {
        let lists = app.lists.lists(for: kind)
        if app.lists.isAvailable, !lists.popular.isEmpty || !lists.curated.isEmpty {
            TVShelf(title: "Lists", trailing: AnyView(Text("From MDBList").font(.system(size: 20)).foregroundStyle(TVMetrics.secondaryText))) {
                ForEach(MDBLists.pageCharts, id: \.self) { chart in
                    TVListCard(name: chart.title, detail: "Chart · updated daily", symbol: "chart.line.uptrend.xyaxis") {
                        router.open(.mdbChart(chart, kind))
                    }
                }
                ForEach(Array(lists.popular.prefix(10)) + lists.curated.prefix(10).filter { list in !lists.popular.prefix(10).contains(list) }) { list in
                    TVListCard(list: list) { router.open(.mdbList(list)) }
                }
                TVListCard(name: "See All Lists", detail: "Charts, popular and curated", symbol: "square.grid.2x2") {
                    router.open(.mdbLists(kind))
                }
            }
        }
    }
}

/// A list as a card: its name, who made it and how many titles, on a color drawn from its name.
struct TVListCard: View {
    let name: String
    let detail: String
    var symbol = "list.bullet.rectangle.portrait"
    var size = TVMetrics.wide
    let action: () -> Void

    init(name: String, detail: String, symbol: String = "list.bullet.rectangle.portrait", size: CGSize = TVMetrics.wide,
         action: @escaping () -> Void) {
        self.name = name; self.detail = detail; self.symbol = symbol; self.size = size; self.action = action
    }

    init(list: MDBList, action: @escaping () -> Void) {
        let owner = list.owner.isEmpty ? nil : "by \(list.owner)"
        self.init(name: list.name, detail: ([owner, "\(list.count) titles"].compactMap { $0 }).joined(separator: " · "), action: action)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                Text(name).font(.system(size: 30, weight: .bold)).lineLimit(2).multilineTextAlignment(.leading)
                Text(detail).font(.system(size: 21)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            .padding(24)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .background(LinearGradient(colors: [Theme.tint(for: name), Theme.tint(for: name).opacity(0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .buttonStyle(.card)
        .accessibilityLabel("\(name), \(detail)")
    }
}

/// Every MDBList chart and list for movies or shows.
struct TVMDBListsView: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router

    var body: some View {
        let lists = app.lists.lists(for: kind)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                TVPageHeader(title: kind == .tv ? "TV Lists" : "Movie Lists", subtitle: "From MDBList")
                section("Charts") {
                    ForEach(MDBListChart.allCases, id: \.self) { chart in
                        TVListCard(name: chart.title, detail: "Chart · updated daily", symbol: "chart.line.uptrend.xyaxis") {
                            router.open(.mdbChart(chart, kind))
                        }
                    }
                }
                if !lists.popular.isEmpty {
                    section("Popular Lists") { ForEach(lists.popular) { list in TVListCard(list: list) { router.open(.mdbList(list)) } } }
                }
                if !lists.curated.isEmpty {
                    section("Curated") { ForEach(lists.curated) { list in TVListCard(list: list) { router.open(.mdbList(list)) } } }
                }
                if app.lists.listsFailed {
                    Text("Couldn't load MDBList's lists.").foregroundStyle(TVMetrics.secondaryText)
                }
            }
            .padding(TVMetrics.edge)
        }
        .tvPageBackground()
        .task { await app.lists.loadLists() }
    }

    private func section(_ title: String, @ViewBuilder cards: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.system(size: 34, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.wide.width), spacing: 40), count: 4), alignment: .leading,
                      spacing: 40) { cards() }
        }
        .focusSection()
    }
}

/// A whole MDBList chart, ranked.
struct TVMDBChartView: View {
    let chart: MDBListChart
    let kind: MediaKind
    @Environment(AppModel.self) private var app

    var body: some View {
        let titles = app.lists.titles(chart, kind)
        TVPosterGridPage(title: chart.title, subtitle: "\(kind == .tv ? "Shows" : "Movies") · \(chart.credit)", titles: titles,
                         ranked: true, isLoading: titles.isEmpty, failed: false, loadMore: nil)
            .task { await app.lists.loadChart(chart, kind: kind) }
    }
}

/// One MDBList list, loaded a page at a time.
struct TVMDBListView: View {
    let list: MDBList
    @Environment(AppModel.self) private var app
    @State private var model: MDBListModel?

    var body: some View {
        let owner = list.owner.isEmpty ? nil : "by \(list.owner)"
        TVPosterGridPage(title: list.name, subtitle: ([owner, "\(list.count) titles", "From MDBList"].compactMap { $0 }).joined(separator: " · "),
                         titles: model?.titles ?? [], ranked: false, isLoading: model?.isLoading ?? true, failed: model?.failed ?? false,
                         loadMore: model?.hasMore == true ? { Task { await model?.loadMore() } } : nil)
            .task {
                guard model == nil else { return }
                let loaded = MDBListModel(list: list, lists: app.lists)
                model = loaded
                await loaded.loadMore()
            }
    }
}

private struct TVPosterGridPage: View {
    let title: String
    let subtitle: String
    let titles: [MDBListTitle]
    let ranked: Bool
    let isLoading: Bool
    let failed: Bool
    let loadMore: (() -> Void)?
    @Environment(TVRouter.self) private var router

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                TVPageHeader(title: title, subtitle: subtitle)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(TVMetrics.poster.width), spacing: 40), count: 6), spacing: 50) {
                    ForEach(titles) { title in
                        TVPosterButton(item: title.catalogItem,
                                       badge: ranked ? [title.rank.map { "#\($0)" }, TVMDBRankChange.text(title.rankChange)].compactMap { $0 }.joined(separator: "  ") : nil) {
                            router.open(title.catalogItem)
                        }
                        .onAppear { if title.id == titles.last?.id { loadMore?() } }
                    }
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if failed {
                    Button("Couldn't load more. Try Again") { loadMore?() }.tvPill()
                } else if titles.isEmpty {
                    Text("Nothing in this list yet.").foregroundStyle(TVMetrics.secondaryText)
                }
            }
            .padding(TVMetrics.edge)
        }
        .tvPageBackground()
    }
}
