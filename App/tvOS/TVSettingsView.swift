import AMDBCore
import AMDBKit
import SwiftUI

/// Everything the iPhone app's Settings has, laid out for the remote. Changes apply as you make them.
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
    @State private var subtitlesUser = ""
    @State private var subtitlesPassword = ""
    @State private var subtitlesStatus: String?
    @State private var signingIn = false
    @State private var libraryStatus: String?

    var body: some View {
        Form {
            Section("put.io") {
                LabeledContent("Signed in as", value: username ?? "…")
                Button("Sign Out", role: .destructive) { app.setToken(nil, for: .putio) }
            }

            Section {
                Toggle("Auto-play when ready", isOn: $draft.autoPlayCountdown)
                Toggle("Auto-play next episode", isOn: $draft.autoPlayNextEpisode)
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
                Text("While watching, swipe down on the remote for Subtitles: put.io's tracks and OpenSubtitles, with timing.")
            }

            openSubtitles

            Section {
                Toggle("One-click Get", isOn: $draft.oneTapGet)
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
                Text("Get & Watch sends the release with the most seeders that matches. Versions is always one click away.")
            }

            Section {
                NavigationLink {
                    TVFolderPicker(title: "Movies Folder", defaultPath: "AMDB/Movies", selection: $draft.moviesFolder)
                } label: {
                    LabeledContent("Movies", value: draft.moviesFolder?.path ?? "AMDB/Movies")
                }
                NavigationLink {
                    TVFolderPicker(title: "TV Folder", defaultPath: "AMDB/TV", selection: $draft.tvFolder)
                } label: {
                    LabeledContent("TV shows", value: draft.tvFolder?.path ?? "AMDB/TV")
                }
                Toggle("Season folders", isOn: $draft.seasonFolders)
                NavigationLink("Organize Library…") { TVOrganizeView() }
                    .disabled(app.library.entries.isEmpty)
            } header: {
                Text("put.io Folders")
            } footer: {
                Text("New downloads go to \(FolderLayout(settings: draft).displayPath(kind: .movie, title: "", season: nil)) and \(FolderLayout(settings: draft).displayPath(kind: .tv, title: "Show", season: draft.seasonFolders ? 1 : nil)). Organize moves files you added elsewhere into these folders; you'll see the list first.")
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
                        libraryStatus = app.library.lastError != nil ? "Couldn't reach put.io"
                            : difference > 0 ? "Updated · \(difference) new" : "Up to date"
                    }
                } label: {
                    LabeledContent("Update Now", value: libraryStatus ?? app.library.lastUpdated.map {
                        RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now)
                    } ?? "Never")
                }
                .disabled(app.library.isRefreshing)
                Picker("Delete finished movies", selection: $draft.autoCleanDays) {
                    Text("Never").tag(Int?.none)
                    Text("After 7 days").tag(Int?.some(7))
                    Text("After 30 days").tag(Int?.some(30))
                    Text("After 90 days").tag(Int?.some(90))
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Your put.io library is saved on this Apple TV so the app opens instantly. Only movies you watched to the end in AMDB are offered for deletion, never shows or unwatched files; Library → Clean Up asks first.")
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
            } header: {
                Text("Ratings")
            } footer: {
                Text("Keys you added on your iPhone appear here by themselves when both devices use the same Apple Account with iCloud Keychain on.")
            }

            Section("Sources") {
                ForEach($draft.sources) { $source in Toggle(source.name, isOn: $source.enabled) }
            }
        }
        .frame(maxWidth: 1300)
        .frame(maxWidth: .infinity)
        .tvPageBackground()
        .task {
            if !loaded { draft = app.settings; loaded = true }
            username = try? await app.putio?.accountInfo().username
        }
        .onChange(of: draft) { _, newValue in if loaded, newValue != app.settings { app.updateSettings(newValue) } }
    }

    private var openSubtitles: some View {
        Section {
            LabeledContent("Search", value: app.hasSubtitleSearch ? (app.usesBundledOpenSubtitles ? "Built in" : "Connected") : "Not connected")
            if !app.usesBundledOpenSubtitles {
                if app.token(.opensubtitles) != nil {
                    Button("Remove OpenSubtitles API Key", role: .destructive) { app.setToken(nil, for: .opensubtitles) }
                } else {
                    TextField("OpenSubtitles API key", text: $subtitlesKey)
                        .onSubmit { app.setToken(subtitlesKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .opensubtitles); subtitlesKey = "" }
                }
            }
            if let user = app.openSubtitlesUser {
                LabeledContent("Account", value: app.openSubtitlesAccount?.isVIP == true ? "\(user) · VIP" : user)
                Button("Sign Out of OpenSubtitles", role: .destructive) { app.signOutOfOpenSubtitles(); subtitlesStatus = nil }
            } else if app.hasSubtitleSearch {
                TextField("OpenSubtitles username", text: $subtitlesUser)
                    .textContentType(.username).autocorrectionDisabled()
                SecureField("Password", text: $subtitlesPassword).textContentType(.password)
                Button(signingIn ? "Signing In…" : "Sign In") { Task { await signIn() } }
                    .disabled(subtitlesUser.isEmpty || subtitlesPassword.isEmpty || signingIn)
            }
            if let subtitlesStatus { Text(subtitlesStatus).foregroundStyle(.secondary) }
        } header: {
            Text("OpenSubtitles")
        } footer: {
            Text("Used when put.io's subtitles are missing or out of sync. Without an account you get a few downloads a day; a free account gives 20, VIP about 1,000.")
        }
    }

    private func signIn() async {
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
}

/// Browse put.io folders with the remote and pick one. nil means the default AMDB folder.
struct TVFolderPicker: View {
    let title: String
    let defaultPath: String
    @Binding var selection: PutioFolderRef?
    var folderID: Int64 = 0
    var path: [String] = []
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [PutioFile]?
    @State private var failed = false

    var body: some View {
        List {
            if path.isEmpty {
                Button { selection = nil; dismiss() } label: {
                    HStack {
                        LabeledContent("Default", value: defaultPath)
                        if selection == nil { Image(systemName: "checkmark") }
                    }
                }
            } else {
                Button {
                    selection = PutioFolderRef(id: folderID, path: path.joined(separator: "/"))
                    dismiss()
                } label: {
                    Label("Use \u{201C}\(path.joined(separator: "/"))\u{201D}", systemImage: "checkmark.circle")
                }
            }
            Section(path.isEmpty ? "Your put.io" : path.joined(separator: "/")) {
                if let folders {
                    if folders.isEmpty { Text("No folders here").foregroundStyle(.secondary) }
                    ForEach(folders) { folder in
                        NavigationLink {
                            TVFolderPicker(title: folder.name, defaultPath: defaultPath, selection: $selection,
                                           folderID: folder.id, path: path + [folder.name])
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                Spacer()
                                if selection?.id == folder.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } else if failed {
                    Text("Couldn't load folders from put.io.")
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle(path.last ?? title)
        .frame(maxWidth: 1300)
        .frame(maxWidth: .infinity)
        .task {
            guard folders == nil, let putio = app.putio else { return }
            do {
                folders = try await putio.listFiles(parentID: folderID).files.filter(\.isFolder)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } catch {
                failed = true
            }
        }
    }
}
