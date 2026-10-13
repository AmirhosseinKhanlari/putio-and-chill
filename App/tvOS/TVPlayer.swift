import AMDBCore
import AMDBKit
import AVKit
import SwiftUI

/// Apple's TV player with the app's subtitles: put.io tracks and OpenSubtitles in the player's own menus
/// (swipe down), drawn over the video in the chosen style. Progress syncs to put.io.
struct TVPlayerView: UIViewControllerRepresentable {
    let request: TVPlayRequest
    @Environment(AppModel.self) private var app

    func makeCoordinator() -> TVPlaybackCoordinator { TVPlaybackCoordinator(request: request, app: app) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        context.coordinator.makeController()
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: TVPlaybackCoordinator) {
        coordinator.finish()
    }
}

@Observable @MainActor
final class TVSubtitleLine {
    var text: String?
}

@MainActor
final class TVPlaybackCoordinator {
    private let request: TVPlayRequest
    private let app: AppModel
    private let session: PlaybackSession?
    private let finder: SubtitleFinder
    private let line = TVSubtitleLine()
    private let player: AVPlayer
    private weak var controller: AVPlayerViewController?
    private var timeObserver: Any?
    private var finished = false

    init(request: TVPlayRequest, app: AppModel) {
        self.request = request
        self.app = app
        if let putio = app.putio {
            session = PlaybackSession(fileID: request.entry.id, resumeFrom: request.resumeFrom, putio: putio,
                                      library: app.library, store: app.store)
            player = AVPlayer(url: putio.hlsURL(fileID: request.entry.id, subtitles: false))
        } else {
            session = nil
            player = AVPlayer()
        }
        finder = app.subtitleFinder(for: request.subtitleContext, fileSize: request.entry.file.size)
    }

    func makeController() -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        self.controller = controller
        let overlay = UIHostingController(rootView: TVSubtitleOverlay(line: line, style: app.settings.subtitleStyle))
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        if let content = controller.contentOverlayView {
            overlay.view.frame = content.bounds
            overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            content.addSubview(overlay.view)
            controller.addChild(overlay)
        }
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .commonIdentifierTitle
        metadata.value = request.title as NSString
        player.currentItem?.externalMetadata = [metadata]

        if request.resumeFrom > 0 { player.seek(to: CMTime(seconds: Double(request.resumeFrom), preferredTimescale: 600)) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        player.play()
        Task {
            await finder.restore()
            rebuildMenus()
        }
        rebuildMenus()
        return controller
    }

    private var lastSync = 0.0

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let text = finder.text(at: seconds)
        if line.text != text { line.text = text }
        if seconds - lastSync >= 10, let session {
            lastSync = seconds
            let duration = player.currentItem?.duration.seconds ?? 0
            Task { await session.tick(seconds: seconds, duration: duration.isFinite ? duration : 0) }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        if let session, position.isFinite, position > 0 {
            Task { await session.finish(seconds: position, duration: duration.isFinite ? duration : 0) }
        }
    }

    // MARK: Menus (Subtitles, Timing) in the player's swipe-down bar

    private func rebuildMenus() {
        var actions: [UIMenuElement] = []
        actions.append(UIAction(title: "Off", state: finder.isShowing ? .off : .on) { [weak self] _ in
            Task { await self?.finder.turnOff(); self?.rebuildMenus() }
        })
        for track in finder.putioTracks {
            let showing = finder.isShowing && finder.choice?.putioKey == track.key
            let source = track.source == "mkv" ? "in the file" : (track.source == "folder" ? "next to the file" : "put.io")
            actions.append(UIAction(title: "\(track.language ?? track.name ?? "Subtitle") · \(source)", state: showing ? .on : .off) { [weak self] _ in
                Task { await self?.finder.choose(track); self?.rebuildMenus() }
            })
        }
        if finder.canSearch {
            if finder.results.isEmpty {
                actions.append(UIAction(title: finder.isSearching ? "Searching OpenSubtitles…" : "Search OpenSubtitles",
                                        image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                    Task { await self?.finder.search(); self?.rebuildMenus() }
                })
            }
            for result in finder.results.prefix(12) {
                let showing = finder.isShowing && finder.choice?.putioKey == nil && finder.choice?.subtitleFileID == result.fileID
                let badge = result.hashMatch ? " ✓ matches this file" : ""
                actions.append(UIAction(title: "OpenSubtitles · \(result.release)\(badge)", state: showing ? .on : .off) { [weak self] _ in
                    Task { await self?.finder.choose(result); self?.rebuildMenus() }
                })
            }
        }
        if let message = finder.message {
            actions.append(UIAction(title: message, attributes: .disabled) { _ in })
        }
        let subtitles = UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: actions)

        let offset = finder.choice?.offset ?? 0
        let timing = UIMenu(title: offset == 0 ? "Timing" : String(format: "Timing %+.1fs", offset),
                            image: UIImage(systemName: "timer"), children: [
            UIAction(title: "Show Earlier (−0.5 s)") { [weak self] _ in Task { await self?.finder.shiftTiming(by: -0.5); self?.rebuildMenus() } },
            UIAction(title: "Show Later (+0.5 s)") { [weak self] _ in Task { await self?.finder.shiftTiming(by: 0.5); self?.rebuildMenus() } },
            UIAction(title: "Reset", attributes: offset == 0 ? .disabled : []) { [weak self] _ in
                Task { await self?.finder.shiftTiming(by: -offset); self?.rebuildMenus() }
            },
        ])
        controller?.transportBarCustomMenuItems = finder.isShowing ? [subtitles, timing] : [subtitles]
    }
}

/// Subtitle text near the bottom of the picture, sized for the TV.
struct TVSubtitleOverlay: View {
    let line: TVSubtitleLine
    let style: SubtitleStyle

    var body: some View {
        VStack {
            Spacer()
            if let text = line.text {
                StyledSubtitleText(text: text, style: style, compact: false, scale: 1.9)
                    .padding(.horizontal, 160)
                    .padding(.bottom, 90)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// Trailers play in the same TV player.
struct TVTrailerPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        controller.player = player
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
    }
}
