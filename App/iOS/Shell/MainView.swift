import AMDBCore
import AMDBKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(OfflineDownloader.self) private var downloader
    @State private var visited: Set<AppTab> = [.home]
    @State private var cleanupReview: [LibraryEntry]?
    @State private var liveActivities = LiveActivityManager()
    /// The saved library and the tracked transfers have been read: a play link can be looked up. Before that (a
    /// widget tap that cold-launches the app) the link waits for them instead of being dropped.
    @State private var linksResolvable = false

    var body: some View {
        @Bindable var router = router
        ZStack(alignment: sizeClass == .compact ? .bottom : .top) {
            ForEach(AppTab.allCases) { tab in
                if visited.contains(tab) {
                    TabStack(tab: tab, path: path(for: tab, router: $router))
                        .opacity(router.tab == tab ? 1 : 0)
                        .allowsHitTesting(router.tab == tab)
                        .accessibilityHidden(router.tab != tab)
                }
            }
            if sizeClass == .compact {
                PhoneTabBar().ignoresSafeArea(.keyboard)
            } else {
                GlassTabBar()
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .ignoresSafeArea(.keyboard)
            }
        }
        .overlay(alignment: .topTrailing) {
            // iPhone: Settings and status at the top right of the main pages (not over Search's field or pushed pages).
            if sizeClass == .compact, router.tab != .search, path(for: router.tab, router: $router).wrappedValue.isEmpty {
                PhoneStatusButtons().padding(.trailing, 16).padding(.top, 4)
            }
        }
        .overlay(alignment: .top) { ReadyBanner() }
        .overlay {
            if let prompt = router.resumePrompt {
                ResumePrompt(request: prompt) { choice in
                    router.resumePrompt = nil
                    if let choice { launch(prompt, from: choice) } else { router.player = nil }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: router.resumePrompt?.id)
        .onChange(of: router.player?.id) { _, _ in
            guard let request = router.player, PlayerCoordinator.current?.request.id != request.id else { return }
            Task { await open(request) }
        }
        .onChange(of: router.tab, initial: true) { _, tab in visited.insert(tab) }
        .sheet(item: $router.versions) { VersionsSheet(request: $0) }
        .sheet(item: $router.fixMatch) { FixMatchSheet(request: $0) }
        .sheet(isPresented: $router.showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $router.showSurprise) { SurprisePage() }
        .task {
            KeyNav.shared.router = router
            wireEvents()
            // The saved library first, so Home and Library fill instantly; put.io is checked afterwards.
            await app.library.loadCached()
            // Positions saved on other devices since last time, without waiting for a library update.
            Task { await app.refreshContinueWatching() }
            await app.myList.load()
            await app.downloads.load()
            downloader.restore()
            DemoMode.apply(to: router)
            #if DEBUG
            if DemoMode.screen == "download-url" { await downloadAndPlayDemoFile() }
            #endif
            openPendingLink()
            await app.transfers.restore()
            // A play link that arrived before the library and transfers were read is tried again now.
            linksResolvable = true
            openPendingLink()
            // Before the library update, so it reads the merged folders.
            await mergeOldFolders()
            await app.refreshLibraryIfDue()
            await runAutoClean()
            await app.episodeAlerts.load()
            await EpisodeAlertScheduler.reschedule(app)
            await WidgetPublisher.publish(app.library)
        }
        .task {
            // While the app is open, update the library whenever the chosen interval has passed.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if UIApplication.shared.applicationState == .active { await app.refreshLibraryIfDue() }
            }
        }
        .onChange(of: app.transfers.tracked) { _, tracked in liveActivities.sync(tracked) }
        // Also when only a position changed (e.g. watched further on another device), or an Up Next card did.
        .onChange(of: WidgetPublisher.signature(app.library)) { _, _ in
            Task { await WidgetPublisher.publish(app.library) }
        }
        // A show's episode was just watched (here or elsewhere): what comes next, from TMDB, for its Up Next card.
        .task(id: app.library.upNextToFind()) { await app.findUpNext() }
        // Downloads saved by earlier builds pick up what the library now knows (e.g. a season-pack episode's number).
        .onChange(of: app.library.lastUpdated) { _, _ in Task { await app.downloads.adopt(app.library.entries) } }
        // Siri and Spotlight know your put.io and My List titles.
        .onChange(of: app.library.entries.count + app.myList.items.count) { _, _ in
            SpotlightIndexer.index(app)
        }
        .onOpenURL { url in open(DeepLink(url: url)) }
        // Controls (Control Center, Action button) leave the screen to open in the App Group.
        .onReceive(NotificationCenter.default.publisher(for: PendingLink.notification)) { _ in openPendingLink() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            app.appWillLeave()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            openPendingLink()
            if app.reloadSyncedTokens() { Task { await app.imdbWatchlist.load(force: true) } }
            // Watched on another device meanwhile: Continue Watching shows it now, not at the next library update.
            Task { await app.refreshContinueWatching() }
            // Saved to or removed from My List on another device.
            Task { await app.myList.sync() }
            // Latest Movies / Shows (chill, MyMoviz) are fetched every time the app opens.
            Task { await app.refreshChillFeed(force: true) }
            // New-episode alerts follow TMDB's schedule, which changes: plan them again.
            Task { await EpisodeAlertScheduler.reschedule(app) }
        }
        .sheet(item: Binding(get: { cleanupReview.map(CleanupList.init) }, set: { if $0 == nil { cleanupReview = nil } })) { list in
            AutoCleanReview(entries: list.entries) {
                cleanupReview = nil
                var settings = app.settings
                settings.autoCleanConfirmed = true
                app.updateSettings(settings)
                Task { await clean(list.entries) }
            } onSkip: { cleanupReview = nil }
        }
        .overlay(alignment: .bottom) {
            if let toast = router.toast {
                Text(toast).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 12).glassCapsule()
                    .padding(.bottom, sizeClass == .compact ? 96 : 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        // Longer messages (the folder merge) stay up long enough to read.
                        try? await Task.sleep(for: .seconds(max(4, Double(toast.count) / 18)))
                        withAnimation { router.toast = nil }
                    }
            }
        }
    }

    private func path(for tab: AppTab, router: Bindable<Router>) -> Binding<[Route]> {
        switch tab {
        case .home: router.homePath
        case .movies: router.moviesPath
        case .tv: router.tvPath
        case .search: router.searchPath
        case .upcoming: router.upcomingPath
        case .library: router.libraryPath
        }
    }

    private func openPendingLink() {
        if let url = PendingLink.take() { open(DeepLink(url: url)) }
    }

    /// Widget / Live Activity / Siri links.
    private func open(_ link: DeepLink?) {
        switch link {
        case let .play(fileID)?:
            if let entry = app.library.entries.first(where: { $0.id == fileID }) {
                router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry))
            } else if let transfer = app.transfers.tracked.first(where: { $0.playableFile?.id == fileID }) {
                router.play(transfer)
            } else if !linksResolvable {
                // Not known yet because nothing has been read: it waits for the library (see the first task).
                PendingLink.set(DeepLink.play(fileID: fileID).url.absoluteString)
            }
        case let .title(tmdbID, kind)?:
            router.tab = .home
            router.open(CatalogItem(tmdbID: tmdbID, mediaType: kind, title: ""))
        case .library?:
            router.tab = .library
        case .surprise?:
            router.showSurprise = true
        case nil:
            break
        }
    }

    /// The one-time move of AMDB/Movies and AMDB/TV into Movies and TV Series; says what it did.
    private func mergeOldFolders() async {
        guard let message = await app.mergeOldFoldersIfNeeded()?.message else { return }
        withAnimation { router.toast = message }
    }

    /// Opt-in auto-clean: the first time, show the list; afterwards delete silently and say so.
    private func runAutoClean() async {
        let due = AutoCleaner.candidates(entries: app.library.entries, finished: await app.store.snapshot.finished,
                                         olderThanDays: app.settings.autoCleanDays, now: Date())
        guard !due.isEmpty else { return }
        if app.settings.autoCleanConfirmed { await clean(due) } else { cleanupReview = due }
    }

    private func clean(_ entries: [LibraryEntry]) async {
        do {
            try await app.library.delete(entries)
            withAnimation { router.toast = "Cleaned up \(entries.count) finished movie\(entries.count == 1 ? "" : "s")" }
        } catch {
            withAnimation { router.toast = "Couldn't clean up put.io right now" }
        }
    }

    /// Plays a request: first asks put.io where it was left (it may have been watched on another device since), briefly,
    /// then offers to resume from the newest position, or starts.
    private func open(_ request: PlayerRequest) async {
        var request = request
        if !request.exactStart {
            // Another copy of the title watched more recently (switching versions): from where that one was left.
            let match = request.played.map {
                LibraryMatch(tmdbID: $0.tmdbID, mediaType: $0.kind, season: request.season, episode: request.episode, confidence: 1)
            }
            let fresh = await app.library.freshResumeSeconds(forTitleOf: LibraryEntry(file: request.file, match: match, folderName: nil))
            // Closed or replaced while put.io was asked.
            guard router.player?.id == request.id, PlayerCoordinator.current?.request.id != request.id else { return }
            request.resumeFrom = fresh
        }
        if request.resumeFrom > 30 { router.resumePrompt = request } else { launch(request, from: 0) }
    }

    private func launch(_ request: PlayerRequest, from seconds: Int) {
        if let played = request.played { Task { await app.notePlayed(played) } }
        let useDownload = switch request.source {
        case .device: true
        case .stream: false
        case .automatic: app.settings.preferDownloads
        }
        let localURL = useDownload ? downloader.localURL(fileID: request.file.id) : nil
        // "Play from This Device" never falls back to streaming: offline that can only fail.
        if request.source == .device, localURL == nil {
            router.player = nil
            withAnimation { router.toast = "This download isn't on this device anymore. Download it again." }
            return
        }
        PlayerPresenter.present(request, from: seconds, app: app, router: router, localURL: localURL)
    }

    #if DEBUG
    /// `-demoScreen download-url -demoPlayURL <url>`: downloads the test video for offline viewing (the original file,
    /// for a video Apple's player can't play), then plays the downloaded copy.
    private func downloadAndPlayDemoFile() async {
        guard let file = DemoMode.playFile else { return }
        router.tab = .library
        router.libraryPath = [.downloads]
        await downloader.start(LibraryEntry(file: file, match: nil, folderName: nil))
        for _ in 0..<120 {
            if case .done? = app.downloads.record(fileID: file.id)?.state { break }
            try? await Task.sleep(for: .seconds(1))
        }
        try? await Task.sleep(for: .seconds(2))
        var request = PlayerRequest(file: file, title: file.name, resumeFrom: 0, played: nil, next: nil, exactStart: true)
        request.source = .device
        router.player = request
    }
    #endif

    private func wireEvents() {
        app.library.onUpdated = { [router, app] change in
            // The very first fetch isn't news, nor files leaving because the library reads fewer folders now;
            // later ones say what changed.
            guard change.added != app.library.entries.count, !change.rescoped else { return }
            let message: String? = switch (change.added, change.removed) {
            case (0, 0): nil
            case let (added, 0): "Library updated · \(added) new"
            case let (0, removed): "Library updated · \(removed) removed"
            case let (added, removed): "Library updated · \(added) new, \(removed) removed"
            }
            if let message { withAnimation { router.toast = message } }
        }
        app.transfers.onEvent = { [router, app] event in
            let active = UIApplication.shared.applicationState == .active
            switch event {
            case let .ready(transfer):
                if active, router.activeTitle == transfer.pending.tmdbID, app.settings.autoPlayCountdown {
                    router.countdown = transfer
                } else {
                    withAnimation(.snappy) { router.banner = .ready(transfer) }
                }
                if !active { Notifier.ready(transfer) }
            case let .failed(transfer):
                withAnimation(.snappy) { router.banner = .failed(transfer) }
            }
        }
    }
}

private struct TabStack: View {
    let tab: AppTab
    @Binding var path: [Route]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack(path: $path) {
            root
                // Keeps content clear of the floating tab bar; full-bleed screens ignore it on purpose.
                .safeAreaInset(edge: sizeClass == .compact ? .bottom : .top, spacing: 0) {
                    Color.clear.frame(height: Metrics.tabBarInset(sizeClass))
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .title(item): TitleView(item: item)
                    case let .episode(item, key): TitleView(item: item, focus: key)
                    case let .chart(chart): ChartPage(chart: chart)
                    case let .person(id): PersonPage(personID: id)
                    case let .collection(id): CollectionPage(collectionID: id)
                    case .myList: MyListPage()
                    case .downloads: DownloadsPage()
                    case let .files(folder): FilesPage(folder: folder)
                    case .trash: TrashPage()
                    case .imdbWatchlist: IMDbWatchlistPage()
                    case let .mdbLists(kind): MDBListsPage(kind: kind)
                    case let .mdbChart(chart, kind): MDBChartPage(chart: chart, kind: kind)
                    case let .mdbList(list): MDBListPage(list: list)
                    }
                }
        }
        .environment(\.keyNavTab, tab)
    }

    @ViewBuilder private var root: some View {
        switch tab {
        case .home: HomeView()
        case .movies: BrowseView(kind: .movie)
        case .tv: BrowseView(kind: .tv)
        case .search: SearchView()
        case .upcoming: ComingUpView()
        case .library: LibraryView()
        }
    }
}

private struct CleanupList: Identifiable {
    let entries: [LibraryEntry]
    var id: String { entries.map { String($0.id) }.joined(separator: ",") }
}
