import AVKit
import SwiftUI
import UIKit

/// Full-screen player: the picture (Apple's player or the built-in one), Picture in Picture, and the app's SwiftUI
/// controls on top. iPhone plays in landscape; iPad follows the device.
@MainActor
final class PlayerViewController: UIViewController, @MainActor AVPictureInPictureControllerDelegate {
    let engine: PlayerEngine
    let chrome: PlayerChrome
    /// Holds the current player's picture view (it changes when the built-in player takes over).
    private let videoContainer = UIView()
    private var pip: AVPictureInPictureController?
    /// Picture in Picture is being closed because the picture changed underneath it: set it up again once it has.
    private var rebuildPiPAfterStop = false

    /// Picture in Picture started (the full-screen player gets out of the way) / ended.
    var onPiPChanged: (Bool) -> Void = { _ in }
    /// The user tapped "back to full screen" in the PiP window.
    var onPiPRestore: (@escaping (Bool) -> Void) -> Void = { $0(true) }

    init(engine: PlayerEngine, chrome: PlayerChrome) {
        self.engine = engine
        self.chrome = chrome
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        videoContainer.frame = view.bounds
        videoContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoContainer)
        showPicture()

        let controls = UIHostingController(rootView: PlayerControlsView(engine: engine, chrome: chrome))
        controls.view.backgroundColor = .clear
        controls.view.frame = view.bounds
        controls.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(controls)
        view.addSubview(controls.view)
        controls.didMove(toParent: self)

        chrome.onSwipeDownChanged = { [weak self] drag in self?.followSwipe(drag) }
        chrome.onSwipeDownEnded = { [weak self] drag, predicted in self?.endSwipe(drag, predicted: predicted) }
        chrome.onFillChanged = { [weak self] fill in self?.engine.setFill(fill) }
        chrome.onTogglePiP = { [weak self] in
            guard let pip = self?.pip else { return }
            pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
        }
        engine.onBackendChanged = { [weak self] in self?.showPicture() }
        engine.onPictureSourceChanged = { [weak self] in self?.setUpPictureInPicture() }
    }

    /// Puts the current player's picture on screen (again, after the built-in player took over).
    private func showPicture() {
        videoContainer.subviews.forEach { $0.removeFromSuperview() }
        let picture = engine.backend.videoView
        picture.frame = videoContainer.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoContainer.addSubview(picture)
        engine.setFill(chrome.fillsScreen)
        setUpPictureInPicture()
    }

    /// Picture in Picture for whatever draws the picture now. The built-in player's layer only exists once it has
    /// loaded, so this runs again when it changes.
    private func setUpPictureInPicture() {
        if let pip, pip.isPictureInPictureActive {
            // The window would keep showing the previous player's layer (a backend switch while in PiP): close it,
            // and PiP is set up again for the new picture once it has stopped.
            rebuildPiPAfterStop = true
            pip.stopPictureInPicture()
            return
        }
        pip?.delegate = nil
        pip = engine.backend.makePictureInPicture()
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
        pip?.delegate = self
        chrome.pipSupported = pip != nil
    }

    /// Closes the Picture in Picture window, if there is one (the playback is being replaced or ended for good).
    func stopPictureInPicture() {
        rebuildPiPAfterStop = false
        guard let pip, pip.isPictureInPictureActive else { return }
        pip.stopPictureInPicture()
    }

    // MARK: Swipe down to close

    /// Drag the video down (from the video, not a button): it follows your finger and shrinks a little; let go far or
    /// fast enough and the player closes. The drag gesture lives in the SwiftUI controls (see PlayerControlsView).
    private func followSwipe(_ drag: CGFloat) {
        let progress = min(1, max(0, drag) / max(1, view.bounds.height))
        let scale = 1 - progress * 0.25
        view.transform = CGAffineTransform(translationX: 0, y: max(0, drag)).scaledBy(x: scale, y: scale)
        view.layer.cornerRadius = min(28, progress * 120)
        view.clipsToBounds = true
    }

    private func endSwipe(_ drag: CGFloat, predicted: CGFloat) {
        if drag > 120 || (drag > 40 && predicted > drag + 160) {
            chrome.onClose()
        } else {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                self.view.transform = .identity
                self.view.layer.cornerRadius = 0
            }
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        traitCollection.userInterfaceIdiom == .phone ? .landscape : .all
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        traitCollection.userInterfaceIdiom == .phone ? .landscapeRight : super.preferredInterfaceOrientationForPresentation
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: Picture in Picture

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        engine.backend.pictureInPictureChanged(active: true)
        chrome.pipActive = true
        onPiPChanged(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        engine.backend.pictureInPictureChanged(active: false)
        chrome.pipActive = false
        onPiPChanged(false)
        if rebuildPiPAfterStop {
            rebuildPiPAfterStop = false
            setUpPictureInPicture()
        }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        onPiPRestore(completionHandler)
    }
}
