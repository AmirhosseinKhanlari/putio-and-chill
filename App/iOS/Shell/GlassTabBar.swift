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
