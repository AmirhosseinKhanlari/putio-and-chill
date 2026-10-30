import AMDBCore
import AMDBKit
import SwiftUI

struct BrowseView: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @Environment(AmbientController.self) private var ambient
    @Environment(ChartCenter.self) private var charts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: BrowseModel?
    @State private var chart: ChartModel?
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                Text(kind == .tv ? "TV Shows" : "Movies")
                    .font(.system(size: sizeClass == .compact ? 34 : 48, weight: .ultraLight)).tracking(3)
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                    .padding(.top, 12)
                if sizeClass == .compact {
                    // iPhone: Movies and TV share the Browse tab.
                    Picker("Browse", selection: Binding(get: { router.tab }, set: { router.tab = $0 })) {
                        Text("Movies").tag(AppTab.movies)
                        Text("TV Shows").tag(AppTab.tv)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                    .padding(.top, -14)
                }
                let recent = app.library.recentlyAdded(kind)
                if !recent.isEmpty {
                    EntryRowView(title: "Recently Added to put.io", entries: recent)
                }
                // New to Stream / New Episodes This Week (TMDB), then MyMoviz's newest.
                if let fresh = model?.newReleases { CatalogRowView(row: fresh) }
                let latest = kind == .tv ? app.latestFeed.shows : app.latestFeed.movies
                if !latest.isEmpty {
                    CatalogRowView(row: CatalogRow(id: "latest", title: kind == .tv ? "Latest Shows" : "Latest Movies", items: latest))
                }
                MDBChartRow(chart: .streamingTop10, kind: kind)
                MDBChartRow(chart: .trending, kind: kind)
                if let chart { ChartRowView(model: chart) }
                MDBChartRow(chart: .anticipated, kind: kind)
                if model?.isLoading == true && model?.rows.isEmpty == true {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(model?.rows ?? []) { CatalogRowView(row: $0) }
                MDBListsRow(kind: kind)
            }
            .padding(.bottom, 120)
        }
        .ignoresSafeArea(.keyboard)
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            // MDBList's charts and lists, asked for again once they're a few hours old.
            Task { await app.lists.loadRows(kind: kind) }
            Task { await app.lists.loadLists() }
            guard model == nil, let catalog = app.catalog else { return }
            let browse = BrowseModel(kind: kind, catalog: catalog)
            model = browse
            if let top = charts.model(kind == .tv ? .top250TV : .top250Movies, app: app) {
                chart = top
                Task { await top.load() }
            }
            Task { await app.refreshLatestFeed() }
            await browse.load()
            if let first = browse.rows.first?.items.first { ambient.focus(first) }
        }
    }
}
