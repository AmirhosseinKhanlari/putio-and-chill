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

    @State private var confirmSignOut = false
    @State private var imdbLink = ""
    @State private var imdbProblem: String?
    @State private var connectingIMDb = false

    var body: some View {
        NavigationStack {
            List {
                Section { accountCard }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                Section {
                    link("Playback", "play.rectangle.fill", .blue, value: draft.autoPlayNextEpisode ? "Auto-play on" : nil) { playbackPage }
                    link("Subtitles", "captions.bubble.fill", .orange, value: subtitlesSummary) { subtitlesPage }
                }
                Section {
                    link("Smart Get", "bolt.fill", .yellow, value: draft.oneTapGet ? smartGetSummary : "Off") { smartGetPage }
                    link("Sources", "antenna.radiowaves.left.and.right", .purple,
                         value: "\(draft.sources.filter(\.enabled).count) on") { sourcesPage }
                }
                Section {
                    link("Library", "square.stack.fill", .teal, value: draft.libraryAutoUpdate ? "Updates automatically" : "Manual") { libraryPage }
                    link("put.io Folders", "folder.fill", .cyan, value: draft.moviesFolder == nil && draft.tvFolder == nil ? "Default" : "Custom") { foldersPage }
                    link("Storage & Downloads", "externaldrive.fill", .gray, value: nil) { storagePage }
                }
                Section {
                    link("Connected Services", "link", .green, value: servicesSummary) { servicesPage }
                } footer: {
                    Text(versionLine).frame(maxWidth: .infinity).padding(.top, 18)
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
                await app.storage.refresh()
            }
            .alert("Sign out of put.io?", isPresented: $confirmSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) {
                    app.setToken(nil, for: .putio)
                    onboarded = false
                    dismiss()
                }
            } message: {
                Text("Your downloads on this device stay. Sign in again to keep using Putio & Chill.")
            }
            .sheet(isPresented: $showChill) { ChillConnectView() }
            .sheet(isPresented: $organizing) { OrganizeSheet(layout: FolderLayout(settings: draft)) }
        }
    }

    // MARK: Hub

    /// put.io account: who, how much space, sign out.
    private var accountCard: some View {
        let name = username ?? (app.putio == nil ? "Not connected" : "put.io")
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text(String(name.prefix(1)).uppercased())
                    .font(.title2.weight(.bold))
                    .frame(width: 56, height: 56)
                    .background(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.95), Color(red: 1, green: 0.45, blue: 0.3)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title3.weight(.semibold))
                    Text("put.io account").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if app.putio != nil {
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Text("Sign Out").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.poor)
                            .padding(.horizontal, 16).frame(height: 40)
                            .glassCapsule()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let disk = app.storage.disk {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.1))
                            Capsule().fill(disk.fractionUsed > 0.9 ? Theme.poor : Theme.good)
                                .frame(width: proxy.size.width * min(1, disk.fractionUsed))
                        }
                    }
                    .frame(height: 6)
                    Text("\(Format.bytes(disk.used)) of \(Format.bytes(disk.size)) used · \(Format.bytes(disk.avail)) free")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .glassRounded(22)
    }

    private func link<Destination: View>(_ title: String, _ symbol: String, _ color: Color, value: String?,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
                .scrollContentBackground(.hidden)
                .background(Theme.sheet)
                .tint(Theme.good)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                Spacer(minLength: 8)
                if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.vertical, 2)
        }
    }

    private var subtitlesSummary: String {
        guard let code = draft.subtitleLanguage else { return "Off" }
        return Self.languages.first { $0.code == code }?.name.components(separatedBy: " (").first ?? code
    }

    private var smartGetSummary: String {
        let quality = switch draft.smartGet.resolution { case 2160?: "4K"; case 720?: "720p"; default: "1080p" }
        return draft.smartGet.maxSizeGB.map { "\(quality) · ≤ \(Int($0)) GB" } ?? quality
    }

    private var servicesSummary: String {
        let count = [app.catalog != nil, app.hasRatings, app.hasChill, app.hasSubtitleSearch, app.imdbWatchlist.isConnected].filter { $0 }.count
        return "\(count) connected"
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "Putio & Chill \(version) (\(build))"
    }

    // MARK: Pages

    private var playbackPage: some View {
        Form {
            Section {
                Toggle("Auto-play when ready", isOn: $draft.autoPlayCountdown)
                Toggle("Auto-play next episode", isOn: $draft.autoPlayNextEpisode)
            } footer: {
                Text("When ready: a video you asked for starts as soon as put.io has it. Next episode: Netflix-style countdown at the end credits.")
            }
            Section {
                Picker("Audio language", selection: $draft.audioLanguage) {
                    Text("Original").tag(String?.none)
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                }
            }
        }
    }

    private var subtitlesPage: some View {
        Form {
            Section {
                Picker("Language", selection: $draft.subtitleLanguage) {
                    Text("Off").tag(String?.none)
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                }
                NavigationLink { SubtitleStyleEditor(style: $draft.subtitleStyle) } label: {
                    LabeledContent("Style", value: SubtitleSheet.summary(draft.subtitleStyle))
                }
            } footer: {
                Text("Subtitles turn on in this language when put.io has them. In the player, the subtitles button lists put.io's subtitles and searches OpenSubtitles.")
            }
            openSubtitlesSection
        }
    }

    private var smartGetPage: some View {
        Form {
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
            } footer: {
                Text("Get & Watch sends the release with the most seeders that matches. Versions is always one tap away.")
            }
            Section {
                Picker("Versions list shows", selection: $draft.defaultResolution) {
                    Text("All").tag(Int?.none)
                    Text("4K").tag(Int?.some(2160))
                    Text("1080p").tag(Int?.some(1080))
                    Text("720p").tag(Int?.some(720))
                }
            }
        }
    }

    private var sourcesPage: some View {
        Form {
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
            } footer: {
                Text("Sites move. If one stops answering, update its address here. chill needs a connected account.")
            }
        }
    }

    private var libraryPage: some View {
        Form {
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
            } footer: {
                Text("Your put.io library is saved on this device so the app opens instantly. With automatic updates on, it checks put.io at this interval while the app is open and now and then in the background, and tells you when something new arrives.")
            }
            Section {
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
            }
        }
    }

    private var foldersPage: some View {
        Form {
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
            } footer: {
                Text("New downloads go to \(FolderLayout(settings: draft).displayPath(kind: .movie, title: "", season: nil)) and \(FolderLayout(settings: draft).displayPath(kind: .tv, title: "Show", season: draft.seasonFolders ? 1 : nil)).")
            }
            Section {
                Button("Organize library…") { organizing = true }
                    .disabled(app.putio == nil || app.library.entries.isEmpty)
            } footer: {
                Text("Moves files you added elsewhere into these folders; you'll see the list first.")
            }
        }
    }

    private var storagePage: some View {
        Form {
            Section {
                Picker("Delete finished movies", selection: $draft.autoCleanDays) {
                    Text("Never").tag(Int?.none)
                    Text("After 7 days").tag(Int?.some(7))
                    Text("After 30 days").tag(Int?.some(30))
                    Text("After 90 days").tag(Int?.some(90))
                }
            } header: {
                Text("put.io")
            } footer: {
                Text("Only movies you watched to the end in Putio & Chill are deleted from put.io, never shows or unwatched files. You'll see the list before the first cleanup.")
            }
            Section {
                Toggle("Play downloads when available", isOn: $draft.preferDownloads)
                Toggle("Data saver downloads", isOn: $draft.downloadDataSaver)
            } header: {
                Text("This device")
            } footer: {
                Text("Data saver keeps offline downloads small (about 1 GB per hour).")
            }
        }
    }

    /// IMDb watchlist: paste a profile or watchlist link; the list must be public (read-only).
    private var imdbSection: some View {
        Section {
            if app.imdbWatchlist.isConnected {
                LabeledContent("IMDb Watchlist", value: app.imdbWatchlist.isLoading ? "Loading…"
                    : "\(app.imdbWatchlist.items.count) title\(app.imdbWatchlist.items.count == 1 ? "" : "s")")
                if let problem = app.imdbWatchlist.problem { Text(problem).font(.footnote).foregroundStyle(Theme.okay) }
                Button("Disconnect IMDb", role: .destructive) { app.disconnectIMDb() }
            } else {
                TextField("IMDb profile or watchlist link", text: $imdbLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    connectingIMDb = true
                    Task {
                        imdbProblem = await app.connectIMDb(imdbLink)
                        connectingIMDb = false
                        if imdbProblem == nil { imdbLink = "" }
                    }
                } label: {
                    HStack {
                        Text("Connect IMDb")
                        Spacer()
                        if connectingIMDb { ProgressView() }
                    }
                }
                .disabled(imdbLink.trimmingCharacters(in: .whitespaces).isEmpty || connectingIMDb)
                if let imdbProblem { Text(imdbProblem).font(.footnote).foregroundStyle(Theme.poor) }
            }
        } header: {
            Text("IMDb")
        } footer: {
            Text("Your IMDb watchlist shows on Home (here and on Apple TV). Paste the link to your IMDb profile or watchlist (IMDb app: You → Watchlist → Share). It must be public: on imdb.com open your Watchlist → Edit → Privacy → Public. The app only reads it.")
        }
    }

    private var servicesPage: some View {
        Form {
            Section {
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
            } header: {
                Text("Catalog")
            } footer: {
                Text("Titles, artwork, cast and recommendations.")
            }
            Section {
                LabeledContent("MDBList", value: app.hasRatings ? "Connected" : "Not connected")
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
            } header: {
                Text("Ratings")
            } footer: {
                Text("IMDb, Rotten Tomatoes, Metacritic and Letterboxd scores on title pages.")
            }
            imdbSection
            Section {
                LabeledContent("chill.institute", value: app.hasChill ? "Connected" : "Not connected")
                if app.hasChill {
                    Button("Disconnect chill", role: .destructive) { app.setToken(nil, for: .chill) }
                } else {
                    Button("Connect chill") { showChill = true }
                }
            } header: {
                Text("Releases")
            } footer: {
                Text("chill's release search and Latest lists.")
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
