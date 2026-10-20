import UIKit

/// One of the TV player's menus (Subtitles, Sleep Timer…) or a plain button (Show Details), described once and shown
/// by either player: Apple's (as transport bar menu items) or the built-in one (in its own swipe-down panel).
struct TVMenu: Identifiable {
    let title: String
    let symbol: String
    var items: [TVMenuItem] = []
    /// A button rather than a menu.
    var action: (() -> Void)?
    var id: String { title }

    var uiElement: UIMenuElement {
        if let action {
            let run = MainThreadAction(action)
            return UIAction(title: title, image: UIImage(systemName: symbol)) { _ in run() }
        }
        return UIMenu(title: title, image: UIImage(systemName: symbol), children: items.map(\.uiAction))
    }
}

/// A row in a menu: a choice (with a checkmark when on), or a gray label when it has no action.
struct TVMenuItem: Identifiable {
    let title: String
    var symbol: String?
    var isOn = false
    var action: (() -> Void)?
    let id = UUID()

    static func header(_ title: String) -> TVMenuItem { TVMenuItem(title: title) }

    var uiAction: UIAction {
        guard let action else { return UIAction(title: title, attributes: .disabled) { _ in } }
        let run = MainThreadAction(action)
        return UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) }, state: isOn ? .on : .off) { _ in run() }
    }
}

/// Carries a menu action into UIAction's handler, which UIKit always calls on the main thread.
struct MainThreadAction: @unchecked Sendable {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func callAsFunction() { MainActor.assumeIsolated { action() } }
}
