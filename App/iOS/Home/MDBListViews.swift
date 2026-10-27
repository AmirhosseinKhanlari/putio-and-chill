import AMDBCore
import AMDBKit
import SwiftUI

/// A chart row on the Movies or TV tab (Top 10 on Streaming Today, Trending, Most Anticipated). The Top 10 has big
/// rank numbers; every title shows how far it moved since yesterday's chart.
struct MDBChartRow: View {
    let chart: MDBListChart
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let titles = app.lists.titles(chart, kind)
        let width = Metrics.poster(sizeClass)
        if !titles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chart.title).font(.title3.weight(.semibold))
                    Spacer()
                    if titles.count > 10 {
                        Button("See all") { router.openChart(chart, kind) }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .accessibilityLabel("See all \(chart.title)")
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
                Shelf {
                    LazyHStack(alignment: .top, spacing: chart == .streamingTop10 ? 4 : 12) {
                        ForEach(titles.prefix(20)) { title in
                            Button { router.open(title.catalogItem) } label: {
                                if chart == .streamingTop10 {
                                    RankedTitle(title: title, width: width)
                                } else {
                                    PosterCard(item: title.catalogItem, width: width)
                                        .overlay(alignment: .topTrailing) { RankChange(change: title.rankChange).padding(6) }
                                }
                            }
                            .buttonStyle(.lift)
                            .accessibilityLabel(title.rank.map { "Number \($0), \(title.title)" } ?? title.title)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                }
                Text(chart.credit).font(.caption2).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}

/// Netflix-style Top 10 card: the rank in big numbers beside the poster.
private struct RankedTitle: View {
    let title: MDBListTitle
    let width: CGFloat

    var body: some View {
        HStack(alignment: .bottom, spacing: -width * 0.18) {
            Text("\(title.rank ?? 0)")
                .font(.system(size: width * 0.8, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.6), radius: 6)
                .frame(minWidth: width * 0.45)
                .offset(y: width * 0.12)
            PosterCard(item: title.catalogItem, width: width)
                .overlay(alignment: .topTrailing) { RankChange(change: title.rankChange).padding(6) }
        }
    }
}

/// ▲3 / ▼2: places moved since the chart's last update. Nothing when it didn't move.
struct RankChange: View {
    let change: Int?

    var body: some View {
        if let change, change != 0 {
            Label("\(abs(change))", systemImage: change > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.bold)).monospacedDigit()
                .foregroundStyle(change > 0 ? Theme.good : Theme.poor)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.7), in: Capsule())
                .accessibilityLabel(change > 0 ? "Up \(change)" : "Down \(-change)")
        }
    }
}

/// The "Lists" row at the bottom of the Movies and TV tabs: MDBList's other charts, then popular and curated lists.
struct MDBListsRow: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let lists = app.lists.lists(for: kind)
        if app.lists.isAvailable, !lists.popular.isEmpty || !lists.curated.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Lists").font(.title3.weight(.semibold))
                    Spacer()
                    Button("See all") { router.openLists(kind) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityLabel("See all lists")
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
                Shelf {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(MDBLists.pageCharts, id: \.self) { chart in
                            ListCard(name: chart.title, detail: "Chart · updated daily", symbol: "chart.line.uptrend.xyaxis") {
                                router.openChart(chart, kind)
                            }
                        }
                        ForEach((lists.popular.prefix(10) + lists.curated.prefix(10)).uniqued()) { list in
                            ListCard(list: list) { router.openList(list) }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                }
                Text("Lists from MDBList").font(.caption2).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}

extension Sequence where Element == MDBList {
    /// Each list once (a list can be both popular and curated), in order.
    func uniqued() -> [MDBList] {
        var seen = Set<Int>()
        return filter { seen.insert($0.id).inserted }
    }
}

/// A list as a tile: its name, who made it and how many titles it has, on a color drawn from its name.
struct ListCard: View {
    let name: String
    let detail: String
    var symbol = "list.bullet.rectangle.portrait"
    let action: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(name: String, detail: String, symbol: String = "list.bullet.rectangle.portrait", action: @escaping () -> Void) {
        self.name = name; self.detail = detail; self.symbol = symbol; self.action = action
    }

    init(list: MDBList, action: @escaping () -> Void) {
        let owner = list.owner.isEmpty ? nil : "by \(list.owner)"
        self.init(name: list.name, detail: ([owner, "\(list.count) titles"].compactMap { $0 }).joined(separator: " · "),
                  action: action)
    }

    var body: some View {
        let width: CGFloat = sizeClass == .compact ? 200 : 250
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
                Text(name).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .padding(14)
            .frame(width: width, height: width * 0.56, alignment: .leading)
            .background(LinearGradient(colors: [Theme.tint(for: name), Theme.tint(for: name).opacity(0.45)], startPoint: .topLeading,
                                       endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.lift)
        .accessibilityLabel("\(name), \(detail)")
    }
}

/// Every MDBList chart and list for movies or shows (the Lists row's See all).
struct MDBListsPage: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let lists = app.lists.lists(for: kind)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MDBLIST").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.65))
                    Text(kind == .tv ? "TV Lists" : "Movie Lists")
                        .font(.system(size: sizeClass == .compact ? 38 : 54, weight: .ultraLight)).tracking(3)
                }
                .padding(.top, sizeClass == .compact ? 56 : 64)
                section("Charts") {
                    ForEach(MDBListChart.allCases, id: \.self) { chart in
                        ListCard(name: chart.title, detail: "Chart · updated daily", symbol: "chart.line.uptrend.xyaxis") {
                            router.openChart(chart, kind)
                        }
                    }
                }
                if !lists.popular.isEmpty {
                    section("Popular Lists") { ForEach(lists.popular) { list in ListCard(list: list) { router.openList(list) } } }
                }
                if !lists.curated.isEmpty {
                    section("Curated") { ForEach(lists.curated) { list in ListCard(list: list) { router.openList(list) } } }
                }
                if app.lists.listsFailed {
                    Text("Couldn't load MDBList's lists.").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Lists from MDBList").font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, 120)
        }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
        .task { await app.lists.loadLists() }
    }

    private func section(_ title: String, @ViewBuilder cards: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 160 : 230), spacing: 12)],
                      alignment: .leading, spacing: 12) { cards() }
        }
    }
}

/// A whole MDBList chart, ranked, with each title's movement.
struct MDBChartPage: View {
    let chart: MDBListChart
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let titles = app.lists.titles(chart, kind)
        PosterGridPage(eyebrow: "MDBLIST CHART", title: chart.title, subtitle: "\(kind == .tv ? "Shows" : "Movies") · \(chart.credit)",
                       titles: titles, ranked: true, isLoading: titles.isEmpty, failed: false, loadMore: nil)
            .task {
                await app.lists.loadChart(chart, kind: kind)
                if let first = app.lists.titles(chart, kind).first { ambient.focus(first.catalogItem) }
            }
    }
}

/// One MDBList list's titles, loaded a page at a time as you scroll.
struct MDBListPage: View {
    let list: MDBList
    @Environment(AppModel.self) private var app
    @Environment(AmbientController.self) private var ambient
    @State private var model: MDBListModel?

    var body: some View {
        let owner = list.owner.isEmpty ? nil : "by \(list.owner)"
        PosterGridPage(eyebrow: "MDBLIST", title: list.name,
                       subtitle: ([owner, "\(list.count) titles"].compactMap { $0 }).joined(separator: " · "),
                       summary: list.summary, titles: model?.titles ?? [], ranked: false,
                       isLoading: model?.isLoading ?? true, failed: model?.failed ?? false,
                       loadMore: model?.hasMore == true ? { Task { await model?.loadMore() } } : nil)
            .task {
                guard model == nil else { return }
                let loaded = MDBListModel(list: list, lists: app.lists)
                model = loaded
                await loaded.loadMore()
                if let first = loaded.titles.first { ambient.focus(first.catalogItem) }
            }
    }
}

/// Header and a grid of posters; `loadMore` runs when the end comes into view.
private struct PosterGridPage: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var summary: String?
    let titles: [MDBListTitle]
    let ranked: Bool
    let isLoading: Bool
    let failed: Bool
    let loadMore: (() -> Void)?
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let width = Metrics.poster(sizeClass)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(eyebrow).font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.white.opacity(0.65))
                    Text(title).font(.system(size: sizeClass == .compact ? 32 : 46, weight: .ultraLight)).tracking(2)
                        .lineLimit(2).minimumScaleFactor(0.6)
                    Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.55))
                    if let summary {
                        Text(summary).font(.callout).foregroundStyle(.white.opacity(0.75)).lineLimit(4).frame(maxWidth: 760, alignment: .leading)
                    }
                }
                .padding(.top, sizeClass == .compact ? 56 : 64)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: width), spacing: 12, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(titles) { title in
                        Button { router.open(title.catalogItem) } label: {
                            PosterCard(item: title.catalogItem, width: width)
                                .overlay(alignment: .topLeading) {
                                    if ranked, let rank = title.rank {
                                        Text("\(rank)").font(.caption.weight(.heavy)).monospacedDigit()
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(.black.opacity(0.7), in: Capsule()).padding(6)
                                    }
                                }
                                .overlay(alignment: .topTrailing) { if ranked { RankChange(change: title.rankChange).padding(6) } }
                        }
                        .buttonStyle(.lift)
                        .onAppear { if title.id == titles.last?.id { loadMore?() } }
                    }
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if failed {
                    Button("Couldn't load more. Try Again") { loadMore?() }.frame(maxWidth: .infinity).padding(.vertical, 20)
                } else if titles.isEmpty {
                    Text("Nothing in this list yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
                Text("From MDBList").font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, 120)
        }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
    }
}
