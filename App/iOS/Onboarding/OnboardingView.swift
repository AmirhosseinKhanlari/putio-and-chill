import AMDBCore
import AMDBKit
import AuthenticationServices
import SwiftUI

enum PutioConfig {
    static let clientID = "9877"
    static let redirectURI = "amdb://oauth/putio"
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @AppStorage("amdb.onboarded") private var onboarded = false
    @State private var putioPaste = ""
    @State private var tmdbToken = ""
    @State private var mdblistKey = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Putio & Chill").font(.system(size: 44, weight: .ultraLight)).tracking(3)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("Find it. Send it to put.io. Watch it.").foregroundStyle(.white.opacity(0.7))
                }
                .padding(.bottom, 12)

                StepCard(number: 1, title: "Connect put.io", done: app.putio != nil) {
                    Button { Task { await connectPutio() } } label: { Label("Sign in with put.io", systemImage: "person.badge.key.fill") }
                        .buttonStyle(.primaryPill)
                    DisclosureGroup("Paste a token instead") {
                        HStack {
                            SecureField("put.io OAuth token", text: $putioPaste).textFieldStyle(.roundedBorder)
                            Button("Save") { app.setToken(putioPaste.trimmingCharacters(in: .whitespaces), for: .putio) }
                                .disabled(putioPaste.isEmpty)
                        }
                    }
                    .font(.footnote)
                }

                if !app.usesBundledTMDB {
                StepCard(number: 2, title: "Add your TMDB token", done: app.catalog != nil) {
                    Text("Free: themoviedb.org → Settings → API → **API Read Access Token**.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    HStack {
                        SecureField("eyJhbGciOi…", text: $tmdbToken).textFieldStyle(.roundedBorder)
                        Button { Task { await saveTMDB() } } label: { busy ? AnyView(ProgressView()) : AnyView(Text("Verify")) }
                            .buttonStyle(.glassPill)
                            .disabled(tmdbToken.isEmpty || busy)
                    }
                }

                }

                if !app.usesBundledMDBList {
                    StepCard(number: app.usesBundledTMDB ? 2 : 3, title: "IMDb & Rotten Tomatoes scores (optional)", done: app.hasRatings) {
                        Text("Free key: mdblist.com → sign in → Preferences → **API key**.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.7))
                        HStack {
                            SecureField("MDBList API key", text: $mdblistKey).textFieldStyle(.roundedBorder)
                            Button { Task { await saveMDBList() } } label: { busy ? AnyView(ProgressView()) : AnyView(Text("Verify")) }
                                .buttonStyle(.glassPill)
                                .disabled(mdblistKey.isEmpty || busy)
                        }
                    }
                }

                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(Theme.poor)
                }

                Button {
                    Notifier.requestAuthorization()
                    onboarded = true
                } label: {
                    Text("Start watching").frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryPill)
                .disabled(!app.isReady)
                .opacity(app.isReady ? 1 : 0.4)
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .ambientBackground()
    }

    private func connectPutio() async {
        errorText = nil
        do {
            let callback = try await webAuthenticationSession.authenticate(
                using: PutioClient.authorizeURL(clientID: PutioConfig.clientID, redirectURI: PutioConfig.redirectURI),
                callbackURLScheme: "amdb")
            guard let token = PutioClient.token(fromCallback: callback) else {
                errorText = "put.io didn't send a token back. Try again."
                return
            }
            app.setToken(token, for: .putio)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveMDBList() async {
        busy = true
        defer { busy = false }
        let key = mdblistKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await app.validateMDBList(key)
            app.setToken(key, for: .mdblist)
            errorText = nil
        } catch {
            errorText = "MDBList rejected that key. Copy it from mdblist.com → Preferences."
        }
    }

    private func saveTMDB() async {
        busy = true
        defer { busy = false }
        let token = tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await app.validateTMDB(token)
            app.setToken(token, for: .tmdb)
            errorText = nil
        } catch {
            errorText = "TMDB rejected that token. Copy the long “API Read Access Token”, not the short API key."
        }
    }
}

private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(done ? Theme.good : .white.opacity(0.15)).frame(width: 28, height: 28)
                    if done { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black) } else { Text("\(number)").font(.caption.bold()) }
                }
                Text(title).font(.headline)
            }
            if !done { content }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRounded()
    }
}
