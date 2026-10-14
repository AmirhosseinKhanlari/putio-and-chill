import AMDBKit
import SwiftUI

struct GlassTabBar: View {
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                let selected = router.tab == tab
                Button {
                    if selected { router.popToRoot(tab) } else { router.tab = tab }
                } label: {
                    Group {
                        if sizeClass == .compact {
                            Image(systemName: tab.symbol).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 36)
                        } else {
                            Text(tab.title).font(.subheadline.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                        }
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(0.6))
                    .background { if selected { Capsule().fill(.white.opacity(0.16)) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
            LibraryUpdatePill()
            TransferPill()
            Button { router.showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36).foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(5)
        .glassCapsule()
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

/// Shows while the library is being updated from put.io in the background.
private struct LibraryUpdatePill: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var spin = false

    var body: some View {
        if app.library.isRefreshing, !app.library.entries.isEmpty {
            Button { router.tab = .library } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Updating library from put.io")
        }
    }
}

private struct TransferPill: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        let active = app.transfers.tracked.filter { !$0.notified }
        if !active.isEmpty {
            let percent = active.map(\.percent).reduce(0, +) / active.count
            Button { router.tab = .library } label: {
                HStack(spacing: 6) {
                    ProgressRing(progress: Double(percent) / 100, lineWidth: 2.5).frame(width: 16, height: 16)
                    Text("\(percent)%").font(.caption.monospacedDigit().weight(.semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("\(active.count) transfers, \(percent) percent")
        }
    }
}

// MARK: iPhone

/// iPhone: a full-width bar with five labelled tabs and big tap areas. Movies and TV share "Browse" (a switch at the
/// top of the page); Settings and the update / transfer status sit at the top right of each main page.
struct PhoneTabBar: View {
    enum Item: CaseIterable {
        case home, browse, upcoming, search, library

        var title: String {
            switch self {
            case .home: "Home"
            case .browse: "Browse"
            case .upcoming: "Coming Up"
            case .search: "Search"
            case .library: "Library"
            }
        }

        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .browse: "film.stack"
            case .upcoming: "calendar"
            case .search: "magnifyingglass"
            case .library: "square.stack.fill"
            }
        }

        func contains(_ tab: AppTab) -> Bool {
            switch self {
            case .home: tab == .home
            case .browse: tab == .movies || tab == .tv
            case .upcoming: tab == .upcoming
            case .search: tab == .search
            case .library: tab == .library
            }
        }
    }

    @Environment(Router.self) private var router
    /// Browse reopens Movies or TV, whichever was used last.
    @State private var lastBrowse: AppTab = .movies

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Item.allCases, id: \.self) { item in
                let selected = item.contains(router.tab)
                Button { select(item, selected: selected) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 21, weight: selected ? .semibold : .regular))
                            .frame(height: 26)
                        Text(item.title).font(.system(size: 11, weight: selected ? .semibold : .medium)).lineLimit(1)
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        }
        .onChange(of: router.tab, initial: true) { _, tab in if tab == .movies || tab == .tv { lastBrowse = tab } }
    }

    private func select(_ item: Item, selected: Bool) {
        if selected { router.popToRoot(router.tab); return }
        switch item {
        case .home: router.tab = .home
        case .browse: router.tab = lastBrowse
        case .upcoming: router.tab = .upcoming
        case .search: router.tab = .search
        case .library: router.tab = .library
        }
    }
}

/// iPhone: library update / transfers / Settings at the top right of the main pages.
struct PhoneStatusButtons: View {
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 8) {
            LibraryUpdatePill()
            TransferPill()
            Button { router.showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white.opacity(0.9))
                    .glassCapsule()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .animation(.snappy, value: router.tab)
    }
}
