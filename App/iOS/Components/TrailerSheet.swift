import AVKit
import SafariServices
import SwiftUI

/// Plays an IMDb trailer in Apple's player, full screen — same experience as movies (PiP, AirPlay, scrubbing).
@MainActor
enum TrailerPlayer {
    static func present(_ url: URL) {
        guard let presenter = PlayerPresenter.topViewController() else { return }
        let player = AVPlayer(url: url)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true) { player.play() }
    }
}

/// Fallback when IMDb has no trailer: YouTube's page in an in-app browser.
/// (YouTube can't be played in AVPlayer, and its embed player stalls inside apps.)
struct YouTubeFallback: UIViewControllerRepresentable {
    let youtubeKey: String
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: URL(string: "https://m.youtube.com/watch?v=\(youtubeKey)")!)
        controller.preferredBarTintColor = .black
        controller.preferredControlTintColor = .white
        controller.dismissButtonStyle = .done
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, @MainActor SFSafariViewControllerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onFinish() }
    }
}

struct TrailerKey: Identifiable {
    let key: String
    var id: String { key }
}
