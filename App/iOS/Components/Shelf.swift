import SwiftUI
import UIKit

/// A horizontal row that also pages with ‹ › arrows at its edges: always on the Mac, on hover with an iPad's
/// trackpad or mouse, never on touch alone (swiping does it there).
struct Shelf<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var scroller = ShelfScroller()
    @State private var hovering = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content.background(ScrollViewFinder(scroller: scroller))
        }
        .overlay(alignment: .leading) {
            if showArrows, scroller.canGoBack { arrow("chevron.left", label: "Scroll back") { scroller.page(-1) } }
        }
        .overlay(alignment: .trailing) {
            if showArrows, scroller.canGoForward { arrow("chevron.right", label: "Scroll forward") { scroller.page(1) } }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: scroller.canGoBack)
        .animation(.easeOut(duration: 0.15), value: scroller.canGoForward)
    }

    private var showArrows: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        hovering
        #endif
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 64)
                .glassCapsule()
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityLabel(label)
        .transition(.opacity)
    }
}

/// Follows the row's scroll view: whether there's more on either side, and paging by most of a screen.
@Observable @MainActor
final class ShelfScroller {
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    @ObservationIgnored private weak var scrollView: UIScrollView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func attach(_ view: UIScrollView) {
        guard view !== scrollView else { return }
        scrollView = view
        let changed: @Sendable (UIScrollView, Any) -> Void = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.update() }
        }
        observations = [
            view.observe(\.contentOffset, changeHandler: changed),
            view.observe(\.contentSize, changeHandler: changed),
            view.observe(\.bounds, changeHandler: changed),
        ]
        update()
    }

    func page(_ direction: Int) {
        guard let view = scrollView else { return }
        let maxX = max(0, view.contentSize.width - view.bounds.width)
        let target = min(maxX, max(0, view.contentOffset.x + CGFloat(direction) * view.bounds.width * 0.8))
        view.setContentOffset(CGPoint(x: target, y: view.contentOffset.y), animated: true)
    }

    private func update() {
        guard let view = scrollView else { return }
        let x = view.contentOffset.x
        let back = x > 4
        let forward = x < view.contentSize.width - view.bounds.width - 4
        if back != canGoBack { canGoBack = back }
        if forward != canGoForward { canGoForward = forward }
    }
}

/// Finds the UIScrollView behind a SwiftUI ScrollView (it sits inside the content, so the first one above it).
private struct ScrollViewFinder: UIViewRepresentable {
    let scroller: ShelfScroller

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.scroller = scroller
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) { probe.scroller = scroller }

    final class Probe: UIView {
        weak var scroller: ShelfScroller?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // The hosting hierarchy settles on the next turn.
            DispatchQueue.main.async { [weak self] in
                var view = self?.superview
                while let current = view, !(current is UIScrollView) { view = current.superview }
                if let scrollView = view as? UIScrollView { self?.scroller?.attach(scrollView) }
            }
        }
    }
}
