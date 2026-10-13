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
                Button { router.play(entry, resumeFrom: 0) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.primaryPill)
                DownloadButton(entry: entry)
                versionsButton
            case let .resume(entry, seconds):
                Button { router.play(entry, resumeFrom: seconds) } label: {
                    Label("Resume \(Format.clock(seconds))", systemImage: "play.fill")
                }
                .buttonStyle(.primaryPill)
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
                    } label: { Label("Try another version", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.primaryPill)
                }
            }
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
        guard let query = model.query(season: season, episode: episode) else { return }
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
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: Double(transfer.percent) / 100, lineWidth: large ? 5 : 3,
                             tint: transfer.isStalled ? Theme.okay : .white)
                Text("\(transfer.percent)%").font((large ? Font.callout : .caption2).monospacedDigit().weight(.semibold))
            }
            .frame(width: large ? 64 : 34, height: large ? 64 : 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(large ? .headline : .caption.weight(.semibold))
                Text(details).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                if large {
                    Button("Cancel", role: .destructive) { Task { try? await app.transfers.cancel(transfer.id) } }
                        .font(.caption.weight(.semibold)).padding(.top, 2)
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

    @State private var finding = false

    var body: some View {
        switch model.action(season: season, episode: episode) {
        case .get:
            if finding {
                ProgressView().frame(width: 34, height: 34)
            } else {
                iconButton("arrow.down.circle", label: "Get episode") { Task { await get() } }
                    .contextMenu { Button("Choose a version…") { openVersions() } }
            }
        case let .play(entry):
            iconButton("play.circle.fill", label: "Play episode") { router.play(entry, resumeFrom: 0, next: next) }
        case let .resume(entry, seconds):
            iconButton("play.circle.fill", label: "Resume episode") { router.play(entry, resumeFrom: seconds, next: next) }
        case let .downloading(transfer):
            DownloadStatus(transfer: transfer).frame(width: 34)
        case .failed:
            iconButton("exclamationmark.arrow.circlepath", label: "Retry episode") { openVersions() }
        }
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
        Button(action: action) { Image(systemName: symbol).font(.system(size: 30, weight: .light)) }
            .buttonStyle(.lift)
            .accessibilityLabel(label)
    }

    private func openVersions() {
        guard let query = model.query(season: season, episode: episode) else { return }
        router.versions = VersionsRequest(query: query, target: model.target(season: season, episode: episode),
                                          playNow: app.library.matching(tmdbID: model.item.tmdbID, season: season, episode: episode))
    }
}
