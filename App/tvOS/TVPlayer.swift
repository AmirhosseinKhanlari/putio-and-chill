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
        coordinator.onNextTransfer = { [router] transfer in router.playTransfer(transfer) }
        coordinator.onDetails = { [router] item in
            router.player = nil
            router.showTitle(item)
        }
        coordinator.onChooseVersion = { [router] request in
            router.player = nil
            router.open(.versions(request))
        }
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
    private var selectionObserver: NSObjectProtocol?
    private var sleepTimer: SleepTimer?
    private var lastSleepMinute = -1
    /// The episode after this one (from TMDB, wherever playback started): offered when the credits start.
    private var nextUp: NextUp?
    private var creditsDismissed = false
    private var countdownStarted: Date?
    private var shownActions: [String] = []
    private var gettingStatus: String?
    private var gettingTask: Task<Void, Never>?
    private var gettingFailed = false
    var onNext: ((LibraryEntry) -> Void)?
    var onNextTransfer: ((TrackedTransfer) -> Void)?
    var onChooseVersion: ((TVVersionsRequest) -> Void)?
    var onDetails: ((CatalogItem) -> Void)?

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
        if let match = request.entry.match, match.mediaType == .tv, let season = match.season, let episode = match.episode {
            Task { [weak self, app] in
                let next = await NextUpFinder.find(tmdbID: match.tmdbID, season: season, episode: episode, catalog: app.catalog,
                                                   library: app.library)
                self?.nextUp = next
            }
        }
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
            await ourSubtitleChanged()
        }
        // Only one subtitle at a time: captions picked in Apple's own menu turn ours off.
        // Any item (the stream is replaced once a conversion finishes), but only the one playing counts.
        selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification,
                                                                   object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.systemSelectionChanged()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem, let next = self.nextUp else { return }
                // The episode is over: play the next one now if it's in put.io (and auto-play is on), else offer it.
                if self.autoplay, next.isInPutio { self.playNext() } else { self.creditsDismissed = false; self.refreshNextActions(atEnd: true) }
            }
        }
        rebuildMenus()
        // A video Apple devices can't play as it is: put.io converts it (a card shows how far), then it plays.
        if let content = controller.contentOverlayView, app.putio != nil {
            let card = UIHostingController(rootView: TVConversionOverlay(conversions: app.conversions, fileID: request.entry.id))
            card.view.backgroundColor = .clear
            card.view.isUserInteractionEnabled = false
            card.view.frame = content.bounds
            card.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            content.addSubview(card.view)
            controller.addChild(card)
            Task { [weak self] in await self?.convertIfNeeded() }
        }
        return controller
    }

    /// If the video doesn't start within 20 s (or fails) and put.io says its format needs converting, converts it
    /// and then plays it. Not done up front: put.io also flags videos only web browsers can't play.
    private func convertIfNeeded() async {
        let fileID = request.entry.id
        for _ in 0..<20 {
            if player.currentItem?.status == .readyToPlay || finished { return }
            if player.currentItem?.status == .failed { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard let putio = app.putio, !finished, await app.conversions.needsConversion(fileID: fileID) else { return }
        player.pause()
        let ok = await app.conversions.makePlayable(fileID: fileID)
        guard ok, !finished else { return }
        let resumeAt = max(player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0, Double(request.resumeFrom))
        let item = AVPlayerItem(url: putio.hlsURL(fileID: fileID, subtitles: false))
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .commonIdentifierTitle
        metadata.value = request.title as NSString
        item.externalMetadata = [metadata]
        player.replaceCurrentItem(with: item)
        if resumeAt > 0 { await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
        player.play()
    }

    private var lastSync = 0.0

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let text = finder.text(at: seconds)
        if line.text != text { line.text = text }
        updateNextOffer(at: seconds)
        applySleepTimer(position: seconds)
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
        gettingTask?.cancel()
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        player.pause()
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        if let session, position.isFinite, position > 0 {
            Task { await session.finish(seconds: position, duration: duration.isFinite ? duration : 0) }
        }
    }

    // MARK: Next episode (Netflix-style)

    private var autoplay: Bool { app.settings.autoPlayNextEpisode && sleepTimer?.option != .endOfEpisode }

    /// From the start of the credits: "Next Episode · 8" counting down (then it plays), and "Watch Credits".
    /// Not in put.io yet: "Get Next Episode", which fetches it and plays it when ready.
    private func updateNextOffer(at seconds: Double) {
        guard nextUp != nil, let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
        let remaining = duration - seconds
        if remaining > NextUp.creditsLength(duration: duration) {
            // Before the credits (or seeked back): nothing on screen unless a download is under way.
            creditsDismissed = false
            countdownStarted = nil
        }
        refreshNextActions(atEnd: remaining < 1.5, inCredits: remaining <= NextUp.creditsLength(duration: duration))
    }

    private func refreshNextActions(atEnd: Bool, inCredits: Bool = true) {
        guard var next = nextUp, !finished else { return }
        if !next.isInPutio, gettingTask == nil { next = next.resolved(in: app.library); nextUp = next }
        var actions: [UIAction] = []
        let show = (inCredits && !creditsDismissed) || atEnd || gettingStatus != nil || gettingFailed
        if show {
            if next.isInPutio {
                var title = "Next Episode"
                if autoplay {
                    let started = countdownStarted ?? Date()
                    countdownStarted = started
                    let left = Int((NextUp.countdown - Date().timeIntervalSince(started)).rounded(.up))
                    if left <= 0 { playNext(); return }
                    title += " · \(left)"
                }
                actions.append(UIAction(title: title, image: UIImage(systemName: "play.fill")) { [weak self] _ in self?.playNext() })
            } else if gettingFailed {
                actions.append(UIAction(title: "Choose Version", image: UIImage(systemName: "square.stack.3d.up")) { [weak self] _ in
                    self?.chooseVersion()
                })
            } else {
                actions.append(UIAction(title: gettingStatus ?? "Get Next Episode",
                                        image: UIImage(systemName: "icloud.and.arrow.down")) { [weak self] _ in self?.getNext() })
            }
            if !atEnd, gettingStatus == nil {
                actions.append(UIAction(title: "Watch Credits") { [weak self] _ in
                    self?.creditsDismissed = true
                    self?.countdownStarted = nil
                    self?.refreshNextActions(atEnd: false)
                })
            }
        }
        let titles = actions.map(\.title)
        guard titles != shownActions else { return }
        shownActions = titles
        controller?.contextualActions = actions
    }

    private func playNext() {
        guard let entry = nextUp?.entry, !finished else { return }
        finish()
        onNext?(entry)
    }

    private func getNext() {
        guard let next = nextUp, gettingTask == nil else { return }
        guard let query = next.query else { gettingFailed = true; refreshNextActions(atEnd: false); return }
        gettingStatus = "Finding the best version…"
        refreshNextActions(atEnd: false)
        gettingTask = Task { [weak self] in
            guard let self else { return }
            switch await app.smartGet(query, target: next.target) {
            case .sent:
                while !Task.isCancelled, !finished {
                    if let transfer = app.transfers.latest(tmdbID: next.target.tmdbID, season: next.season, episode: next.episode) {
                        if transfer.playableFile != nil {
                            finish()
                            onNextTransfer?(transfer)
                            return
                        }
                        if case .failed = transfer.phase { break }
                        gettingStatus = "Getting Next Episode · \(transfer.percent)%"
                        refreshNextActions(atEnd: false)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                if !finished { gettingFailed = true }
            case .noMatch, .failed:
                gettingFailed = true
            }
            gettingStatus = nil
            gettingTask = nil
            refreshNextActions(atEnd: false)
        }
    }

    private func chooseVersion() {
        guard let next = nextUp, let query = next.query else { return }
        finish()
        onChooseVersion?(TVVersionsRequest(query: query, target: next.target, playNow: []))
    }

    // MARK: Sleep timer

    /// Fades the sound over the last 15 seconds, then pauses.
    private func applySleepTimer(position: Double) {
        guard let timer = sleepTimer else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        let now = Date()
        player.volume = timer.volume(now: now, position: position, duration: duration)
        if timer.shouldStop(now: now, position: position, duration: duration) {
            player.pause()
            player.volume = 1
            sleepTimer = nil
            controller?.contextualActions = []
            rebuildMenus()
            return
        }
        // Refresh "about N min left" in the menu once a minute.
        let minute = Int((timer.remaining(now: now, position: position, duration: duration) ?? 0) / 60)
        if minute != lastSleepMinute { lastSleepMinute = minute; rebuildMenus() }
    }

    private func sleepMenu() -> UIMenu {
        var items: [UIMenuElement] = []
        if let sleepTimer {
            let position = player.currentTime().seconds
            let duration = player.currentItem?.duration.seconds ?? 0
            let left = sleepTimer.remaining(now: Date(), position: position, duration: duration).map { max(1, Int(($0 / 60).rounded())) }
            items.append(UIAction(title: left.map { "Stops in about \($0) min" } ?? sleepTimer.option.title, attributes: .disabled) { _ in })
            items.append(UIAction(title: "Turn Off", image: UIImage(systemName: "xmark")) { [weak self] _ in
                self?.sleepTimer = nil
                self?.player.volume = 1
                self?.rebuildMenus()
            })
        }
        for option in SleepTimer.Option.choices {
            items.append(UIAction(title: option.title, state: sleepTimer?.option == option ? .on : .off) { [weak self] _ in
                self?.sleepTimer = SleepTimer(option, startedAt: Date())
                self?.lastSleepMinute = -1
                self?.rebuildMenus()
            })
        }
        return UIMenu(title: "Sleep Timer", image: UIImage(systemName: sleepTimer == nil ? "moon" : "moon.fill"), children: items)
    }

    // MARK: One subtitle at a time

    /// Ours turned on: switch off whatever Apple's own Subtitles menu is showing (captions inside the video).
    private func ourSubtitleChanged() async {
        if finder.isShowing, let item = player.currentItem,
           let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), group.allowsEmptySelection,
           item.currentMediaSelection.selectedMediaOption(in: group) != nil {
            item.select(nil, in: group)
        }
        rebuildMenus()
    }

    /// Something picked in Apple's own Subtitles menu: turn ours off so two never show at once.
    private func systemSelectionChanged() {
        guard finder.isShowing, let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible),
              item.currentMediaSelection.selectedMediaOption(in: group) != nil else { return }
        Task { await finder.turnOff(); rebuildMenus() }
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
                    Task { await self?.finder.choose(track); await self?.ourSubtitleChanged() }
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
                    Task { await self?.finder.choose(result); await self?.ourSubtitleChanged() }
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
        var bar: [UIMenuElement] = [
            UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble.fill"), children: items),
            sleepMenu(),
        ]
        // The movie or show page (closes the player).
        if let item = request.entry.titleItem {
            bar.append(UIAction(title: item.mediaType == .tv ? "Show Details" : "Movie Details",
                                image: UIImage(systemName: "info.circle")) { [weak self] _ in
                guard let self else { return }
                finish()
                onDetails?(item)
            })
        }
        controller?.transportBarCustomMenuItems = bar
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

/// "Converting for Apple devices · 42%" over the video while put.io converts it.
private struct TVConversionOverlay: View {
    let conversions: VideoConversions
    let fileID: Int64

    var body: some View {
        if let state = conversions.states[fileID] {
            VStack(spacing: 18) {
                switch state {
                case let .converting(percent):
                    ProgressView(value: Double(percent), total: 100).frame(width: 420)
                    Text("Converting for Apple TV · \(percent)%").font(.system(size: 34, weight: .semibold))
                    Text("This video's format doesn't play on Apple TV as it is, so put.io is converting it. It starts by itself when it's ready.")
                        .font(.system(size: 24)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                case .failed:
                    Text("put.io couldn't convert this video").font(.system(size: 34, weight: .semibold))
                    Text("Try another version of it.").font(.system(size: 24)).foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(40)
            .frame(maxWidth: 820)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 28))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
