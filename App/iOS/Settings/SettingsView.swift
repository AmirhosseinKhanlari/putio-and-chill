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
                    LabeledContent("TMDB", value: app.catalog == nil ? "Not connected" : "Connected")
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
