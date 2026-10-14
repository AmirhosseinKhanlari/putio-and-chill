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

        let swipe = UIPanGestureRecognizer(target: self, action: #selector(swipeDown(_:)))
        swipe.delegate = self
        view.addGestureRecognizer(swipe)

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

    /// Drag the video down: it follows your finger and shrinks a little; let go far or fast enough and the player closes.
    @objc private func swipeDown(_ pan: UIPanGestureRecognizer) {
        let drag = max(0, pan.translation(in: view).y)
        let progress = min(1, drag / max(1, view.bounds.height))
        switch pan.state {
        case .changed:
            let scale = 1 - progress * 0.25
            view.transform = CGAffineTransform(translationX: 0, y: drag).scaledBy(x: scale, y: scale)
            view.layer.cornerRadius = min(28, progress * 120)
            view.clipsToBounds = true
        case .ended, .cancelled:
            let velocity = pan.velocity(in: view).y
            if pan.state == .ended, drag > 140 || velocity > 900 {
                chrome.onClose()
            } else {
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    self.view.transform = .identity
                    self.view.layer.cornerRadius = 0
                }
            }
        default:
            break
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

extension PlayerViewController: UIGestureRecognizerDelegate {
    /// Only a mostly-downward drag that doesn't start on the progress bar and buttons at the bottom.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pip?.isPictureInPictureActive != true else { return false }
        let velocity = pan.velocity(in: view)
        let start = pan.location(in: view)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x) * 1.5 && start.y < view.bounds.height - 150
    }
}
