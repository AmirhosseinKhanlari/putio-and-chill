import SafariServices
import SwiftUI

/// Full-screen YouTube trailer in an in-app browser. (The embed player refuses to run here: YouTube error 153.)
struct TrailerSheet: UIViewControllerRepresentable {
    let youtubeKey: String
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let url = URL(string: "https://m.youtube.com/watch?v=\(youtubeKey)")!
        let controller = SFSafariViewController(url: url)
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
