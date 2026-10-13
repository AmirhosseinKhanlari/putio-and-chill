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
            GlassTabBar()
                .padding(.horizontal, 12)
                .padding(sizeClass == .compact ? .bottom : .top, 6)
                .ignoresSafeArea(.keyboard)
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
            if request.resumeFrom > 30 { router.resumePrompt = request } else { launch(request, from: 0) }
        }
        .onChange(of: router.tab, initial: true) { _, tab in visited.insert(tab) }
        .sheet(item: $router.versions) { VersionsSheet(request: $0) }
        .sheet(isPresented: $router.showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $router.showSurprise) { SurprisePage() }
        .task {
            wireEvents()
            await app.myList.load()
            await app.downloads.load()
            downloader.restore()
            DemoMode.apply(to: router)
            await app.transfers.restore()
            await app.library.refresh()
            await runAutoClean()
            await WidgetPublisher.publish(app.library)
        }
        .onChange(of: app.transfers.tracked) { _, tracked in liveActivities.sync(tracked) }
        .onChange(of: app.library.continueWatching.map(\.id)) { _, _ in Task { await WidgetPublisher.publish(app.library) } }
        .onOpenURL { url in open(DeepLink(url: url)) }
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
                        try? await Task.sleep(for: .seconds(4))
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
        case .library: router.libraryPath
        }
    }

    /// Widget / Live Activity / Siri links.
    private func open(_ link: DeepLink?) {
        switch link {
        case let .play(fileID)?:
            if let entry = app.library.entries.first(where: { $0.id == fileID }) {
                router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry))
            } else if let transfer = app.transfers.tracked.first(where: { $0.playableFile?.id == fileID }) {
                router.play(transfer)
            }
        case let .title(tmdbID, kind)?:
            router.tab = .home
            router.open(CatalogItem(tmdbID: tmdbID, mediaType: kind, title: ""))
        case .library?:
            router.tab = .library
        case nil:
            break
        }
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

    private func launch(_ request: PlayerRequest, from seconds: Int) {
        if let played = request.played { Task { await app.notePlayed(played) } }
        PlayerPresenter.present(request, from: seconds, app: app, router: router,
                                localURL: downloader.localURL(fileID: request.file.id))
    }

    private func wireEvents() {
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
                    case let .chart(chart): ChartPage(chart: chart)
                    case let .person(id): PersonPage(personID: id)
                    case let .collection(id): CollectionPage(collectionID: id)
                    }
                }
        }
    }

    @ViewBuilder private var root: some View {
        switch tab {
        case .home: HomeView()
        case .movies: BrowseView(kind: .movie)
        case .tv: BrowseView(kind: .tv)
        case .search: SearchView()
        case .library: LibraryView()
        }
    }
}

private struct CleanupList: Identifiable {
    let entries: [LibraryEntry]
    var id: String { entries.map { String($0.id) }.joined(separator: ",") }
}
