import AMDBCore
import AMDBKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var visited: Set<AppTab> = [.home]

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
        .task {
            wireEvents()
            DemoMode.apply(to: router)
            await app.transfers.restore()
            await app.library.refresh()
        }
    }

    private func path(for tab: AppTab, router: Bindable<Router>) -> Binding<[CatalogItem]> {
        switch tab {
        case .home: router.homePath
        case .movies: router.moviesPath
        case .tv: router.tvPath
        case .search: router.searchPath
        case .library: router.libraryPath
        }
    }

    private func launch(_ request: PlayerRequest, from seconds: Int) {
        if let played = request.played { Task { await app.notePlayed(played) } }
        PlayerPresenter.present(request, from: seconds, app: app, router: router)
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
    @Binding var path: [CatalogItem]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack(path: $path) {
            root
                // Keeps content clear of the floating tab bar; full-bleed screens ignore it on purpose.
                .safeAreaInset(edge: sizeClass == .compact ? .bottom : .top, spacing: 0) {
                    Color.clear.frame(height: Metrics.tabBarInset(sizeClass))
                }
                .navigationDestination(for: CatalogItem.self) { TitleView(item: $0) }
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
