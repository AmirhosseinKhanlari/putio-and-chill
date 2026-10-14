import AMDBCore
import AMDBKit
import AVKit
import SwiftUI

/// Apple's TV player. put.io's subtitles are in its own Subtitles menu (they're in the stream); one extra
/// OpenSubtitles button searches, picks and fixes timing, drawn over the video in the chosen style.
/// Progress syncs to put.io.
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
    private var selectionObserver: NSObjectProtocol?
    private var finished = false

    init(request: TVPlayRequest, app: AppModel) {
        self.request = request
        self.app = app
        if let putio = app.putio {
            session = PlaybackSession(fileID: request.entry.id, resumeFrom: request.resumeFrom, putio: putio,
                                      library: app.library, store: app.store)
            // put.io's subtitles ride in the stream, so they're in the player's own Subtitles menu.
            player = AVPlayer(url: putio.hlsURL(fileID: request.entry.id, subtitles: true))
        } else {
            session = nil
            player = AVPlayer()
        }
        finder = app.subtitleFinder(for: request.subtitleContext, fileSize: request.entry.file.size, includePutio: false)
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
            await applySubtitleLanguage()
            rebuildMenus()
        }
        // Picking a subtitle in the player's own menu turns OpenSubtitles off (never two at once).
        selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification,
                                                                   object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemSelectionChanged() }
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
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        player.pause()
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        if let session, position.isFinite, position > 0 {
            Task { await session.finish(seconds: position, duration: duration.isFinite ? duration : 0) }
        }
    }

    // MARK: Menus (Subtitles, Timing) in the player's swipe-down bar

    /// The preferred language from Settings, on put.io's tracks in the stream — unless an OpenSubtitles pick is showing.
    private func applySubtitleLanguage() async {
        guard let item = player.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        if finder.isShowing {
            if group.allowsEmptySelection { item.select(nil, in: group) }
            return
        }
        if let language = app.settings.subtitleLanguage,
           let index = LanguageMatcher.bestIndex(available: group.options.map { $0.extendedLanguageTag ?? $0.locale?.identifier },
                                                 preferred: language) {
            item.select(group.options[index], in: group)
        }
    }

    private func systemSelectionChanged() {
        guard finder.isShowing, let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible),
              item.currentMediaSelection.selectedMediaOption(in: group) != nil else { return }
        Task { await finder.turnOff(); rebuildMenus() }
    }

    /// Turns the stream's own subtitles off while an OpenSubtitles pick is showing.
    private func clearSystemSubtitles() async {
        guard let item = player.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              group.allowsEmptySelection else { return }
        item.select(nil, in: group)
    }

    /// One extra button next to the player's own Subtitles: search OpenSubtitles, pick, and fix timing.
    private func rebuildMenus() {
        var items: [UIMenuElement] = []
        if finder.canSearch {
            if finder.results.isEmpty {
                items.append(UIAction(title: finder.isSearching ? "Searching…" : "Search OpenSubtitles",
                                      image: UIImage(systemName: "magnifyingglass"),
                                      attributes: finder.isSearching ? .disabled : []) { [weak self] _ in
                    Task { await self?.finder.search(); self?.rebuildMenus() }
                })
            }
            for result in finder.results.prefix(15) {
                let showing = finder.isShowing && finder.choice?.subtitleFileID == result.fileID
                let badge = result.hashMatch ? "  ·  matches this file" : ""
                items.append(UIAction(title: "\(result.release)\(badge)", state: showing ? .on : .off) { [weak self] _ in
                    Task {
                        guard let self else { return }
                        await self.finder.choose(result)
                        if self.finder.isShowing { await self.clearSystemSubtitles() }
                        self.rebuildMenus()
                    }
                })
            }
        } else {
            items.append(UIAction(title: "Add an OpenSubtitles API key in Settings", attributes: .disabled) { _ in })
        }
        if finder.isShowing {
            let offset = finder.choice?.offset ?? 0
            items.append(UIAction(title: offset == 0 ? "Timing: in sync" : String(format: "Timing: %+.1f s", offset), attributes: .disabled) { _ in })
            items.append(UIAction(title: "Show Earlier  (−0.5 s)", image: UIImage(systemName: "backward")) { [weak self] _ in
                Task { await self?.finder.shiftTiming(by: -0.5); self?.rebuildMenus() }
            })
            items.append(UIAction(title: "Show Later  (+0.5 s)", image: UIImage(systemName: "forward")) { [weak self] _ in
                Task { await self?.finder.shiftTiming(by: 0.5); self?.rebuildMenus() }
            })
            items.append(UIAction(title: "Turn Off OpenSubtitles", image: UIImage(systemName: "xmark")) { [weak self] _ in
                Task { await self?.finder.turnOff(); self?.rebuildMenus() }
            })
        }
        if let message = finder.message {
            items.append(UIAction(title: message, attributes: .disabled) { _ in })
        }
        controller?.transportBarCustomMenuItems = [
            UIMenu(title: "OpenSubtitles", image: UIImage(systemName: "text.magnifyingglass"), children: items),
        ]
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
