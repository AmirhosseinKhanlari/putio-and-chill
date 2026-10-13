import AMDBCore
import AMDBKit
import SwiftUI

/// Settings that matter on the TV. Changes apply as you make them.
struct TVSettingsView: View {
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("fa", "Persian (فارسی)"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("ru", "Russian"), ("ar", "Arabic"), ("tr", "Turkish"),
        ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("hi", "Hindi"),
    ]

    @Environment(AppModel.self) private var app
    @State private var draft = AppSettings.defaults
    @State private var loaded = false
    @State private var username: String?
    @State private var mdblistKey = ""
    @State private var subtitlesKey = ""
    @State private var status: String?

    var body: some View {
        Form {
            Section("put.io") {
                LabeledContent("Signed in as", value: username ?? "…")
                Button("Sign Out", role: .destructive) { app.setToken(nil, for: .putio) }
            }

            Section {
                Picker("Subtitles", selection: $draft.subtitleLanguage) {
                    Text("Off").tag(String?.none)
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                }
                Picker("Audio language", selection: $draft.audioLanguage) {
                    Text("Original").tag(String?.none)
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                }
                NavigationLink("Subtitle Style") { SubtitleStyleEditor(style: $draft.subtitleStyle) }
            } header: {
                Text("Playback")
            } footer: {
                Text("While watching, swipe down on the remote for Subtitles: put.io's tracks and OpenSubtitles.")
            }

            Section("Library") {
                Toggle("Update automatically", isOn: $draft.libraryAutoUpdate)
                Button {
                    Task {
                        status = "Updating…"
                        await app.refreshLibraryIfDue(force: true)
                        status = app.library.lastError == nil ? "Up to date" : "Couldn't reach put.io"
                    }
                } label: {
                    LabeledContent("Update Now", value: status ?? app.library.lastUpdated.map {
                        RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now)
                    } ?? "Never")
                }
            }

            Section {
                LabeledContent("Ratings (MDBList)", value: app.hasRatings ? "Connected" : "Not connected")
                if app.hasRatings {
                    Button("Remove MDBList Key", role: .destructive) { app.setToken(nil, for: .mdblist) }
                } else {
                    TextField("MDBList API key", text: $mdblistKey)
                        .onSubmit {
                            let key = mdblistKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { if (try? await app.validateMDBList(key)) != nil { app.setToken(key, for: .mdblist); mdblistKey = "" } }
                        }
                }
                LabeledContent("OpenSubtitles", value: app.hasSubtitleSearch ? (app.usesBundledOpenSubtitles ? "Built in" : "Connected") : "Not connected")
                if !app.hasSubtitleSearch {
                    TextField("OpenSubtitles API key", text: $subtitlesKey)
                        .onSubmit { app.setToken(subtitlesKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .opensubtitles) }
                }
            } header: {
                Text("Services")
            } footer: {
                Text("Keys you added on your iPhone appear here by themselves when both devices use the same Apple Account with iCloud Keychain on.")
            }

            Section("Sources") {
                ForEach($draft.sources) { $source in Toggle(source.name, isOn: $source.enabled) }
            }
        }
        .frame(maxWidth: 1300)
        .frame(maxWidth: .infinity)
        .task {
            if !loaded { draft = app.settings; loaded = true }
            username = try? await app.putio?.accountInfo().username
        }
        .onChange(of: draft) { _, newValue in if loaded, newValue != app.settings { app.updateSettings(newValue) } }
    }
}
