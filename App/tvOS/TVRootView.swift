import AMDBCore
import AMDBKit
import SwiftUI

/// Signed out: the put.io code screen. Signed in: tabs across the top, each with its own navigation.
struct TVRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        Group {
            if app.putio == nil {
                TVSignInView()
            } else {
                TabView(selection: $router.tab) {
                    stack($router.homePath) { TVHomeView() }
                        .tabItem { Text("Home") }.tag(TVTab.home)
                    stack($router.moviesPath) { TVBrowseView(kind: .movie) }
                        .tabItem { Text("Movies") }.tag(TVTab.movies)
                    stack($router.tvPath) { TVBrowseView(kind: .tv) }
                        .tabItem { Text("TV Shows") }.tag(TVTab.tv)
                    stack($router.searchPath) { TVSearchView() }
                        .tabItem { Image(systemName: "magnifyingglass") }.tag(TVTab.search)
                    stack($router.libraryPath) { TVLibraryView() }
                        .tabItem { Text("Library") }.tag(TVTab.library)
                    NavigationStack { TVSettingsView() }
                        .tabItem { Image(systemName: "gearshape") }.tag(TVTab.settings)
                }
                .task { await startUp() }
            }
        }
        .fullScreenCover(item: $router.player) { request in
            TVPlayerView(request: request).ignoresSafeArea()
        }
    }

    private func stack<Content: View>(_ path: Binding<[TVRoute]>, @ViewBuilder root: () -> Content) -> some View {
        NavigationStack(path: path) {
            root().navigationDestination(for: TVRoute.self) { route in
                switch route {
                case let .title(item): TVTitleView(item: item)
                case let .versions(request): TVVersionsView(request: request)
                case .myList: TVMyListView()
                }
            }
        }
    }

    /// Saved library first (instant), then put.io when due — same as the iPhone app.
    private func startUp() async {
        switch DemoMode.screen {
        case "title": router.homePath = [.title(DemoCatalog.movies[0])]
        case "show": router.homePath = [.title(DemoCatalog.shows[0])]
        case "library": router.tab = .library
        case "search": router.tab = .search
        case "settings": router.tab = .settings
        case "movies": router.tab = .movies
        default: break
        }
        await app.library.loadCached()
        await app.myList.load()
        await app.transfers.restore()
        await app.refreshLibraryIfDue()
    }
}
