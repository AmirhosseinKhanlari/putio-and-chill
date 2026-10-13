import AMDBCore
import AMDBKit
import SwiftUI

struct SettingsView: View {
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

                Section("Playback") {
                    Picker("Default quality", selection: $draft.defaultResolution) {
                        Text("All").tag(Int?.none)
                        Text("4K").tag(Int?.some(2160))
                        Text("1080p").tag(Int?.some(1080))
                        Text("720p").tag(Int?.some(720))
                    }
                    Toggle("Auto-play when ready", isOn: $draft.autoPlayCountdown)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sheet)
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
