import SwiftUI
import UIKit

/// Keyboard navigation for the Mac (and an iPad with a keyboard): the arrow keys move a highlight between buttons and
/// posters on screen, scrolling to keep it in view; Return or Space opens it; Esc goes back. SwiftUI's own focus
/// doesn't reach these buttons on the Mac, so the app keeps track itself: every button styled `.lift`, `.glassPill`,
/// `.primaryPill` or `.row` takes part.
@Observable @MainActor
final class KeyNav {
    static let shared = KeyNav()

    enum Direction { case up, down, left, right }

    /// The highlighted button, if any.
    private(set) var focused: UUID?
    /// Typing in a text field: the arrow keys, Return and Space are its own then.
    private(set) var isEditingText = false
    // Observed, so the menu enables its keys once the app is up.
    var router: Router?
    @ObservationIgnored private var items: [UUID: Item] = [:]

    struct Item {
        weak var probe: UIView?
        var tab: AppTab?
        var action: (() -> Void)?
    }

    private init() {
        let center = NotificationCenter.default
        for (name, editing) in [(UITextField.textDidBeginEditingNotification, true), (UITextField.textDidEndEditingNotification, false),
                                (UITextView.textDidBeginEditingNotification, true), (UITextView.textDidEndEditingNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { KeyNav.shared.isEditingText = editing }
            }
        }
    }

    /// Whether the keys belong to navigation right now (not while typing, or while the player is up).
    var isAvailable: Bool {
        guard let router else { return false }
        // `player` is already set while "Resume from…" asks; the player itself has its own keys.
        return !isEditingText && (router.player == nil || router.resumePrompt != nil)
    }

    func register(_ id: UUID, _ item: Item) { items[id] = item }
    func unregister(_ id: UUID) {
        items[id] = nil
        if focused == id { focused = nil }
    }

    // MARK: Keys

    func move(_ direction: Direction) {
        let candidates = visibleItems()
        guard !candidates.isEmpty else { return }
        guard let current = focused, let from = candidates.first(where: { $0.id == current }) else {
            focus(firstOnScreen(candidates))
            return
        }
        let others = candidates.filter { $0.id != current }
        if let next = KeyNav.nearest(from: from.frame, in: direction, among: others.map { ($0.id, $0.frame) }) {
            focus(candidates.first { $0.id == next })
        }
    }

    func activate() {
        guard let focused, visibleItems().contains(where: { $0.id == focused }) else { return move(.down) }
        items[focused]?.action?()
    }

    func back() {
        guard let router else { return }
        if router.resumePrompt != nil {
            router.resumePrompt = nil
            router.player = nil
        } else if router.showSettings { router.showSettings = false } else if router.versions != nil { router.versions = nil } else {
            router.goBack()
        }
    }

    // MARK: Finding

    private struct Candidate {
        let id: UUID
        let frame: CGRect
        let probe: UIView
    }

    /// Buttons on the screen in front: the current tab's page, what's presented over it (a sheet), or the
    /// "Resume from…" prompt.
    private func visibleItems() -> [Candidate] {
        let presented = Self.topPresentedView()
        let prompt = router?.resumePrompt != nil
        return items.compactMap { id, item in
            guard item.action != nil, let probe = item.probe, let window = probe.window, !Self.isHidden(probe) else { return nil }
            if let presented {
                guard probe.isDescendant(of: presented) else { return nil }
            } else if prompt {
                guard item.tab == nil else { return nil }
            } else if item.tab != router?.tab {
                return nil
            }
            let frame = probe.convert(probe.bounds, to: window)
            guard frame.width > 1, frame.height > 1 else { return nil }
            // Pages of a carousel that aren't showing.
            if let pager = Self.scrollViews(above: probe).first(where: \.isPagingEnabled),
               !pager.convert(pager.bounds, to: window).intersects(frame.insetBy(dx: 2, dy: 2)) { return nil }
            return Candidate(id: id, frame: frame, probe: probe)
        }
    }

    private func firstOnScreen(_ candidates: [Candidate]) -> Candidate? {
        let window = candidates.first?.probe.window?.bounds ?? .zero
        let onScreen = candidates.filter { $0.frame.intersects(window.insetBy(dx: 0, dy: 60)) }
        return (onScreen.isEmpty ? candidates : onScreen).min { a, b in
            (a.frame.minY.rounded() / 20, a.frame.minX) < (b.frame.minY.rounded() / 20, b.frame.minX)
        }
    }

    private func focus(_ candidate: Candidate?) {
        guard let candidate else { return }
        focused = candidate.id
        // Innermost first: the row scrolls sideways, then the page up or down (clear of the floating tab bar).
        for scrollView in Self.scrollViews(above: candidate.probe) where !scrollView.isPagingEnabled {
            var rect = candidate.probe.convert(candidate.probe.bounds, to: scrollView).insetBy(dx: -24, dy: -24)
            if scrollView.contentSize.height > scrollView.bounds.height + 1 {
                rect.origin.y -= 70
                rect.size.height += 70
            }
            scrollView.scrollRectToVisible(rect, animated: true)
        }
    }

    /// The closest frame in that direction: same row (or column) first, then the nearest one along the way.
    static func nearest(from: CGRect, in direction: Direction, among others: [(UUID, CGRect)]) -> UUID? {
        let scored: [(UUID, CGFloat)] = others.compactMap { id, frame in
            switch direction {
            case .left, .right:
                let ahead = direction == .right ? frame.midX > from.midX + 1 : frame.midX < from.midX - 1
                let overlap = min(frame.maxY, from.maxY) - max(frame.minY, from.minY)
                guard ahead, overlap > min(frame.height, from.height) * 0.3 else { return nil }
                return (id, abs(frame.midX - from.midX) + abs(frame.midY - from.midY) * 2)
            case .up, .down:
                let ahead = direction == .down ? frame.minY >= from.midY : frame.maxY <= from.midY
                guard ahead else { return nil }
                let gap = direction == .down ? frame.minY - from.maxY : from.minY - frame.maxY
                let sideways = max(0, max(frame.minX, from.minX) - min(frame.maxX, from.maxX)) + abs(frame.minX - from.minX) * 0.25
                return (id, max(0, gap) + sideways * 2)
            }
        }
        return scored.min { $0.1 < $1.1 }?.0
    }

    private static func scrollViews(above view: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        var current = view.superview
        while let next = current {
            if let scrollView = next as? UIScrollView { result.append(scrollView) }
            current = next.superview
        }
        return result
    }

    private static func isHidden(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let next = current {
            if next.isHidden || next.alpha < 0.01 { return true }
            current = next.superview
        }
        return false
    }

    /// The view of whatever is presented over the main screen (a sheet), or nil when nothing is.
    private static func topPresentedView() -> UIView? {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var top = window?.rootViewController?.presentedViewController else { return nil }
        while let next = top.presentedViewController { top = next }
        return top.view
    }
}

// MARK: - Taking part

private struct KeyNavTabKey: EnvironmentKey { static let defaultValue: AppTab? = nil }

extension EnvironmentValues {
    /// The tab a page belongs to, so only the tab on screen is navigated.
    var keyNavTab: AppTab? {
        get { self[KeyNavTabKey.self] }
        set { self[KeyNavTabKey.self] = newValue }
    }
}

/// A button style that also takes part in keyboard navigation, drawing a ring while highlighted.
struct KeyNavStyle<Inner: ButtonStyle, Ring: Shape>: PrimitiveButtonStyle {
    let inner: Inner
    let ring: Ring

    func makeBody(configuration: Configuration) -> some View {
        KeyNavButton(configuration: configuration, inner: inner, ring: ring)
    }
}

private struct KeyNavButton<Inner: ButtonStyle, Ring: Shape>: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let inner: Inner
    let ring: Ring
    @Environment(\.keyNavTab) private var tab
    @Environment(\.isEnabled) private var isEnabled
    @State private var id = UUID()

    var body: some View {
        Button(configuration)
            .buttonStyle(inner)
            .background(KeyNavProbe(id: id, tab: tab, action: isEnabled ? { configuration.trigger() } : nil))
            .overlay {
                if KeyNav.shared.focused == id {
                    ring.stroke(.white, lineWidth: 3).padding(-4).shadow(color: .black.opacity(0.5), radius: 6)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct KeyNavProbe: UIViewRepresentable {
    let id: UUID
    let tab: AppTab?
    let action: (() -> Void)?

    final class Probe: UIView { var id: UUID? }

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.id = id
        view.isUserInteractionEnabled = false
        KeyNav.shared.register(id, .init(probe: view, tab: tab, action: action))
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        KeyNav.shared.register(id, .init(probe: view, tab: tab, action: action))
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        if let id = view.id { KeyNav.shared.unregister(id) }
    }
}

/// A list row: looks like a plain button, dims while pressed.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension PrimitiveButtonStyle where Self == KeyNavStyle<RowPressStyle, RoundedRectangle> {
    /// A list row (a file, a download) that the arrow keys reach.
    static var row: Self { KeyNavStyle(inner: RowPressStyle(), ring: RoundedRectangle(cornerRadius: 12, style: .continuous)) }
}

extension PrimitiveButtonStyle where Self == KeyNavStyle<LiftStyle, RoundedRectangle> {
    static var lift: Self { KeyNavStyle(inner: LiftStyle(), ring: RoundedRectangle(cornerRadius: 12, style: .continuous)) }
}

extension PrimitiveButtonStyle where Self == KeyNavStyle<GlassPillStyle, Capsule> {
    static var glassPill: Self { KeyNavStyle(inner: GlassPillStyle(), ring: Capsule()) }
}

extension PrimitiveButtonStyle where Self == KeyNavStyle<PrimaryPillStyle, Capsule> {
    static var primaryPill: Self { KeyNavStyle(inner: PrimaryPillStyle(), ring: Capsule()) }
}
