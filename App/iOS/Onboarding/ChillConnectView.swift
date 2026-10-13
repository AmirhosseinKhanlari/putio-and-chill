import AMDBKit
import SwiftUI
import WebKit

struct ChillConnectView: View {
    static let startURL = URL(string: "https://api.chill.institute/auth/putio/start?success_url=https%3A%2F%2Fchill.institute%2Fauth%2Fsuccess")!

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ChillWebView(startURL: Self.startURL) { token in
                    app.setToken(token, for: .chill)
                    dismiss()
                }
                HStack {
                    SecureField("…or paste your chilly token", text: $pasted).textFieldStyle(.roundedBorder)
                    Button("Save") {
                        app.setToken(pasted.trimmingCharacters(in: .whitespacesAndNewlines), for: .chill)
                        dismiss()
                    }
                    .disabled(pasted.isEmpty)
                }
                .padding()
                .background(Theme.sheet)
            }
            .navigationTitle("Connect chill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct ChillWebView: UIViewRepresentable {
    let startURL: URL
    let onToken: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        private let onToken: @MainActor (String) -> Void
        private var delivered = false

        init(onToken: @escaping @MainActor (String) -> Void) { self.onToken = onToken }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url, capture(url) { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url { _ = capture(url) }
        }

        private func capture(_ url: URL) -> Bool {
            guard !delivered, let token = CallbackToken.value(named: "auth_token", in: url) else { return false }
            delivered = true
            onToken(token)
            return true
        }
    }
}
