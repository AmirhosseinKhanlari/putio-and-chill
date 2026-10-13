import AMDBCore
import AMDBKit
import AVKit
import SwiftUI

struct PlayerScreen: View {
    let request: PlayerRequest
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var session: PlaybackSession?
    @State private var askingResume = false
    @State private var ready = false
    @State private var remaining = Double.infinity
    @State private var failure: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayerController(player: player).ignoresSafeArea()
            if !ready && failure == nil && !askingResume {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Preparing…").font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
            }
            if askingResume {
                VStack(spacing: 14) {
                    Text(request.title).font(.headline)
                    Button { begin(at: Double(request.resumeFrom)) } label: {
                        Label("Resume from \(Format.clock(request.resumeFrom))", systemImage: "play.fill")
                    }
                    .buttonStyle(.primaryPill)
                    Button("Start over") { begin(at: 0) }.buttonStyle(.glassPill)
                }
                .padding(28)
                .glassRounded(24)
            }
            if let failure {
                VStack(spacing: 14) {
                    Text(failure).multilineTextAlignment(.center)
                    Link("Open in put.io", destination: URL(string: "https://app.put.io/files/\(request.file.id)")!)
                        .buttonStyle(.glassPill)
                }
                .padding(28)
                .glassRounded(24)
                .padding(40)
            }
            if let next = request.next, remaining < 30 {
                Button { advance(to: next) } label: { Label("Next: \(next.label)", systemImage: "forward.end.fill") }
                    .buttonStyle(.primaryPill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 40).padding(.bottom, 110)
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40).glassCapsule()
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Close player")
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await setUp() }
        .task { await trackProgress() }
        .onDisappear { finish() }
    }

    private func setUp() async {
        guard let putio = app.putio else { return }
        let playback = PlaybackSession(fileID: request.file.id, resumeFrom: request.resumeFrom, putio: putio, library: app.library)
        session = playback
        if let played = request.played { await app.notePlayed(played) }
        player.replaceCurrentItem(with: AVPlayerItem(url: playback.streamURL))
        if playback.shouldOfferResume { askingResume = true } else { begin(at: 0) }

        for _ in 0..<60 {
            switch player.currentItem?.status {
            case .readyToPlay:
                ready = true
                return
            case .failed:
                break
            default:
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            break
        }
        if request.file.contentType == "video/mp4", let original = try? await putio.originalURL(fileID: request.file.id) {
            player.replaceCurrentItem(with: AVPlayerItem(url: original))
            if !askingResume { begin(at: Double(request.resumeFrom)) }
            ready = true
        } else {
            failure = "put.io couldn't stream this file yet. It may still be converting. Try again in a few minutes."
        }
    }

    private func begin(at seconds: Double) {
        askingResume = false
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        player.play()
    }

    private func trackProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let position = player.currentTime().seconds
            guard position.isFinite, position > 0 else { continue }
            let duration = player.currentItem?.duration.seconds ?? 0
            let total = duration.isFinite ? duration : 0
            remaining = total > 0 ? total - position : .infinity
            await session?.tick(seconds: position, duration: total)
        }
    }

    private func finish() {
        player.pause()
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        guard let session, position.isFinite, position > 0 else { return }
        Task { await session.finish(seconds: position, duration: duration.isFinite ? duration : 0) }
    }

    private func advance(to next: NextEpisode) {
        dismiss()
        let library = app.library
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if let entry = library.matching(tmdbID: next.target.tmdbID, season: next.target.season, episode: next.target.episode).first {
                router.play(entry, resumeFrom: library.resumeSeconds(for: entry))
            } else if let query = next.query {
                router.versions = VersionsRequest(query: query, target: next.target, playNow: [])
            }
        }
    }
}

private struct VideoPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
