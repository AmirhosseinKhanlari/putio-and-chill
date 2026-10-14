import AVKit
import SwiftUI
import UIKit

/// A view whose backing layer is the AVPlayerLayer.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Full-screen player: the video layer, Picture in Picture, and the app's SwiftUI controls on top.
/// iPhone plays in landscape; iPad follows the device.
@MainActor
final class PlayerViewController: UIViewController, @MainActor AVPictureInPictureControllerDelegate {
    let engine: PlayerEngine
    let chrome: PlayerChrome
    private let videoView = PlayerLayerView()
    private var pip: AVPictureInPictureController?

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
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.playerLayer.player = engine.player
        videoView.playerLayer.videoGravity = .resizeAspect
        view.addSubview(videoView)

        let controls = UIHostingController(rootView: PlayerControlsView(engine: engine, chrome: chrome))
        controls.view.backgroundColor = .clear
        controls.view.frame = view.bounds
        controls.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(controls)
        view.addSubview(controls.view)
        controls.didMove(toParent: self)

        chrome.onSwipeDownChanged = { [weak self] drag in self?.followSwipe(drag) }
        chrome.onSwipeDownEnded = { [weak self] drag, predicted in self?.endSwipe(drag, predicted: predicted) }

        chrome.onFillChanged = { [weak self] fill in
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            self?.videoView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            CATransaction.commit()
        }
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: videoView.playerLayer) {
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            pip.delegate = self
            self.pip = pip
            chrome.pipSupported = true
            chrome.onTogglePiP = { [weak self] in
                guard let pip = self?.pip else { return }
                pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
            }
        }
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
        chrome.pipActive = true
        onPiPChanged(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        chrome.pipActive = false
        onPiPChanged(false)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        onPiPRestore(completionHandler)
    }
}
