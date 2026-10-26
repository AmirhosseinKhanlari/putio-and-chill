import AMDBCore
import AMDBKit
import SwiftUI

struct PrimaryActions: View {
    let model: TitleModel
    let season: Int?
    let episode: Int?
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var finding = false
    @State private var smartError: String?

    var body: some View {
        HStack(spacing: 10) {
            switch model.action(season: season, episode: episode) {
            case .get:
                Button { Task { await get() } } label: {
                    if finding {
                        HStack(spacing: 8) { ProgressView().controlSize(.small).tint(.black); Text("Finding the best version…") }
                    } else {
                        Label("Get & Watch", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.primaryPill)
                .disabled(finding)
                if app.settings.oneTapGet { versionsButton }
            case let .play(entry):
                Button { router.play(entry, resumeFrom: 0) } label: { playLabel("Play", entry: entry) }
                    .buttonStyle(.primaryPill)
                    .playSourceMenu(entry: entry, resumeFrom: 0)
                DownloadButton(entry: entry)
                versionsButton
            case let .resume(entry, seconds):
                Button { router.play(entry, resumeFrom: seconds) } label: {
                    playLabel("Resume \(Format.clock(seconds))", entry: entry)
                }
                .buttonStyle(.primaryPill)
                .playSourceMenu(entry: entry, resumeFrom: seconds)
                DownloadButton(entry: entry)
                versionsButton
            case let .downloading(transfer):
                DownloadStatus(transfer: transfer, large: true)
            case let .failed(transfer):
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure(transfer)).font(.footnote).foregroundStyle(Theme.poor)
                    Button {
                        app.transfers.dismiss(transfer.id)
                        openVersions()
                    } label: { Label("Choose Another Version", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.primaryPill)
                }
            }
        }
    }

    /// "Play" plus a small device icon when it will play the downloaded copy.
    @ViewBuilder private func playLabel(_ title: String, entry: LibraryEntry) -> some View {
        if app.settings.preferDownloads, app.downloads.finished.contains(where: { $0.fileID == entry.id }) {
            Label { Text(title) + Text("  ·  Downloaded").font(.caption.weight(.semibold)) } icon: { Image(systemName: "play.fill") }
        } else {
            Label(title, systemImage: "play.fill")
        }
    }

    /// One-tap Get: best release by the Smart Get rule; falls back to the Versions sheet when nothing fits.
    private func get() async {
        guard app.settings.oneTapGet, let query = model.query(season: season, episode: episode) else {
            openVersions()
            return
        }
        finding = true
        defer { finding = false }
        switch await app.smartGet(query, target: model.target(season: season, episode: episode)) {
        case .sent: break
        case .noMatch: openVersions()
        case let .failed(error):
            smartError = String(describing: error)
            openVersions()
        }
    }

    private var versionsButton: some View {
        Button { openVersions() } label: { Label("Versions", systemImage: "square.stack.3d.up") }
            .buttonStyle(.glassPill)
    }

    private func openVersions() {
        guard let query = model.query(season: season, episode: episode) else {
            router.toast = model.queryUnavailableMessage
            return
        }
        router.versions = VersionsRequest(query: query, target: model.target(season: season, episode: episode),
                                          playNow: app.library.matching(tmdbID: model.item.tmdbID, season: season, episode: episode))
    }

    private func failure(_ transfer: TrackedTransfer) -> String {
        if case let .failed(message) = transfer.phase { return message }
        return "Transfer failed"
    }
}

struct DownloadStatus: View {
    let transfer: TrackedTransfer
    var large = false
    /// Just the ring, for tight rows (the episode list).
    var ringOnly = false
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: Double(transfer.percent) / 100, lineWidth: large ? 5 : 3,
                             tint: transfer.isStalled ? Theme.okay : .white)
                Text("\(transfer.percent)%").font((large ? Font.callout : .caption2).monospacedDigit().weight(.semibold))
            }
            .frame(width: large ? 64 : 34, height: large ? 64 : 34)
            .accessibilityLabel(ringOnly ? "\(headline), \(transfer.percent)%" : "\(transfer.percent)%")
            if !ringOnly {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(large ? .headline : .caption.weight(.semibold)).lineLimit(1).fixedSize(horizontal: large, vertical: false)
                    Text(details).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                    if large {
                        Button("Cancel", role: .destructive) { Task { try? await app.transfers.cancel(transfer.id) } }
                            .font(.caption.weight(.semibold)).padding(.top, 2)
                    }
                }
            }
        }
    }

    private var headline: String {
        switch transfer.phase {
        case .queued: "Queued"
        case .finishing: "Finishing up"
        case .completed: "Preparing"
        default: transfer.isStalled ? "Stalled: no peers" : "Downloading"
        }
    }

    private var details: String {
        guard let live = transfer.transfer else { return "Starting…" }
        let parts = [Format.speed(live.downSpeed), live.peersConnected.map { "\($0) peers" }, Format.eta(live.estimatedTime)]
        let joined = parts.compactMap { $0 }.joined(separator: " · ")
        return transfer.isStalled ? "Try another version if this doesn't move." : (joined.isEmpty ? "Working…" : joined)
    }
}

struct EpisodeActionButton: View {
    let model: TitleModel
    let season: Int
    let episode: Int
    let next: NextEpisode?
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(OfflineDownloader.self) private var downloader
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var finding = false

    /// iPhone rows are narrow: Download moves into the ⋯ menu (its state shows on the episode image instead).
    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        let action = model.action(season: season, episode: episode)
        HStack(spacing: compact ? 4 : 10) {
            switch action {
            case .get:
                if finding {
                    ProgressView().frame(width: 34, height: 34)
                } else {
                    iconButton("icloud.and.arrow.down", label: "Get episode") { Task { await get() } }
                }
            case let .play(entry):
                if !compact { DownloadButton(entry: entry, plain: true) }
                iconButton("play.circle.fill", label: "Play episode") { router.play(entry, resumeFrom: 0, next: next) }
                    .playSourceMenu(entry: entry, resumeFrom: 0, next: next)
            case let .resume(entry, seconds):
                if !compact { DownloadButton(entry: entry, plain: true) }
                iconButton("play.circle.fill", label: "Resume episode") { router.play(entry, resumeFrom: seconds, next: next) }
                    .playSourceMenu(entry: entry, resumeFrom: seconds, next: next)
            case let .downloading(transfer):
                DownloadStatus(transfer: transfer, ringOnly: true)
            case .failed:
                iconButton("exclamationmark.arrow.circlepath", label: "Retry episode") { openVersions() }
            }
            moreMenu(action)
        }
    }

    /// Everything for one episode, including picking a different release (another quality, size or source).
    private func moreMenu(_ action: TitleAction) -> some View {
        Menu {
            switch action {
            case let .play(entry):
                playItems(entry, resumeFrom: 0)
            case let .resume(entry, seconds):
                playItems(entry, resumeFrom: seconds)
                Button { router.play(entry, resumeFrom: 0, next: next, exactStart: true) } label: { Label("Start Over", systemImage: "backward.end") }
            case .get:
                Button { Task { await get() } } label: { Label("Get Episode", systemImage: "icloud.and.arrow.down") }
            case let .downloading(transfer):
                Button(role: .destructive) { Task { try? await app.transfers.cancel(transfer.id) } } label: {
                    Label("Cancel Download", systemImage: "xmark")
                }
            case .failed:
                EmptyView()
            }
            Divider()
            Button { openVersions() } label: {
                Label(owned.isEmpty ? "Choose a Version…" : "Choose Another Version…", systemImage: "square.stack.3d.up")
            }
            if owned.count > 1 {
                Section("In put.io") {
                    ForEach(owned) { entry in
                        Button { router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry), next: next) } label: {
                            Label(Self.versionLabel(entry), systemImage: "play")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: compact ? 22 : 26, weight: .light))
                .frame(width: compact ? 30 : 34, height: 34)
        }
        .accessibilityLabel("More for episode \(episode)")
    }

    @ViewBuilder private func playItems(_ entry: LibraryEntry, resumeFrom: Int) -> some View {
        if app.downloads.finished.contains(where: { $0.fileID == entry.id }) {
            Button { router.play(entry, resumeFrom: resumeFrom, next: next, source: .device) } label: {
                Label("Play from This Device", systemImage: "arrow.down.circle")
            }
        }
        Button { router.play(entry, resumeFrom: resumeFrom, next: next, source: .stream) } label: {
            Label("Stream from put.io", systemImage: "icloud")
        }
        if compact { downloadItem(entry) }
    }

    @ViewBuilder private func downloadItem(_ entry: LibraryEntry) -> some View {
        switch app.downloads.record(fileID: entry.id)?.state {
        case .done?:
            Button(role: .destructive) { Task { await downloader.remove(fileID: entry.id) } } label: {
                Label("Remove Download", systemImage: "trash")
            }
        case .downloading?, .queued?:
            Button(role: .destructive) { Task { await downloader.cancel(fileID: entry.id) } } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        default:
            Button { Task { await downloader.start(entry) } } label: {
                Label("Download to This Device", systemImage: "arrow.down.to.line")
            }
            .disabled(!OfflineDownloader.isSupported)
        }
    }

    private var owned: [LibraryEntry] {
        app.library.matching(tmdbID: model.item.tmdbID, season: season, episode: episode)
    }

    /// "1080p · 2.1 GB" from the file name and size, else the file name.
    static func versionLabel(_ entry: LibraryEntry) -> String {
        let resolution = ReleaseNameParser.parse(entry.file.name).resolution
        let parts = [resolution == .unknown ? nil : resolution.label, entry.file.size.map { Format.bytes($0) }].compactMap { $0 }
        return parts.isEmpty ? entry.file.name : parts.joined(separator: " · ")
    }

    private func get() async {
        guard app.settings.oneTapGet, let query = model.query(season: season, episode: episode) else {
            openVersions()
            return
        }
        finding = true
        defer { finding = false }
        switch await app.smartGet(query, target: model.target(season: season, episode: episode)) {
        case .sent: break
        case .noMatch, .failed: openVersions()
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: compact ? 26 : 30, weight: .light)) }
            .buttonStyle(.lift)
            .accessibilityLabel(label)
    }

    private func openVersions() {
        guard let query = model.query(season: season, episode: episode) else {
            router.toast = model.queryUnavailableMessage
            return
        }
        router.versions = VersionsRequest(query: query, target: model.target(season: season, episode: episode),
                                          playNow: app.library.matching(tmdbID: model.item.tmdbID, season: season, episode: episode))
    }
}

/// Long-press on Play: choose the downloaded copy or streaming, whatever the default is.
private struct PlaySourceMenu: ViewModifier {
    let entry: LibraryEntry
    let resumeFrom: Int
    let next: NextEpisode?
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        let downloaded = app.downloads.finished.contains { $0.fileID == entry.id }
        content.contextMenu {
            if downloaded {
                Button { router.play(entry, resumeFrom: resumeFrom, next: next, source: .device) } label: {
                    Label("Play from This Device", systemImage: "arrow.down.circle")
                }
            }
            Button { router.play(entry, resumeFrom: resumeFrom, next: next, source: .stream) } label: {
                Label("Stream from put.io", systemImage: "icloud")
            }
            if resumeFrom > 0 {
                Button { router.play(entry, resumeFrom: 0, next: next, exactStart: true) } label: { Label("Start Over", systemImage: "backward.end") }
            }
        }
    }
}

extension View {
    func playSourceMenu(entry: LibraryEntry, resumeFrom: Int, next: NextEpisode? = nil) -> some View {
        modifier(PlaySourceMenu(entry: entry, resumeFrom: resumeFrom, next: next))
    }
}
