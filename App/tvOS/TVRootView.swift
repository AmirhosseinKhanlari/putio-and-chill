import AMDBCore
import AMDBKit
import SwiftUI

/// Signed out: the put.io code screen. Signed in: tabs across the top, each with its own navigation.
struct TVRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

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
                    stack($router.upcomingPath) { TVComingUpView() }
                        .tabItem { Text("Coming Up") }.tag(TVTab.upcoming)
                    stack($router.topPath) { TVChartView() }
                        .tabItem { Text("Top 250") }.tag(TVTab.top250)
                    stack($router.libraryPath) { TVLibraryView() }
                        .tabItem { Text("Library") }.tag(TVTab.library)
                    stack($router.searchPath) { TVSearchView() }
                        .tabItem { Image(systemName: "magnifyingglass") }.tag(TVTab.search)
                    NavigationStack { TVSettingsView() }
                        .tabItem { Image(systemName: "gearshape") }.tag(TVTab.settings)
                }
                .overlay(alignment: .topTrailing) { readyNotice }
                .task { await startUp() }
                .onChange(of: app.library.entries) { _, _ in TVTopShelfPublisher.publish(app.library) }
                .onChange(of: app.library.continueWatching.map(\.id)) { _, _ in TVTopShelfPublisher.publish(app.library) }
            }
        }
        .preferredColorScheme(.dark)
        // Leaving the app: make sure the Top Shelf shows what you were just watching.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, app.putio != nil { TVTopShelfPublisher.publish(app.library, force: true) }
            // Back in the app: Latest Movies / Shows are fetched every time it opens, and the library is checked.
            if phase == .active, app.putio != nil {
                Task {
                    await app.refreshChillFeed(force: true)
                    await app.refreshLibraryIfDue()
                }
            }
        }
        // Top Shelf items: play resumes, select opens the title.
        .onOpenURL { url in Task { await open(DeepLink(url: url)) } }
        // The cover stays up when one episode hands over to the next; only the player inside is replaced.
        .fullScreenCover(isPresented: Binding(get: { router.player != nil }, set: { if !$0 { router.player = nil } })) {
            if let request = router.player {
                TVPlayerView(request: request).id(request.id).ignoresSafeArea()
            }
        }
    }

    private func stack<Content: View>(_ path: Binding<[TVRoute]>, @ViewBuilder root: () -> Content) -> some View {
        NavigationStack(path: path) {
            root().navigationDestination(for: TVRoute.self) { route in
                switch route {
                case let .title(item): TVTitleView(item: item)
                case let .versions(request): TVVersionsView(request: request)
                case .myList: TVMyListView()
                case let .person(id): TVPersonView(personID: id)
                case let .collection(id): TVCollectionView(collectionID: id)
                case .surprise: TVSurpriseView()
                case .organize: TVOrganizeView()
                case let .files(folder): TVFilesView(folder: folder)
                case .trash: TVTrashView()
                }
            }
        }
    }

    /// A transfer finished on put.io: a quiet card in the corner with Play.
    @ViewBuilder private var readyNotice: some View {
        if let transfer = router.ready, transfer.playableFile != nil {
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to watch").font(.system(size: 19, weight: .semibold)).foregroundStyle(TVMetrics.secondaryText)
                    Text(transfer.pending.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                }
                .frame(maxWidth: 520, alignment: .leading)
                Button { router.ready = nil; router.playTransfer(transfer) } label: { Label("Play", systemImage: "play.fill") }
                    .tvPill()
                    .layoutPriority(1)
            }
            .padding(.leading, 30).padding(.trailing, 14).padding(.vertical, 14)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 40).padding(.trailing, 60)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: transfer.id) {
                try? await Task.sleep(for: .seconds(12))
                withAnimation { if router.ready?.id == transfer.id { router.ready = nil } }
            }
        }
    }

    private func open(_ link: DeepLink?) async {
        guard let link, app.putio != nil else { return }
        if app.library.entries.isEmpty { await app.library.loadCached() }
        switch link {
        case let .play(fileID):
            if let entry = app.library.entries.first(where: { $0.id == fileID }) {
                router.play(entry, from: app.library.resumeSeconds(for: entry))
            }
        case let .title(tmdbID, kind):
            guard let catalog = app.catalog, let item = try? await catalog.item(kind, id: tmdbID) else { return }
            router.tab = .home
            router.homePath = [.title(item)]
        case .library:
            router.tab = .library
        case .surprise:
            router.tab = .home
            router.homePath = [.surprise]
        }
    }

    /// Saved library first (instant), then put.io when due — same as the iPhone app.
    private func startUp() async {
        app.transfers.onEvent = { [router] event in
            if case let .ready(transfer) = event { withAnimation(.snappy) { router.ready = transfer } }
        }
        switch DemoMode.screen {
        case "title": router.homePath = [.title(DemoCatalog.movies[0])]
        case "show": router.homePath = [.title(DemoCatalog.shows[0])]
        case "person": router.homePath = [.person(900)]
        case "collection": router.homePath = [.collection(8945)]
        case "surprise": router.homePath = [.surprise]
        case "chart": router.tab = .top250
        case "upcoming": router.tab = .upcoming
        case "library": router.tab = .library
        case "files":
            router.tab = .library
            router.open(.files(.root))
        case "search": router.tab = .search
        case "settings": router.tab = .settings
        case "movies": router.tab = .movies
        case "tvshows": router.tab = .tv
        case "player-episode":
            router.player = TVPlayRequest(entry: LibraryEntry(
                file: PutioFile(id: 2, name: "Severance.S02E04.1080p.WEB.H264-NTb.mkv", fileType: "VIDEO", size: 2_000_000_000),
                match: LibraryMatch(tmdbID: DemoCatalog.shows[0].tmdbID, mediaType: .tv, season: 2, episode: 4, confidence: 1,
                                    title: "Severance"),
                folderName: nil), resumeFrom: 1745)
        case "player":
            router.player = TVPlayRequest(entry: LibraryEntry(
                file: PutioFile(id: 2, name: "Severance.S02E04.1080p.WEB.H264-NTb.mkv", fileType: "VIDEO", size: 2_000_000_000),
                match: LibraryMatch(tmdbID: 95396, mediaType: .tv, season: 2, episode: 4, confidence: 1, title: "Severance"),
                folderName: nil), resumeFrom: 0)
        default: break
        }
        await app.library.loadCached()
        TVTopShelfPublisher.publish(app.library)
        await app.myList.load()
        await app.transfers.restore()
        Task { await app.refreshChillFeed(force: true) }
        await app.refreshLibraryIfDue()
    }
}
