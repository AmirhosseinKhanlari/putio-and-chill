import UIKit

/// Swipe to go back from the left edge. The app's pages hide the navigation bar (they draw their own back button), and
/// UIKit turns the edge swipe off when the bar is hidden; this turns it back on whenever there is a page to go back to.
/// iOS 26's full-page swipe is left to the system: taking it over made taps on buttons (like Back) that moved a few
/// points turn into swipes.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1 && transitionCoordinator == nil
    }

}
