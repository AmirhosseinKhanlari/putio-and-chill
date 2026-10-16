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
                    .frame(width: 44, height: 44).foregroundStyle(.white.opacity(0.75))
                    // The whole circle takes the touch, not just the gear glyph.
                    .contentShape(Circle())
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if app.library.isRefreshing, !app.library.entries.isEmpty {
            Button { router.tab = .library } label: {
                // Spins for as long as the update runs. A keyframe loop, not a state flip in onAppear: that flip lands
                // in the pill's own insertion transaction and SwiftUI drops it, so the icon sat still.
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .keyframeAnimator(initialValue: 0.0, repeating: !reduceMotion) { icon, angle in
                        icon.rotationEffect(.degrees(angle))
                    } keyframes: { _ in
                        LinearKeyframe(360.0, duration: 1.2)
                    }
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
    @Namespace private var selection

    var body: some View {
        bar
            .padding(.horizontal, 16)
            .onChange(of: router.tab, initial: true) { _, tab in if tab == .movies || tab == .tv { lastBrowse = tab } }
    }

    /// A floating Liquid Glass capsule (like Apple's TV app); the chosen tab sits on a lighter glass pill that slides.
    @ViewBuilder private var bar: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                items.padding(5).glassEffect(.regular, in: .capsule)
            }
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        } else {
            items.padding(5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
    }

    private var items: some View {
        HStack(spacing: 0) {
            ForEach(Item.allCases, id: \.self) { item in
                let selected = item.contains(router.tab)
                Button { select(item, selected: selected) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 22, weight: .semibold)).frame(height: 27)
                        Text(item.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? Self.tint : .white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background { if selected { highlight } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: router.tab)
    }

    @ViewBuilder private var highlight: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.black.opacity(0.18))
                .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .capsule)
                .matchedGeometryEffect(id: "selection", in: selection)
        } else {
            Capsule().fill(.white.opacity(0.14))
                .matchedGeometryEffect(id: "selection", in: selection)
        }
    }

    /// Apple's TV-app blue for the chosen tab.
    static let tint = Color(red: 0.30, green: 0.62, blue: 1.0)

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
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .animation(.snappy, value: router.tab)
    }
}
