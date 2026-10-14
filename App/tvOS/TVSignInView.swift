import AMDBCore
import AMDBKit
import SwiftUI

/// Sign in to put.io without typing a password on the TV: enter the code at put.io/link on a phone or computer,
/// or scan the QR code.
struct TVSignInView: View {
    @Environment(AppModel.self) private var app
    @State private var signIn: DeviceSignIn?

    var body: some View {
        HStack(alignment: .center, spacing: 120) {
            VStack(alignment: .leading, spacing: 28) {
                Text("AMDB").font(.system(size: 96, weight: .bold))
                Text("Sign in to put.io").font(.system(size: 40, weight: .semibold))
                VStack(alignment: .leading, spacing: 14) {
                    Label("On your phone or computer, go to put.io/link", systemImage: "1.circle")
                    Label("Enter this code", systemImage: "2.circle")
                }
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(TVMetrics.secondaryText)
                switch signIn?.phase {
                case let .waiting(code):
                    Text(code.code)
                        .font(.system(size: 120, weight: .semibold, design: .monospaced))
                        .tracking(18)
                        .accessibilityLabel("Code \(code.code.map(String.init).joined(separator: " "))")
                    Text("This screen continues by itself once the code is entered.")
                        .font(.callout).foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message)
                    Button("Try Again") { signIn?.start() }.tvPill()
                default:
                    ProgressView()
                }
            }
            .frame(maxWidth: 900, alignment: .leading)

            if case let .waiting(code) = signIn?.phase, let qr = code.qrCodeURL {
                VStack(spacing: 18) {
                    AsyncImage(url: qr) { image in
                        image.resizable().interpolation(.none).scaledToFit()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.08))
                    }
                    .frame(width: 420, height: 420)
                    .padding(24)
                    .background(.white, in: RoundedRectangle(cornerRadius: 32))
                    Text("Or scan with your phone").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(100)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvPageBackground()
        .task {
            let session = DeviceSignIn(appID: "9877") { [app] token in app.setToken(token, for: .putio) }
            signIn = session
            session.start()
        }
        .onDisappear { signIn?.cancel() }
    }
}
