import AMDBCore
import AMDBKit
import AVKit
import SwiftUI

/// Apple's TV player with one Subtitles button of ours (like the iPhone app): put.io's subtitles and OpenSubtitles,
/// timing, and style, all drawn over the video in the chosen style. Progress syncs to put.io.
struct TVPlayerView: UIViewControllerRepresentable {
    let request: TVPlayRequest
    @Environment(AppModel.self) private var app
    @Environment(TVRouter.self) private var router

    func makeCoordinator() -> TVPlaybackCoordinator {
        let coordinator = TVPlaybackCoordinator(request: request, app: app)
        coordinator.onNext = { [router] next in router.play(next, from: 0) }
        return coordinator
    }

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
    var style = SubtitleStyle.standard
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
    private var endObserver: NSObjectProtocol?
    /// The next episode when it's already in put.io; offered near the end and auto-played if Settings say so.
    private let next: LibraryEntry?
    private var offeringNext = false
    var onNext: ((LibraryEntry) -> Void)?

    init(request: TVPlayRequest, app: AppModel) {
        self.request = request
        self.app = app
        if let putio = app.putio {
            session = PlaybackSession(fileID: request.entry.id, resumeFrom: request.resumeFrom, putio: putio,
                                      library: app.library, store: app.store)
            // Subtitles stay out of the stream: ours draws them, so style and timing apply to all of them.
            player = AVPlayer(url: putio.hlsURL(fileID: request.entry.id, subtitles: false))
        } else {
            session = nil
            player = AVPlayer()
        }
        finder = app.subtitleFinder(for: request.subtitleContext, fileSize: request.entry.file.size)
        line.style = app.settings.subtitleStyle
        next = Self.nextEpisode(after: request.entry, in: app.library)
    }

    static func nextEpisode(after entry: LibraryEntry, in library: LibraryIndex) -> LibraryEntry? {
        guard let match = entry.match, match.mediaType == .tv, let season = match.season, let episode = match.episode else { return nil }
        return library.matching(tmdbID: match.tmdbID, season: season, episode: episode + 1).first
            ?? library.matching(tmdbID: match.tmdbID, season: season + 1, episode: 1).first
    }

    func makeController() -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        self.controller = controller
        let overlay = UIHostingController(rootView: TVSubtitleOverlay(line: line))
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
        // put.io's tracks, then the saved pick or the preferred language from Settings.
        Task {
            await finder.restore()
            rebuildMenus()
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.app.settings.autoPlayNextEpisode else { return }
                self.playNext()
            }
        }
        rebuildMenus()
        return controller
    }

    private var lastSync = 0.0

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let text = finder.text(at: seconds)
        if line.text != text { line.text = text }
        updateNextOffer(at: seconds)
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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.pause()
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        if let session, position.isFinite, position > 0 {
            Task { await session.finish(seconds: position, duration: duration.isFinite ? duration : 0) }
        }
    }

    // MARK: Next episode

    /// "Next Episode" button over the video for the last 30 seconds (like Skip Intro in Apple's apps).
    private func updateNextOffer(at seconds: Double) {
        guard let next, let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
        let offer = duration - seconds < 30
        guard offer != offeringNext else { return }
        offeringNext = offer
        let label = next.match.flatMap { match in match.episode.map { "Next: S\(match.season ?? 0) E\($0)" } } ?? "Next Episode"
        controller?.contextualActions = offer
            ? [UIAction(title: label, image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in self?.playNext() }]
            : []
    }

    private func playNext() {
        guard let next, !finished else { return }
        finish()
        onNext?(next)
    }

    // MARK: Subtitles menu (the player's swipe-down bar)

    /// One button with everything: put.io's subtitles, OpenSubtitles, timing and style. tvOS allows only one menu
    /// level here, so sections are gray labels and style options step through their values.
    private func rebuildMenus() {
        var items: [UIMenuElement] = []
        let off = !finder.isShowing
        items.append(UIAction(title: "Off", state: off ? .on : .off) { [weak self] _ in
            Task { await self?.finder.turnOff(); self?.rebuildMenus() }
        })

        if !finder.putioTracks.isEmpty {
            items.append(header("From put.io"))
            for track in finder.putioTracks {
                let showing = finder.isShowing && finder.choice?.putioKey == track.key
                items.append(UIAction(title: Self.title(track), state: showing ? .on : .off) { [weak self] _ in
                    Task { await self?.finder.choose(track); self?.rebuildMenus() }
                })
            }
        }

        items.append(header("OpenSubtitles"))
        if finder.canSearch {
            if finder.results.isEmpty {
                items.append(UIAction(title: finder.isSearching ? "Searching…" : "Search OpenSubtitles",
                                      image: UIImage(systemName: "magnifyingglass"),
                                      attributes: finder.isSearching ? .disabled : []) { [weak self] _ in
                    Task { await self?.finder.search(); self?.rebuildMenus() }
                })
            }
            for result in finder.results.prefix(12) {
                let showing = finder.isShowing && finder.choice?.putioKey == nil && finder.choice?.subtitleFileID == result.fileID
                let badge = result.hashMatch ? "  ·  matches this file" : ""
                items.append(UIAction(title: "\(result.release)\(badge)", state: showing ? .on : .off) { [weak self] _ in
                    Task { await self?.finder.choose(result); self?.rebuildMenus() }
                })
            }
        } else {
            items.append(UIAction(title: "Add an OpenSubtitles API key in Settings", attributes: .disabled) { _ in })
        }

        if finder.isShowing {
            let offset = finder.choice?.offset ?? 0
            items.append(header(offset == 0 ? "Timing: in sync" : String(format: "Timing: %+.1f s", offset)))
            items.append(UIAction(title: "Show Earlier  (−0.5 s)", image: UIImage(systemName: "backward")) { [weak self] _ in
                Task { await self?.finder.shiftTiming(by: -0.5); self?.rebuildMenus() }
            })
            items.append(UIAction(title: "Show Later  (+0.5 s)", image: UIImage(systemName: "forward")) { [weak self] _ in
                Task { await self?.finder.shiftTiming(by: 0.5); self?.rebuildMenus() }
            })
        }

        items.append(header("Style"))
        let style = line.style
        items.append(styleAction("Size", Self.name(style.size), image: "textformat.size") { $0.size = Self.next($0.size) })
        items.append(styleAction("Background", Self.name(style.background), image: "rectangle.fill") { $0.background = Self.next($0.background) })
        items.append(styleAction("Color", Self.name(style.color), image: "paintpalette") { $0.color = Self.next($0.color) })
        items.append(styleAction("Font", Self.name(style.typeface), image: "textformat") { $0.typeface = Self.next($0.typeface) })

        if let message = finder.message {
            items.append(UIAction(title: message, attributes: .disabled) { _ in })
        }
        controller?.transportBarCustomMenuItems = [
            UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble.fill"), children: items),
        ]
    }

    private func header(_ title: String) -> UIAction {
        UIAction(title: title, attributes: .disabled) { _ in }
    }

    /// "Size: Large" — selecting it steps to the next value; the change shows at once and is saved for next time.
    private func styleAction(_ label: String, _ value: String, image: String, _ change: @escaping (inout SubtitleStyle) -> Void) -> UIAction {
        UIAction(title: "\(label): \(value)", image: UIImage(systemName: image)) { [weak self] _ in
            guard let self else { return }
            var style = line.style
            change(&style)
            line.style = style
            app.updateSubtitleStyle(style)
            rebuildMenus()
        }
    }

    static func title(_ track: PutioSubtitle) -> String {
        let language = track.language ?? track.languageCode?.uppercased() ?? "Subtitle"
        let source = switch track.source { case "mkv": "in the file"; case "folder": "next to the file"; default: track.name }
        return [language, source].compactMap { $0 }.joined(separator: " · ")
    }

    static func next<Value: CaseIterable & Equatable>(_ value: Value) -> Value where Value.AllCases: BidirectionalCollection {
        let all = Array(Value.allCases)
        guard let index = all.firstIndex(of: value) else { return value }
        return all[(index + 1) % all.count]
    }

    static func name(_ value: some RawRepresentable<String>) -> String {
        switch value.rawValue {
        case "extraLarge": "Extra Large"
        case "none": "None"
        default: value.rawValue.prefix(1).uppercased() + value.rawValue.dropFirst()
        }
    }
}

/// Subtitle text near the bottom of the picture, sized for the TV.
struct TVSubtitleOverlay: View {
    let line: TVSubtitleLine

    var body: some View {
        VStack {
            Spacer()
            if let text = line.text {
                StyledSubtitleText(text: text, style: line.style, compact: false, scale: 1.9)
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
