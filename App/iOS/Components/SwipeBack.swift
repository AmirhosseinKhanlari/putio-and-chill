import UIKit

/// Swipe to go back. The app's pages hide the navigation bar (they draw their own back button), and UIKit turns the
/// back swipe off when the bar is hidden; this turns it back on whenever there is a page to go back to. On iOS 26+
/// the swipe works from anywhere on the page, not just the left edge.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        if #available(iOS 26.0, *) { interactiveContentPopGestureRecognizer?.delegate = self }
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1 && transitionCoordinator == nil
    }

}
