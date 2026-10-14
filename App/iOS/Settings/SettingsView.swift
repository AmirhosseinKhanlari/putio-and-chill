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
    @State private var subtitlesKeyDraft = ""
    @State private var subtitlesUser = ""
    @State private var subtitlesPassword = ""
    @State private var subtitlesStatus: String?
    @State private var signingIn = false
    @State private var libraryStatus: String?
    @State private var organizing = false

    private var openSubtitlesSection: some View {
        Section {
            LabeledContent("Search", value: app.hasSubtitleSearch ? (app.usesBundledOpenSubtitles ? "Built in" : "Connected") : "Not connected")
            if !app.usesBundledOpenSubtitles {
                if app.token(.opensubtitles) != nil {
                    Button("Remove OpenSubtitles API key", role: .destructive) { app.setToken(nil, for: .opensubtitles) }
                } else {
                    HStack {
                        SecureField("OpenSubtitles API key", text: $subtitlesKeyDraft)
                        Button("Save") {
                            app.setToken(subtitlesKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines), for: .opensubtitles)
                            subtitlesKeyDraft = ""
                        }
                        .disabled(subtitlesKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            if let user = app.openSubtitlesUser {
                LabeledContent("Account", value: app.openSubtitlesAccount?.isVIP == true ? "\(user) · VIP" : user)
                Button("Sign out of OpenSubtitles", role: .destructive) { app.signOutOfOpenSubtitles(); subtitlesStatus = nil }
            } else if app.hasSubtitleSearch {
                TextField("OpenSubtitles username", text: $subtitlesUser)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $subtitlesPassword).textContentType(.password)
                Button {
                    Task { await signInToOpenSubtitles() }
                } label: {
                    if signingIn { ProgressView() } else { Text("Sign in") }
                }
                .disabled(subtitlesUser.isEmpty || subtitlesPassword.isEmpty || signingIn)
            }
            if let subtitlesStatus { Text(subtitlesStatus).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("OpenSubtitles")
        } footer: {
            Text("In the player, the subtitles button searches OpenSubtitles when put.io's subtitles are missing or out of sync. "
                 + "Without an account you get a few downloads a day; a free account gives 20, OpenSubtitles VIP about 1,000. "
                 + (app.usesBundledOpenSubtitles ? "" : "Get an API key at opensubtitles.com → API consumers."))
        }
    }

    private func signInToOpenSubtitles() async {
        signingIn = true
        defer { signingIn = false }
        do {
            let login = try await app.signInToOpenSubtitles(username: subtitlesUser.trimmingCharacters(in: .whitespaces),
                                                            password: subtitlesPassword)
            subtitlesPassword = ""
            let level = login.isVIP ? "VIP" : "Free account"
            subtitlesStatus = login.allowedDownloads.map { "Signed in (\(level)). \($0) downloads a day." } ?? "Signed in (\(level))."
        } catch OpenSubtitlesError.badCredentials {
            subtitlesStatus = "Wrong username or password."
        } catch {
            subtitlesStatus = "Couldn't reach OpenSubtitles. Try again."
        }
    }

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
                    NavigationLink { SubtitleStyleEditor(style: $draft.subtitleStyle) } label: {
                        LabeledContent("Subtitle style", value: SubtitleSheet.summary(draft.subtitleStyle))
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Subtitles turn on in this language when put.io has them. In the player, the subtitles button lists put.io's subtitles and searches OpenSubtitles.")
                }

                openSubtitlesSection

                Section {
                    Picker("Delete finished movies", selection: $draft.autoCleanDays) {
                        Text("Never").tag(Int?.none)
                        Text("After 7 days").tag(Int?.some(7))
                        Text("After 30 days").tag(Int?.some(30))
                        Text("After 90 days").tag(Int?.some(90))
                    }
                    Toggle("Data saver downloads", isOn: $draft.downloadDataSaver)
                    Toggle("Play downloads when available", isOn: $draft.preferDownloads)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Only movies you watched to the end in AMDB are deleted from put.io, never shows or unwatched files. You'll see the list before the first cleanup. Data saver keeps offline downloads small (about 1 GB per hour).")
                }

                Section {
                    NavigationLink {
                        PutioFolderPicker(title: "Movies Folder", defaultPath: "AMDB/Movies", selection: $draft.moviesFolder)
                    } label: {
                        LabeledContent("Movies", value: draft.moviesFolder?.path ?? "AMDB/Movies")
                    }
                    NavigationLink {
                        PutioFolderPicker(title: "TV Folder", defaultPath: "AMDB/TV", selection: $draft.tvFolder)
                    } label: {
                        LabeledContent("TV shows", value: draft.tvFolder?.path ?? "AMDB/TV")
                    }
                    Toggle("Season folders", isOn: $draft.seasonFolders)
                    Button("Organize library…") { organizing = true }
                        .disabled(app.putio == nil || app.library.entries.isEmpty)
                } header: {
                    Text("put.io Folders")
                } footer: {
                    Text("New downloads go to \(FolderLayout(settings: draft).displayPath(kind: .movie, title: "", season: nil)) and \(FolderLayout(settings: draft).displayPath(kind: .tv, title: "Show", season: draft.seasonFolders ? 1 : nil)). Organize library moves files you added elsewhere into these folders; you'll see the list first.")
                }

                Section {
                    Toggle("Update automatically", isOn: $draft.libraryAutoUpdate)
                    if draft.libraryAutoUpdate {
                        Picker("Check put.io every", selection: $draft.libraryUpdateMinutes) {
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                            Text("Hour").tag(60)
                            Text("6 hours").tag(360)
                            Text("Day").tag(1440)
                        }
                    }
                    Button {
                        Task {
                            libraryStatus = "Updating…"
                            let before = app.library.entries.count
                            await app.refreshLibraryIfDue(force: true)
                            let difference = app.library.entries.count - before
                            libraryStatus = app.library.lastError != nil ? "Couldn't reach put.io."
                                : difference > 0 ? "Updated · \(difference) new" : "Up to date"
                        }
                    } label: {
                        HStack {
                            Text("Update now")
                            Spacer()
                            if app.library.isRefreshing { ProgressView() }
                        }
                    }
                    .disabled(app.library.isRefreshing || app.putio == nil)
                    LabeledContent("Last updated", value: libraryStatus ?? app.library.lastUpdated
                        .map { LibraryFreshness.relative($0, now: .now).capitalizedFirst } ?? "Never")
                } header: {
                    Text("Library")
                } footer: {
                    Text("Your put.io library is saved on this device so the app opens instantly. With automatic updates on, it checks put.io at this interval while the app is open and now and then in the background, and tells you when something new arrives.")
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
            .sheet(isPresented: $organizing) { OrganizeSheet(layout: FolderLayout(settings: draft)) }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
