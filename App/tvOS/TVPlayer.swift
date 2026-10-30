import AMDBCore
import AMDBKit
import AVKit
import SwiftUI

/// Apple's TV player with one Subtitles button of ours (like the iPhone app): put.io's subtitles and OpenSubtitles,
/// timing, and style, all drawn over the video in the chosen style. Apple's own Subtitles button is hidden (its Audio
/// button stays); captions inside the video stream, if any, are in our menu too. Progress syncs to put.io.
/// A video Apple's player can't play goes to the built-in player (TVBuiltInPlayerController) instead, with the same
/// menus, subtitles, Next Episode and progress sync.
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
        coordinator.onClose = { [router] in router.player = nil }
        return coordinator
    }

    func makeUIViewController(context: Context) -> TVPlayerHostController {
        context.coordinator.makeController()
    }

    func updateUIViewController(_ controller: TVPlayerHostController, context: Context) {}

    static func dismantleUIViewController(_ controller: TVPlayerHostController, coordinator: TVPlaybackCoordinator) {
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
    private let host = TVPlayerHostController()
    /// Apple's player, kept while the built-in player has the screen (the host drops it as a child then), so it can
    /// take the screen back with its picture and the "Converting…" card; released when the player closes.
    private var controller: AVPlayerViewController?
    /// The built-in player, while it plays this video (nil: Apple's player).
    private var builtIn: PlayerEngine?
    private let builtInChrome = TVBuiltInChrome()
    private var builtInTicker: Task<Void, Never>?
    /// Which player to try next when one fails.
    private let plan: PlaybackPlan?
    private var routingTask: Task<Void, Never>?
    private var endHandled = false
    private var timeObserver: Any?
    private var finished = false
    /// Set once playback is at the starting point (after the seek to the resume position): before that the player
    /// reports 0, which must never be saved over where the user stopped last time.
    private var atStart = false
    private var endObserver: NSObjectProtocol?
    private var pauseObservation: NSKeyValueObservation?
    /// Where playback starts: the request's position, or put.io's newer one (looked up before playing).
    private var startSeconds = 0
    private var resignObserver: NSObjectProtocol?
    private var selectionObserver: NSObjectProtocol?
    private var sleepTimer: SleepTimer?
    private var lastSleepMinute = -1
    /// The sleep timer paused playback: the pause isn't the end of the episode, and the next episode waits for the
    /// user (Play Next by hand, no countdown) rather than starting by itself. Cleared once playback goes on.
    private var stoppedBySleepTimer = false
    /// The episode after this one (from TMDB, wherever playback started): offered when the credits start.
    private var nextUp: NextUp?
    private var creditsDismissed = false
    private var countdownStarted: Date?
    private var shownActions: [String] = []
    private var gettingStatus: String?
    /// How far the next episode's download is (0…1), while it's being fetched.
    private var gettingProgress: Double?
    private var gettingTask: Task<Void, Never>?
    private var gettingFailed = false
    /// Captions inside the video stream itself (e.g. closed captions), offered in our menu; and the one picked there.
    private var streamGroup: AVMediaSelectionGroup?
    private var streamPick: AVMediaSelectionOption?
    var onNext: ((LibraryEntry) -> Void)?
    var onNextTransfer: ((TrackedTransfer) -> Void)?
    var onChooseVersion: ((TVVersionsRequest) -> Void)?
    var onDetails: ((CatalogItem) -> Void)?
    var onClose: (() -> Void)?

    init(request: TVPlayRequest, app: AppModel) {
        self.request = request
        self.app = app
        if let putio = app.putio {
            // With the entry, a file the library doesn't have yet (played from Files, a new transfer) still shows in
            // Continue Watching as soon as it's been watched a little.
            session = PlaybackSession(fileID: request.entry.id, resumeFrom: request.resumeFrom, putio: putio,
                                      library: app.library, store: app.store, entry: request.entry, watchLog: app.watchLog)
            // Subtitles stay out of the stream: ours draws them, so style and timing apply to all of them.
            player = AVPlayer(url: putio.hlsURL(fileID: request.entry.id, subtitles: false))
            plan = BuiltInPlayer.plan(fileID: request.entry.id, app: app)
        } else {
            session = nil
            player = AVPlayer()
            plan = nil
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

    func makeController() -> TVPlayerHostController {
        let controller = AVPlayerViewController()
        controller.player = player
        // No languages allowed: Apple's Subtitles button goes away (the Audio one stays), so ours is the only one.
        controller.allowedSubtitleOptionLanguages = []
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
        host.show(controller)

        builtInChrome.title = request.title
        if let match = request.entry.match, let season = match.season, let episode = match.episode {
            builtInChrome.subtitle = "Season \(season) · Episode \(episode)"
        }
        builtInChrome.onClose = { [weak self] in self?.close() }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.builtIn == nil else { return }
                self.tick(time.seconds)
            }
        }
        // Which player first (Apple's, or the built-in one when put.io's codec info says Apple's can't decode it),
        // and where to start: the request's position, or put.io's newer one (it may have been watched further on
        // another device).
        routingTask = Task { [weak self, app, entry = self.request.entry, exact = self.request.exactStart || self.session == nil] in
            // Another copy of the title watched more recently (switching versions): from where that one was left.
            let fresh = exact ? nil : await app.library.freshResumeSeconds(forTitleOf: entry)
            let id = entry.id
            guard let self, !self.finished else { return }
            let seconds = fresh ?? self.request.resumeFrom
            let step = await self.plan?.firstStep() ?? .play(.apple)
            BuiltInPlayer.log.notice("file \(id): first \(String(describing: step)) (TV)")
            if step == .play(.builtIn), await self.switchToBuiltIn(at: Double(seconds)) {
                self.startSeconds = seconds
                self.atStart = true
            } else {
                self.start(at: seconds)
            }
            await self.watchApplesPlayer()
        }
        // Pausing (or reaching the end) saves the position, for put.io and the other devices. Playing again after
        // the sleep timer stopped it lets the next episode count down again.
        pauseObservation = player.observe(\.timeControlStatus, options: [.old, .new]) { [weak self] _, change in
            let paused = change.oldValue != .paused && change.newValue == .paused
            let playing = change.newValue == .playing
            guard paused || playing else { return }
            Task { @MainActor in
                if paused { self?.saveProgress() }
                if playing { self?.resumedAfterSleepTimer() }
            }
        }
        // put.io's tracks, then the saved pick or the preferred language from Settings.
        Task {
            await finder.restore()
            await loadStreamCaptions()
            await ourSubtitleChanged()
        }
        // Only one subtitle at a time: captions the player turns on by itself are turned off again.
        // Any item (the stream is replaced once a conversion finishes), but only the one playing counts.
        selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification,
                                                                   object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.systemSelectionChanged()
            }
        }
        // Leaving the app (TV or Home button, the app switcher) doesn't close the player, so save the position now.
        // The next episode's countdown starts over when the app comes back: the time away mustn't count, or the
        // first tick back would start the next episode with no countdown seen.
        resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveProgress()
                self?.resetCountdown()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.playbackEnded()
            }
        }
        rebuildMenus()
        // A video put.io has to convert first (the last resort): a card shows how far, then it plays.
        if let content = controller.contentOverlayView, app.putio != nil {
            let card = UIHostingController(rootView: TVConversionOverlay(conversions: app.conversions, fileID: request.entry.id))
            card.view.backgroundColor = .clear
            card.view.isUserInteractionEnabled = false
            card.view.frame = content.bounds
            card.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            content.addSubview(card.view)
            controller.addChild(card)
        }
        return host
    }

    // MARK: Which player

    /// Apple's player has up to 20 s to get going (60 s when put.io doesn't say the format needs converting). If it
    /// fails, the next player: the built-in one on the original file, then put.io's conversion, the last resort.
    private func watchApplesPlayer() async {
        guard let plan, builtIn == nil else { return }
        for second in 1...60 {
            try? await Task.sleep(for: .seconds(1))
            guard !finished, builtIn == nil else { return }
            if player.currentItem?.status == .readyToPlay, await applesPlayerDecodes() {
                plan.succeeded(.apple)
                BuiltInPlayer.log.notice("file \(self.request.entry.id): playing with apple (TV)")
                return
            }
            let failed = player.currentItem?.status == .failed || (player.currentItem?.status == .readyToPlay)
            let stuck = second == 20 ? await app.conversions.needsConversion(fileID: request.entry.id) : false
            if failed || stuck || second == 60 { break }
        }
        guard !finished else { return }
        await moveOn(after: .apple)
    }

    /// "Ready to play" can also mean a video AVFoundation opens but can't decode (a black picture).
    private func applesPlayerDecodes() async -> Bool {
        guard let asset = player.currentItem?.asset else { return false }
        for track in (try? await asset.loadTracks(withMediaType: .video)) ?? [] where (try? await track.load(.isDecodable)) == false {
            return false
        }
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        if audio.isEmpty { return true }
        for track in audio where (try? await track.load(.isDecodable)) != false { return true }
        return false
    }

    /// `failed` couldn't play it: the next step of the plan.
    private func moveOn(after failed: PlaybackEngineKind) async {
        guard let plan, !finished else { return }
        var step = await plan.step(afterFailureOf: failed)
        BuiltInPlayer.log.notice("file \(self.request.entry.id): \(failed.rawValue) failed, next \(String(describing: step)) (TV)")
        while !finished {
            switch step {
            case .play(.builtIn):
                if await switchToBuiltIn(at: resumePoint) { return }
                step = await plan.step(afterFailureOf: .builtIn)
            case .play(.apple):
                switchToApple(url: app.putio?.hlsURL(fileID: request.entry.id, subtitles: false))
                await watchApplesPlayer()
                return
            case .convert:
                switchToApple(url: nil)
                await convert()
                return
            case .fail:
                if builtIn != nil { builtInChrome.message = "This video couldn't be played. Try another version of it." }
                return
            }
        }
    }

    private var resumePoint: Double { max(currentSeconds, Double(startSeconds)) }

    /// The built-in player takes over the screen, on put.io's link to the original file.
    private func switchToBuiltIn(at seconds: Double) async -> Bool {
        guard let putio = app.putio else { return false }
        let fileID = request.entry.id
        guard let original = try? await putio.originalURL(fileID: fileID), !finished,
              let backend = BuiltInPlayer.backend(url: original, audioLanguage: app.settings.audioLanguage,
                                                  refreshURL: { try? await putio.originalURL(fileID: fileID) }) else { return false }
        player.pause()
        player.replaceCurrentItem(with: nil)
        let engine = PlayerEngine(backend: backend)
        engine.onPause = { [weak self] in self?.saveProgress() }
        engine.enableNowPlaying(title: request.title)
        builtIn = engine
        builtInChrome.message = nil
        endHandled = false
        host.show(TVBuiltInPlayerController(engine: engine, chrome: builtInChrome, line: line))
        engine.start(at: seconds)
        rebuildMenus()
        builtInTicker = Task { [weak self] in await self?.watchBuiltIn(engine) }
        return true
    }

    /// Back to Apple's player (the built-in one failed, or put.io converted the video), going on from wherever the
    /// built-in player got to, not from where the video started.
    private func switchToApple(url: URL?) {
        // Read before the built-in player is torn down: its position is the furthest point reached.
        let resumeAt = Int(resumePoint)
        builtInTicker?.cancel()
        builtIn?.tearDown()
        builtIn = nil
        // Kept for the conversion path too: Apple's player starts here once put.io's conversion is done.
        startSeconds = resumeAt
        host.setUpNext(nil)
        shownActions = []
        if let controller { host.show(controller) }
        if let url {
            let item = AVPlayerItem(url: url)
            let metadata = AVMutableMetadataItem()
            metadata.identifier = .commonIdentifierTitle
            metadata.value = request.title as NSString
            item.externalMetadata = [metadata]
            player.replaceCurrentItem(with: item)
            start(at: resumeAt)
            Task { await loadStreamCaptions() }
        }
        rebuildMenus()
    }

    /// The built-in player's clock drives subtitles, Next Episode, the sleep timer and saving; a failure moves on.
    private func watchBuiltIn(_ engine: PlayerEngine) async {
        var remembered = false
        var waited = 0
        var wasPlaying = false
        while !Task.isCancelled, !finished, builtIn === engine {
            try? await Task.sleep(for: .milliseconds(250))
            if engine.status == .ready {
                if !remembered {
                    remembered = true
                    plan?.succeeded(.builtIn)
                    BuiltInPlayer.log.notice("file \(self.request.entry.id): playing with builtIn (TV)")
                }
                // Going from paused to playing (the engine reports the pause a moment after it's asked for, so only
                // the change counts): the user went on after the sleep timer stopped it.
                if engine.isPlaying, !wasPlaying { resumedAfterSleepTimer() }
                wasPlaying = engine.isPlaying
                tick(engine.position)
                // A pause by the sleep timer in the last second isn't the episode ending.
                if engine.duration > 0, engine.position >= engine.duration - 1, !engine.isPlaying, !endHandled, !stoppedBySleepTimer {
                    endHandled = true
                    playbackEnded()
                }
            } else {
                waited += 1
            }
            if engine.status.isFailed || waited >= 240 {
                await moveOn(after: .builtIn)
                return
            }
        }
    }

    /// put.io converts it to MP4, then Apple's player plays the stream.
    private func convert() async {
        let fileID = request.entry.id
        guard let putio = app.putio, !finished else { return }
        player.pause()
        let ok = await app.conversions.makePlayable(fileID: fileID)
        guard ok, !finished else { return }
        switchToApple(url: putio.hlsURL(fileID: fileID, subtitles: false))
    }

    /// Where playback is, whichever player plays.
    private var currentSeconds: Double {
        if let builtIn { return builtIn.position }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    private var currentDuration: Double {
        if let builtIn { return builtIn.duration }
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private func pausePlayback() { builtIn?.pause() ?? player.pause() }

    private func setVolume(_ volume: Float) {
        if let builtIn { builtIn.volume = volume } else { player.volume = volume }
    }

    private func close() {
        finish()
        onClose?()
    }

    private var lastSync = 0.0

    /// Seeks to the starting point and plays. Positions aren't saved until the seek is done (`atStart`): also when
    /// Apple's player takes over from the built-in one, so the 0 it reports before the seek isn't saved.
    private func start(at seconds: Int) {
        guard !finished else { return }
        startSeconds = seconds
        lastSync = Double(seconds)
        atStart = false
        if seconds > 0 {
            player.seek(to: CMTime(seconds: Double(seconds), preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor in self?.atStart = true }
            }
        } else {
            atStart = true
        }
        player.play()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let text: String? = if case let .text(embedded)? = builtIn?.embeddedSubtitle { embedded }
            else if builtIn?.embeddedSubtitleID != nil { nil }
            else { finder.text(at: seconds) }
        if line.text != text { line.text = text }
        updateNextOffer(at: seconds)
        applySleepTimer(position: seconds)
        // Either way: after seeking back, the earlier position is saved without waiting to pass the old one.
        if atStart, abs(seconds - lastSync) >= 10, let session {
            lastSync = seconds
            let duration = currentDuration
            Task { await session.tick(seconds: seconds, duration: duration) }
        }
    }

    /// The episode is over: play the next one now if it's in put.io (and auto-play is on), else offer it.
    private func playbackEnded() {
        guard let next = nextUp else { return }
        if autoplay, next.isInPutio { playNext() } else { creditsDismissed = false; refreshNextActions(atEnd: true) }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        routingTask?.cancel()
        builtInTicker?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        gettingTask?.cancel()
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        pauseObservation?.invalidate()
        player.pause()
        saveProgress()
        builtIn?.onPause = nil
        builtIn?.tearDown()
        controller = nil
    }

    /// Saves where playback is now (in the library at once, then to put.io), finishing even if the app is leaving.
    private func saveProgress() {
        let position = currentSeconds
        let duration = currentDuration
        guard let session, atStart, position.isFinite, position > 0 else { return }
        lastSync = position
        BackgroundSave.run("Save playback position") {
            await session.finish(seconds: position, duration: duration)
        }
    }

    // MARK: Next episode (Netflix-style)

    private var autoplay: Bool {
        app.settings.autoPlayNextEpisode && sleepTimer?.option != .endOfEpisode && !stoppedBySleepTimer
    }

    /// From the start of the credits: "Next Episode · 8" counting down (then it plays), and "Watch Credits".
    /// Not in put.io yet: "Get Next Episode", which fetches it and plays it when ready.
    private func updateNextOffer(at seconds: Double) {
        let duration = currentDuration
        guard nextUp != nil, duration > 0 else { return }
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
        var actions: [TVMenuItem] = []
        let show = (inCredits && !creditsDismissed) || atEnd || gettingStatus != nil || gettingFailed
        if show {
            if next.isInPutio {
                var title = "Next Episode"
                // The countdown only runs while the app is active: ticks still come for a moment after the TV
                // button, and they mustn't restart it with the clock then running on while the app is away.
                if autoplay, UIApplication.shared.applicationState != .active {
                    countdownStarted = nil
                } else if autoplay {
                    let started = countdownStarted ?? Date()
                    countdownStarted = started
                    let left = Int((NextUp.countdown - Date().timeIntervalSince(started)).rounded(.up))
                    if left <= 0 { playNext(); return }
                    title += " · \(left)"
                }
                actions.append(TVMenuItem(title: title, symbol: "play.fill") { [weak self] in self?.playNext() })
            } else if gettingFailed {
                actions.append(TVMenuItem(title: "Choose Version", symbol: "square.stack.3d.up") { [weak self] in self?.chooseVersion() })
            } else {
                actions.append(TVMenuItem(title: gettingStatus ?? "Get Next Episode", symbol: "icloud.and.arrow.down") { [weak self] in
                    self?.getNext()
                })
            }
            if !atEnd, gettingStatus == nil {
                actions.append(TVMenuItem(title: "Watch Credits", symbol: "text.append") { [weak self] in
                    self?.creditsDismissed = true
                    self?.countdownStarted = nil
                    self?.refreshNextActions(atEnd: false)
                })
            }
        }
        let titles = actions.map(\.title)
        guard titles != shownActions else { return }
        shownActions = titles
        let secondary = actions.dropFirst().first
        // Menu on the remote: Watch Credits, or at the very end (or while it's being fetched) close the player.
        host.onUpNextBack = { [weak self] in
            if let watchCredits = secondary?.action { watchCredits() } else { self?.close() }
        }
        host.setUpNext(actions.first.map { primary in
            TVUpNextState(next: next, primary: primary, secondary: secondary,
                          countdownStarted: next.isInPutio && autoplay ? countdownStarted : nil, progress: gettingProgress)
        })
    }

    /// Play Next stops filling up, and the countdown starts from 8 again at the next offer (also on the panel: the
    /// next refresh pushes a fresh state even if the title hasn't changed).
    private func resetCountdown() {
        countdownStarted = nil
        shownActions = []
        host.pauseUpNextCountdown()
    }

    private func playNext() {
        guard let entry = nextUp?.entry, !finished else { return }
        // Next Episode (or its countdown): this one is watched, wherever it stopped.
        if let session, atStart {
            let position = currentSeconds, duration = currentDuration
            BackgroundSave.run("Save playback position") { await session.markWatched(seconds: position, duration: duration) }
        }
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
                        gettingProgress = Double(transfer.percent) / 100
                        refreshNextActions(atEnd: false)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                if !finished { gettingFailed = true }
            case .noMatch, .failed:
                gettingFailed = true
            }
            gettingStatus = nil
            gettingProgress = nil
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

    /// Fades the sound over the last 15 seconds, then pauses. The next episode stays offered (in the credits) but
    /// without its countdown: the user is asleep, or meant to stop here.
    private func applySleepTimer(position: Double) {
        guard let timer = sleepTimer else { return }
        let duration = currentDuration
        let now = Date()
        setVolume(timer.volume(now: now, position: position, duration: duration))
        if timer.shouldStop(now: now, position: position, duration: duration) {
            stoppedBySleepTimer = true
            countdownStarted = nil
            pausePlayback()
            setVolume(1)
            sleepTimer = nil
            // Rebuilt without the countdown (this tick's offer was made before the stop).
            updateNextOffer(at: position)
            rebuildMenus()
            return
        }
        // Refresh "about N min left" in the menu once a minute.
        let minute = Int((timer.remaining(now: now, position: position, duration: duration) ?? 0) / 60)
        if minute != lastSleepMinute { lastSleepMinute = minute; rebuildMenus() }
    }

    /// Playback went on after the sleep timer stopped it: the next episode may count down and play by itself again.
    /// Only if it really is playing now: a "playing" change reported just before the stop arrives after it.
    private func resumedAfterSleepTimer() {
        guard stoppedBySleepTimer, builtIn?.isPlaying ?? (player.timeControlStatus == .playing) else { return }
        stoppedBySleepTimer = false
        countdownStarted = nil
    }

    private func sleepMenu() -> TVMenu {
        var items: [TVMenuItem] = []
        if let sleepTimer {
            let left = sleepTimer.remaining(now: Date(), position: currentSeconds, duration: currentDuration)
                .map { max(1, Int(($0 / 60).rounded())) }
            items.append(.header(left.map { "Stops in about \($0) min" } ?? sleepTimer.option.title))
            items.append(TVMenuItem(title: "Turn Off", symbol: "xmark") { [weak self] in
                self?.sleepTimer = nil
                self?.setVolume(1)
                self?.rebuildMenus()
            })
        }
        for option in SleepTimer.Option.choices {
            items.append(TVMenuItem(title: option.title, isOn: sleepTimer?.option == option) { [weak self] in
                self?.sleepTimer = SleepTimer(option, startedAt: Date())
                self?.lastSleepMinute = -1
                self?.rebuildMenus()
            })
        }
        return TVMenu(title: "Sleep Timer", symbol: sleepTimer == nil ? "moon" : "moon.fill", items: items)
    }

    // MARK: One subtitle at a time

    /// Captions inside the stream (put.io is asked for none, but a video can carry closed captions of its own).
    private func loadStreamCaptions() async {
        guard let item = player.currentItem else { return }
        let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        guard item === player.currentItem else { return }
        streamGroup = group
        streamPick = nil
        systemSelectionChanged()
    }

    /// Ours turned on: switch off captions inside the stream (or the file, on the built-in player).
    private func ourSubtitleChanged() async {
        if finder.isShowing {
            selectStream(nil)
            if builtIn?.embeddedSubtitleID != nil { builtIn?.selectEmbeddedSubtitle(id: nil) }
        }
        rebuildMenus()
    }

    /// The player picked captions by itself (the stream's default): turn them off unless they're the ones picked in
    /// our menu, or ours are off and they're forced (signs) or the system's "Closed Captions and SDH" setting asks.
    private func systemSelectionChanged() {
        guard let item = player.currentItem, let group = streamGroup else { return }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        if let selected, selected != streamPick {
            let forced = Self.isForcedOnly(selected)
            if finder.isShowing || !(forced || UIAccessibility.isClosedCaptioningEnabled) {
                if group.allowsEmptySelection { item.select(nil, in: group) }
            } else if !forced {
                streamPick = selected
            }
        }
        rebuildMenus()
    }

    private func selectStream(_ option: AVMediaSelectionOption?) {
        streamPick = option
        guard let item = player.currentItem, let group = streamGroup, option != nil || group.allowsEmptySelection,
              item.currentMediaSelection.selectedMediaOption(in: group) != option else { return }
        item.select(option, in: group)
    }

    /// Stream captions worth offering: not forced-only tracks (those just translate signs and play on their own).
    private var streamOptions: [AVMediaSelectionOption] {
        (streamGroup?.options ?? []).filter { !Self.isForcedOnly($0) }
    }

    private static func isForcedOnly(_ option: AVMediaSelectionOption) -> Bool {
        option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
    }

    // MARK: Menus (Apple's player's swipe-down bar, or the built-in player's panel)

    /// One Subtitles menu with everything: put.io's subtitles, OpenSubtitles, timing and style. tvOS allows only one
    /// menu level here, so sections are gray labels and style options step through their values. The built-in
    /// player adds Audio and Speed (Apple's player has its own).
    private func rebuildMenus() {
        var items: [TVMenuItem] = []
        let embeddedID = builtIn?.embeddedSubtitleID
        let off = !finder.isShowing && streamPick == nil && embeddedID == nil
        items.append(TVMenuItem(title: "Off", isOn: off) { [weak self] in
            self?.selectStream(nil)
            self?.builtIn?.selectEmbeddedSubtitle(id: nil)
            Task { await self?.finder.turnOff(); self?.rebuildMenus() }
        })

        if !finder.putioTracks.isEmpty {
            items.append(.header("From put.io"))
            for track in finder.putioTracks {
                let showing = finder.isShowing && finder.choice?.putioKey == track.key
                items.append(TVMenuItem(title: Self.title(track), isOn: showing) { [weak self] in
                    Task { await self?.finder.choose(track); await self?.ourSubtitleChanged() }
                })
            }
        }

        // Tracks inside the file itself, which the built-in player reads.
        if let builtIn, !builtIn.embeddedSubtitles.isEmpty {
            items.append(.header("In the File"))
            for track in builtIn.embeddedSubtitles {
                items.append(TVMenuItem(title: track.name, isOn: embeddedID == track.id) { [weak self] in
                    Task {
                        await self?.finder.turnOff()
                        self?.builtIn?.selectEmbeddedSubtitle(id: track.id)
                        self?.rebuildMenus()
                    }
                })
            }
        }

        items.append(.header("OpenSubtitles"))
        if finder.canSearch {
            if finder.results.isEmpty {
                items.append(TVMenuItem(title: finder.isSearching ? "Searching…" : "Search OpenSubtitles", symbol: "magnifyingglass",
                                        action: finder.isSearching ? nil : { [weak self] in
                                            Task { await self?.finder.search(); self?.rebuildMenus() }
                                        }))
            }
            for result in finder.results.prefix(12) {
                let showing = finder.isShowing && finder.choice?.putioKey == nil && finder.choice?.subtitleFileID == result.fileID
                let badge = result.hashMatch ? "  ·  matches this file" : ""
                items.append(TVMenuItem(title: "\(result.release)\(badge)", isOn: showing) { [weak self] in
                    Task { await self?.finder.choose(result); await self?.ourSubtitleChanged() }
                })
            }
        } else {
            items.append(.header("Add an OpenSubtitles API key in Settings"))
        }

        // Captions carried by the video stream itself (closed captions), shown by the player in the system's style.
        if builtIn == nil, !streamOptions.isEmpty {
            items.append(.header("In the Video"))
            for option in streamOptions {
                let showing = !finder.isShowing && streamPick == option
                items.append(TVMenuItem(title: Self.title(option), isOn: showing) { [weak self] in
                    Task {
                        await self?.finder.turnOff()
                        self?.selectStream(option)
                        self?.rebuildMenus()
                    }
                })
            }
        }

        if finder.isShowing {
            let offset = finder.choice?.offset ?? 0
            items.append(.header(offset == 0 ? "Timing: in sync" : String(format: "Timing: %+.1f s", offset)))
            items.append(TVMenuItem(title: "Show Earlier  (−0.5 s)", symbol: "backward") { [weak self] in
                Task { await self?.finder.shiftTiming(by: -0.5); self?.rebuildMenus() }
            })
            items.append(TVMenuItem(title: "Show Later  (+0.5 s)", symbol: "forward") { [weak self] in
                Task { await self?.finder.shiftTiming(by: 0.5); self?.rebuildMenus() }
            })
        }

        items.append(.header("Style"))
        let style = line.style
        items.append(styleItem("Size", Self.name(style.size), image: "textformat.size") { $0.size = Self.next($0.size) })
        items.append(styleItem("Background", Self.name(style.background), image: "rectangle.fill") { $0.background = Self.next($0.background) })
        items.append(styleItem("Color", Self.name(style.color), image: "paintpalette") { $0.color = Self.next($0.color) })
        items.append(styleItem("Font", Self.name(style.typeface), image: "textformat") { $0.typeface = Self.next($0.typeface) })

        if let message = finder.message { items.append(.header(message)) }
        var menus = [TVMenu(title: "Subtitles", symbol: "captions.bubble.fill", items: items)]
        if let builtIn {
            if builtIn.audioTracks.count > 1 {
                menus.append(TVMenu(title: "Audio", symbol: "speaker.wave.2.fill", items: builtIn.audioTracks.map { track in
                    TVMenuItem(title: track.name, isOn: builtIn.currentAudioID == track.id) { [weak self] in
                        self?.builtIn?.selectAudio(id: track.id)
                        self?.rebuildMenus()
                    }
                }))
            }
            menus.append(TVMenu(title: "Speed", symbol: "gauge.with.dots.needle.67percent", items: [Float(0.5), 0.75, 1, 1.25, 1.5, 2].map { rate in
                TVMenuItem(title: rate == 1 ? "Normal" : String(format: "%g×", rate), isOn: builtIn.rate == rate) { [weak self] in
                    self?.builtIn?.rate = rate
                    self?.rebuildMenus()
                }
            }))
        }
        menus.append(sleepMenu())
        // The movie or show page (closes the player).
        if let item = request.entry.titleItem {
            menus.append(TVMenu(title: item.mediaType == .tv ? "Show Details" : "Movie Details", symbol: "info.circle") { [weak self] in
                guard let self else { return }
                finish()
                onDetails?(item)
            })
        }
        builtInChrome.menus = menus
        controller?.transportBarCustomMenuItems = menus.map(\.uiElement)
        // The built-in player learns its tracks after loading: refresh the menus once they're known.
        if let builtIn, builtIn.embeddedSubtitles.isEmpty || builtIn.audioTracks.isEmpty, !menusRefreshScheduled {
            menusRefreshScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.menusRefreshScheduled = false
                if self?.builtIn != nil { self?.rebuildMenus() }
            }
        }
    }

    private var menusRefreshScheduled = false

    /// "Size: Large" — selecting it steps to the next value; the change shows at once and is saved for next time.
    private func styleItem(_ label: String, _ value: String, image: String, _ change: @escaping (inout SubtitleStyle) -> Void) -> TVMenuItem {
        TVMenuItem(title: "\(label): \(value)", symbol: image) { [weak self] in
            guard let self else { return }
            var style = line.style
            change(&style)
            line.style = style
            app.updateSubtitleStyle(style)
            rebuildMenus()
        }
    }

    /// The stream's own name for it ("English CC"), or "Closed Captions" when it doesn't say its language.
    static func title(_ option: AVMediaSelectionOption) -> String {
        let unnamed = option.extendedLanguageTag == nil && option.locale == nil
        return unnamed && option.mediaType == .closedCaption ? "Closed Captions" : option.displayName
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
                case .queued:
                    ProgressView().scaleEffect(2).frame(width: 170, height: 170)
                    Text("Waiting for put.io to convert it").font(.system(size: 34, weight: .semibold))
                    Text("This video's format doesn't play on Apple TV as it is. It plays by itself once put.io has converted it.")
                        .font(.system(size: 24)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                case let .converting(percent):
                    ProgressRing(progress: Double(percent) / 100, lineWidth: 12)
                        .frame(width: 170, height: 170)
                        .overlay {
                            Text("\(percent)%").font(.system(size: 44, weight: .bold).monospacedDigit())
                                .contentTransition(.numericText())
                        }
                        .animation(.easeInOut, value: percent)
                    Text("Converting for Apple TV").font(.system(size: 36, weight: .semibold))
                    Text("This video's format doesn't play on Apple TV as it is, so put.io is converting it. It starts by itself when it's ready.")
                        .font(.system(size: 24)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                case .failed:
                    Text("put.io couldn't convert this video").font(.system(size: 34, weight: .semibold))
                    Text("Try another version of it.").font(.system(size: 24)).foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(50)
            .frame(maxWidth: 820)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
