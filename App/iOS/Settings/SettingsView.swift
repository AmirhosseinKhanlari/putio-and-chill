import AMDBCore
import AMDBKit
import SwiftUI

struct SettingsView: View {
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("fa", "Persian (فارسی)"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("ru", "Russian"), ("ar", "Arabic"), ("tr", "Turkish"),
        ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("hi", "Hindi"),
    ]

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("amdb.onboarded") private var onboarded = false
    @State private var username: String?
    @State private var draft = AppSettings.defaults
    @State private var showChill = false
    @State private var tmdbDraft = ""
    @State private var mdblistDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts") {
                    LabeledContent("put.io", value: username ?? (app.putio == nil ? "Not connected" : "Connected"))
                    Button("Sign out of put.io", role: .destructive) {
                        app.setToken(nil, for: .putio)
                        onboarded = false
                        dismiss()
                    }
                    LabeledContent("TMDB", value: app.usesBundledTMDB ? "Built in" : (app.catalog == nil ? "Not connected" : "Connected"))
                    if !app.usesBundledTMDB {
                    HStack {
                        SecureField("Replace TMDB token", text: $tmdbDraft)
                        Button("Save") {
                            Task {
                                let token = tmdbDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                if (try? await app.validateTMDB(token)) != nil { app.setToken(token, for: .tmdb); tmdbDraft = "" }
                            }
                        }
                        .disabled(tmdbDraft.isEmpty)
                    }
                    }
                    LabeledContent("Ratings (MDBList)", value: app.hasRatings ? "Connected" : "Not connected")
                    if app.hasRatings {
                        Button("Remove MDBList key", role: .destructive) { app.setToken(nil, for: .mdblist) }
                    } else {
                        HStack {
                            SecureField("MDBList API key", text: $mdblistDraft)
                            Button("Save") {
                                Task {
                                    let key = mdblistDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if (try? await app.validateMDBList(key)) != nil { app.setToken(key, for: .mdblist); mdblistDraft = "" }
                                }
                            }
                            .disabled(mdblistDraft.isEmpty)
                        }
                    }
                    if app.hasChill {
                        Button("Disconnect chill", role: .destructive) { app.setToken(nil, for: .chill) }
                    } else {
                        Button("Connect chill") { showChill = true }
                    }
                }

                Section {
                    ForEach($draft.sources) { $source in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(source.name, isOn: $source.enabled)
                            TextField("Base URL", text: $source.baseURL)
                                .font(.caption.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Sites move. If one stops answering, update its address here. chill needs a connected account.")
                }

                Section {
                    Toggle("Auto-play when ready", isOn: $draft.autoPlayCountdown)
                    Toggle("Auto-play next episode", isOn: $draft.autoPlayNextEpisode)
                    Picker("Audio language", selection: $draft.audioLanguage) {
                        Text("Original").tag(String?.none)
                        ForEach(Self.languages, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                    }
                    Picker("Subtitles", selection: $draft.subtitleLanguage) {
                        Text("Off").tag(String?.none)
                        ForEach(Self.languages, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Subtitles come from put.io. Choose which languages put.io fetches in put.io → Settings → Subtitles.")
                }

                Section {
                    Toggle("One-tap Get", isOn: $draft.oneTapGet)
                    Picker("Quality", selection: $draft.smartGet.resolution) {
                        Text("4K").tag(Int?.some(2160))
                        Text("1080p").tag(Int?.some(1080))
                        Text("720p").tag(Int?.some(720))
                    }
                    .disabled(!draft.oneTapGet)
                    Picker("Max size", selection: $draft.smartGet.maxSizeGB) {
                        Text("5 GB").tag(Double?.some(5))
                        Text("10 GB").tag(Double?.some(10))
                        Text("20 GB").tag(Double?.some(20))
                        Text("40 GB").tag(Double?.some(40))
                        Text("No limit").tag(Double?.none)
                    }
                    .disabled(!draft.oneTapGet)
                    Picker("Versions list shows", selection: $draft.defaultResolution) {
                        Text("All").tag(Int?.none)
                        Text("4K").tag(Int?.some(2160))
                        Text("1080p").tag(Int?.some(1080))
                        Text("720p").tag(Int?.some(720))
                    }
                } header: {
                    Text("Smart Get")
                } footer: {
                    Text("Get & Watch sends the release with the most seeders that matches. Versions is always one tap away.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sheet)
            .tint(Theme.good)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        app.updateSettings(draft)
                        dismiss()
                    }
                }
            }
            .task {
                draft = app.settings
                username = try? await app.putio?.accountInfo().username
            }
            .sheet(isPresented: $showChill) { ChillConnectView() }
        }
    }
}
