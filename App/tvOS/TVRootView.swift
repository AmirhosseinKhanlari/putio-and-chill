import AMDBCore
import AMDBKit
import SwiftUI

/// Signed out: the put.io code screen. Signed in: tabs across the top, each with its own navigation.
struct TVRootView: View {
    /// Height of the collapsed sidebar (the pill at the top left).
    static let sidebarInset: CGFloat = 90

    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var username: String?
    /// The put.io account name for the top of the sidebar ("Account" until it's known).
    private var accountName: String { username ?? "Account" }

    var body: some View {
        @Bindable var router = router
        Group {
            if app.putio == nil {
                TVSignInView()
            } else {
                // A sidebar on the left, as in Apple's TV app: it slides away while you browse.
                TabView(selection: Binding(get: { router.tab }, set: { router.select($0) })) {
                    mainTabs
                    listsSection
                    browseSection
                }
                .tabViewStyle(.sidebarAdaptable)
                .modifier(TVSidebarAccountHeader(name: accountName))
                .overlay(alignment: .topTrailing) { readyNotice }
                .task { await startUp() }
                .task(id: app.putio == nil) { username = try? await app.putio?.accountInfo().username }
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

    // MARK: Sidebar

    @TabContentBuilder<TVTab> private var mainTabs: some TabContent<TVTab> {
        @Bindable var router = router
        // Your put.io account (opens Settings), like the profile at the top of Apple's TV app.
        Tab(Self.hasSidebarHeader ? "Settings" : accountName, systemImage: Self.hasSidebarHeader ? "gearshape" : "person.crop.circle.fill",
            value: TVTab.settings) {
            NavigationStack { TVSettingsView().safeAreaPadding(.top, Self.sidebarInset) }
        }
        Tab("Search", systemImage: "magnifyingglass", value: TVTab.search) {
            stack($router.searchPath) { TVSearchView() }
        }
        Tab("Home", systemImage: "house", value: TVTab.home) {
            stack($router.homePath) { TVHomeView() }
        }
        Tab("Movies", systemImage: "film", value: TVTab.movies) {
            stack($router.moviesPath) { TVBrowseView(kind: .movie) }
        }
        Tab("TV Shows", systemImage: "tv", value: TVTab.tv) {
            stack($router.tvPath) { TVBrowseView(kind: .tv) }
        }
        Tab("Coming Up", systemImage: "calendar", value: TVTab.upcoming) {
            stack($router.upcomingPath) { TVComingUpView() }
        }
        Tab("Top 250", systemImage: "star", value: TVTab.top250) {
            stack($router.topPath) { TVChartView() }
        }
        Tab("Library", systemImage: "square.stack.fill", value: TVTab.library) {
            stack($router.libraryPath) { TVLibraryView() }
        }
    }

    @TabContentBuilder<TVTab> private var listsSection: some TabContent<TVTab> {
        @Bindable var router = router
        TabSection("Your Lists") {
            Tab("My List", systemImage: "plus.circle", value: TVTab.myList) {
                stack($router.listsPath) { TVMyListView() }
            }
            Tab("IMDb Watchlist", systemImage: "bookmark", value: TVTab.imdb) {
                stack($router.listsPath) { TVIMDbWatchlistView() }
            }
            Tab("Files", systemImage: "folder", value: TVTab.files) {
                stack($router.listsPath) { TVFilesView(folder: .root) }
            }
            // How many are on their way, in the title (tvOS sidebars have no badges).
            Tab(activeTransfers > 0 ? "Downloading · \(activeTransfers)" : "Downloading", systemImage: "arrow.down.circle",
                value: TVTab.transfers) {
                stack($router.listsPath) { TVTransfersView() }
            }
        }
    }

    @TabContentBuilder<TVTab> private var browseSection: some TabContent<TVTab> {
        @Bindable var router = router
        TabSection("Browse") {
            ForEach(TVGenre.all) { genre in
                Tab(genre.name, systemImage: genre.symbol, value: TVTab.genre(genre.id)) {
                    stack($router.listsPath) { TVGenreView(genre: genre) }
                }
            }
            Tab("Surprise Me", systemImage: "dice", value: TVTab.surprise) {
                stack($router.listsPath) { TVSurpriseView() }
            }
        }
    }

    /// tvOS 27 shows the account above the sidebar's tabs; earlier versions show it as the first tab instead.
    static var hasSidebarHeader: Bool {
        if #available(tvOS 27.0, *) { return true }
        return false
    }

    private var activeTransfers: Int { app.transfers.tracked.filter { $0.playableFile == nil }.count }

    private func stack<Content: View>(_ path: Binding<[TVRoute]>, @ViewBuilder root: () -> Content) -> some View {
        NavigationStack(path: path) {
            // Room for the sidebar's pill at the top left; pages with full-screen art ignore it and run under it.
            root().safeAreaPadding(.top, Self.sidebarInset).navigationDestination(for: TVRoute.self) { route in
                Group { destination(route) }
                    .safeAreaPadding(.top, Self.sidebarInset)
                    // Back goes back exactly one page, wherever focus is on it (e.g. while a list is still loading).
                    // Only on pushed pages: on a tab's first page Back must stay the system's (it opens the sidebar).
                    .onExitCommand { router.goBack() }
            }
        }
    }

    @ViewBuilder private func destination(_ route: TVRoute) -> some View {
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
