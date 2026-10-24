import AMDBCore
import AMDBKit
import AVKit
import SwiftUI

/// Glass card shown before playback when put.io has a saved position.
struct ResumePrompt: View {
    let request: PlayerRequest
    /// Seconds to start from, or nil when cancelled.
    let onChoice: (Int?) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { onChoice(nil) }
            VStack(spacing: 14) {
                Text(request.title).font(.headline).multilineTextAlignment(.center)
                Button { onChoice(request.resumeFrom) } label: {
                    Label("Resume from \(Format.clock(request.resumeFrom))", systemImage: "play.fill")
                }
                .buttonStyle(.primaryPill)
                Button("Start over") { onChoice(0) }.buttonStyle(.glassPill)
                Button("Cancel") { onChoice(nil) }.font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            .padding(28)
            .glassRounded(24)
            .padding(32)
        }
        .transition(.opacity)
    }
}

@MainActor
enum PlayerPresenter {
    /// Presents Apple's player full screen. Its own close button is the only one; dismissal is detected by the coordinator.
    static func present(_ request: PlayerRequest, from seconds: Int, app: AppModel, router: Router, localURL: URL? = nil) {
        guard let putio = app.putio, let presenter = topViewController() else {
            router.player = nil
            return
        }
        let coordinator = PlayerCoordinator(request: request, putio: putio, app: app, router: router, localURL: localURL)
        PlayerCoordinator.current = coordinator
        coordinator.start(from: seconds, on: presenter)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// Runs one playback: the app's player screen, put.io progress sync, subtitles, next episode, Picture in Picture.
@MainActor
final class PlayerCoordinator {
    static var current: PlayerCoordinator?

    let request: PlayerRequest
    private let engine: PlayerEngine
    private let chrome: PlayerChrome
    private let controller: PlayerViewController
    private let session: PlaybackSession
    private let putio: any PutioService
    private let app: AppModel
    private let router: Router
    private var progressTask: Task<Void, Never>?
    /// No next-episode card or auto-play (a sleep timer set to "end of episode").
    private var countdownDismissed = false
    /// The user chose Watch Credits: the card comes back when the episode ends.
    private var creditsDismissed = false
    private var gettingNext: Task<Void, Never>?
    private var appliedLanguages = false
    private var inPictureInPicture = false
    /// Nothing more to try: the failure message is showing.
    private var gaveUp = false
    /// Which player to try next when one fails (nil for a file on this device).
    private let plan: PlaybackPlan?
    /// Deciding or switching players: no "can't play" handling meanwhile.
    private var routing = true
    private var rememberedSuccess = false
    private var triedOriginalMP4 = false
    /// Waiting for put.io to convert the video (no "can't play" errors meanwhile).
    private var converting = false
    private var conversionTask: Task<Void, Never>?
    private var startSeconds = 0
    private var finished = false
    /// Subtitles on the TV during AirPlay (the TV plays the stream itself and never sees the app's drawing).
    private let airPlaySubtitles: AirPlaySubtitleSwitcher
    private var resignObserver: NSObjectProtocol?

    init(request: PlayerRequest, putio: any PutioService, app: AppModel, router: Router, localURL: URL? = nil) {
        self.request = request
        self.putio = putio
        self.app = app
        self.router = router
        // With the entry, a file the library doesn't have yet (played from Files, a new transfer) still shows in
        // Continue Watching as soon as it's been watched a little.
        let entry = app.library.entries.first { $0.id == request.file.id } ?? LibraryEntry(
            file: request.file,
            match: request.played.map { LibraryMatch(tmdbID: $0.tmdbID, mediaType: $0.kind, season: request.season,
                                                     episode: request.episode, confidence: 1, title: $0.title) },
            folderName: nil)
        session = PlaybackSession(fileID: request.file.id, resumeFrom: request.resumeFrom, putio: putio,
                                  library: app.library, store: app.store, entry: entry, watchLog: app.watchLog)
        // Offline copy when downloaded; otherwise put.io's HLS stream in Apple's player, unless the routing picks the
        // built-in player (see start). An original-file download (a video Apple's player can't play) is the built-in
        // player's from the start.
        if let localURL, OfflineDownloader.isOriginalFile(localURL),
           let builtIn = BuiltInPlayer.backend(url: localURL, audioLanguage: app.settings.audioLanguage, refreshURL: nil) {
            engine = PlayerEngine(backend: builtIn)
        } else {
            engine = PlayerEngine(url: localURL ?? session.streamURL)
        }
        plan = localURL == nil ? BuiltInPlayer.plan(fileID: request.file.id, app: app) : nil
        let episode = request.season.map { season in request.episode.map { "Season \(season) · Episode \($0)" } ?? "Season \(season)" }
        chrome = PlayerChrome(title: request.played?.title ?? request.title, subtitle: episode,
                              subtitles: app.subtitleFinder(for: request.subtitleContext, fileSize: request.file.size))

        chrome.playingFromDevice = localURL != nil
        airPlaySubtitles = AirPlaySubtitleSwitcher(engine: engine, finder: chrome.subtitles, putio: putio, fileID: request.file.id,
                                                   plainStream: localURL == nil ? session.streamURL : nil,
                                                   fromDevice: localURL != nil)
        chrome.subtitleStyle = app.settings.subtitleStyle
        chrome.failureLink = localURL == nil ? URL(string: "https://app.put.io/files/\(request.file.id)") : nil
        controller = PlayerViewController(engine: engine, chrome: chrome)
    }

    func start(from seconds: Int, on presenter: UIViewController) {
        chrome.onClose = { [weak self] in self?.controller.dismiss(animated: true) }
        if let item = titleItem {
            chrome.detailsLabel = item.mediaType == .tv ? "Show details" : "Movie details"
            chrome.onDetails = { [weak self] in
                guard let self else { return }
                let router = router
                controller.dismiss(animated: true) { router.showTitle(item) }
            }
        }
        chrome.onNext = { [weak self] in self?.playNext() }
        chrome.onWatchCredits = { [weak self] in
            self?.creditsDismissed = true
            self?.chrome.nextUpCard = .hidden
        }
        chrome.onChooseNextVersion = { [weak self] in self?.chooseNextVersion() }
        chrome.onStyleChanged = { [weak app] style in app?.updateSubtitleStyle(style) }
        controller.onPiPChanged = { [weak self] active in
            guard let self else { return }
            inPictureInPicture = active
            // Picture in Picture frees the app: get the full-screen player out of the way.
            if active, controller.presentingViewController != nil { controller.dismiss(animated: true) }
        }
        controller.onPiPRestore = { [weak self] completion in
            guard let self, controller.presentingViewController == nil, let presenter = PlayerPresenter.topViewController() else {
                completion(true)
                return
            }
            presenter.present(controller, animated: true) { completion(true) }
        }
        engine.enableNowPlaying(title: chrome.title)
        // Pausing (or reaching the end) saves the position, for put.io and the other devices.
        engine.onPause = { [weak self] in self?.saveNow() }
        startSeconds = seconds
        presenter.present(controller, animated: true)
        Task { [weak self] in await self?.begin() }
        progressTask = Task { [weak self] in await self?.run() }
        // Leaving the app (Home, the app switcher) can suspend it before the next save: save the position now.
        resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        Task { [weak self] in await self?.findNextUp() }
        Task { await chrome.subtitles?.restore() }
    }

    private func run() async {
        var waitedForReady = 0
        while !Task.isCancelled, !finished {
            try? await Task.sleep(for: .seconds(1))
            if controller.presentingViewController == nil, !inPictureInPicture {
                finish()
                return
            }
            if converting {
                chrome.conversion = app.conversions.states[request.file.id] ?? chrome.conversion
                continue
            }
            let status = engine.status
            chrome.preparing = status != .ready && !gaveUp
            if routing { continue }
            airPlaySubtitles.update()
            // A stream switch for AirPlay subtitles handles its own failure (back to the plain stream).
            if airPlaySubtitles.isSwitching { continue }
            if status == .ready {
                waitedForReady = 0
                if !appliedLanguages, let apple = engine.backend as? AVPlayerBackend {
                    appliedLanguages = true
                    await apple.applyLanguagePreferences(audioLanguage: app.settings.audioLanguage)
                }
                if !rememberedSuccess {
                    rememberedSuccess = true
                    BuiltInPlayer.log.notice("file \(self.request.file.id): playing with \(self.engine.kind.rawValue)")
                    plan?.succeeded(engine.kind)
                }
            } else {
                waitedForReady += 1
            }
            // Apple's player not playing after 20 s: if put.io says the format needs converting, that's why.
            var stuck = false
            if engine.kind == .apple, waitedForReady == 20, plan != nil {
                stuck = await app.conversions.needsConversion(fileID: request.file.id)
            }
            if status.isFailed || stuck || (status != .ready && waitedForReady >= 60) {
                waitedForReady = 0
                await handleUnplayable()
            }
            let position = engine.position
            let total = engine.duration
            if position > 0 { await session.tick(seconds: position, duration: total) }
            let remaining = total > 0 ? total - position : .infinity
            applySleepTimer(position: position, duration: total)
            updateNextUpCard(remaining: remaining, duration: total)
        }
    }

    /// Fades the sound over the last 15 seconds, then pauses. "End of episode" also skips the next-episode countdown.
    private func applySleepTimer(position: Double, duration: Double) {
        guard let timer = chrome.sleepTimer else {
            if engine.volume < 1 { engine.volume = 1 }
            chrome.sleepLabel = nil
            return
        }
        let now = Date()
        chrome.sleepLabel = timer.label(now: now, position: position, duration: duration)
        engine.volume = timer.volume(now: now, position: position, duration: duration)
        if timer.option == .endOfEpisode { countdownDismissed = true }
        if timer.shouldStop(now: now, position: position, duration: duration) {
            engine.pause()
            engine.volume = 1
            chrome.sleepTimer = nil
            chrome.sleepLabel = nil
            chrome.nextUpCard = .hidden
            chrome.controlsVisible = true
        }
    }

    // MARK: Which player

    /// Picks the first player (Apple's on put.io's stream, or the built-in one on the original file when put.io's
    /// codec info says Apple's can't decode it, or it worked here before), then plays from the start point.
    private func begin() async {
        defer { routing = false }
        guard let plan else {
            engine.start(at: Double(startSeconds))
            return
        }
        let step = await plan.firstStep()
        BuiltInPlayer.log.notice("file \(self.request.file.id): first \(String(describing: step)), codecs \(String(describing: plan.verdict))")
        guard !finished else { return }
        if step == .play(.builtIn), await switchToBuiltIn() { return }
        engine.start(at: Double(startSeconds))
    }

    /// The player didn't play the video: the next one. Apple's → the built-in player on the original file → put.io's
    /// conversion (only when put.io says the format needs it) → a message.
    private func handleUnplayable() async {
        guard !gaveUp, !routing else { return }
        if chrome.playingFromDevice {
            giveUp("This download couldn't be played. Remove it and download it again, or stream it from put.io.")
            return
        }
        guard let plan else { return }
        routing = true
        defer { routing = false }
        let failed = engine.kind
        var step = await plan.step(afterFailureOf: failed)
        BuiltInPlayer.log.notice("file \(self.request.file.id): \(failed.rawValue) failed (\(String(describing: self.engine.status))), next \(String(describing: step))")
        while !finished {
            switch step {
            case let .play(next):
                let switched = if next == .builtIn { await switchToBuiltIn() } else { switchToApple() }
                if switched { return }
                // Couldn't even set it up (no link from put.io): count it as failed too.
                step = await plan.step(afterFailureOf: next)
            case .convert:
                startConversion()
                return
            case .fail:
                await fallBackOrGiveUp()
                return
            }
        }
    }

    /// The built-in player on the original file (put.io's download link; refreshed when it expires).
    private func switchToBuiltIn() async -> Bool {
        let putio = putio, fileID = request.file.id
        guard let original = try? await putio.originalURL(fileID: fileID), !finished,
              let builtIn = BuiltInPlayer.backend(url: original, audioLanguage: app.settings.audioLanguage,
                                                  refreshURL: { try? await putio.originalURL(fileID: fileID) }) else { return false }
        engine.switchTo(builtIn, at: resumePoint)
        rememberedSuccess = false
        chrome.failure = nil
        return true
    }

    private func switchToApple() -> Bool {
        airPlaySubtitles.plainStream = session.streamURL
        engine.switchTo(AVPlayerBackend(url: session.streamURL), at: resumePoint)
        appliedLanguages = false
        rememberedSuccess = false
        return true
    }

    /// Where a new player starts: where this one got to, or where playback was meant to start.
    private var resumePoint: Double { max(engine.position, Double(startSeconds)) }

    /// Nothing else to try. An MP4 put.io doesn't stream yet may still play from the original file in Apple's player.
    private func fallBackOrGiveUp() async {
        if !triedOriginalMP4, request.file.contentType == "video/mp4", let original = try? await putio.originalURL(fileID: request.file.id) {
            triedOriginalMP4 = true
            // Not an HLS stream: AirPlay plays the file as it is, without subtitles.
            airPlaySubtitles.plainStream = nil
            engine.switchTo(AVPlayerBackend(url: original), at: resumePoint)
            return
        }
        giveUp("This video isn't ready to stream yet. Try again in a few minutes.")
    }

    private func giveUp(_ message: String) {
        gaveUp = true
        chrome.preparing = false
        chrome.failure = message
    }

    /// put.io converts the video for Apple devices (the player shows how far), then Apple's player plays it from where
    /// it was meant to start. The last resort: only after the built-in player couldn't play it either (or with
    /// "Convert with put.io" in Settings). The wait runs on its own, so closing the player is never held up by it (the
    /// conversion carries on at put.io and shows again when the video is reopened).
    private func startConversion() {
        guard !converting, !finished else { return }
        converting = true
        engine.pause()
        chrome.preparing = false
        chrome.failure = nil
        chrome.conversion = app.conversions.states[request.file.id] ?? .queued
        let app = app, fileID = request.file.id
        conversionTask = Task { [weak self] in
            let ok = await app.conversions.makePlayable(fileID: fileID)
            guard let self, !self.finished, !Task.isCancelled else { return }
            self.conversionDone(ok)
        }
    }

    private func conversionDone(_ ok: Bool) {
        converting = false
        conversionTask = nil
        chrome.conversion = nil
        if ok {
            _ = switchToApple()
        } else {
            giveUp("put.io couldn't convert this video for Apple devices. Try another version of it.")
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        progressTask?.cancel()
        gettingNext?.cancel()
        conversionTask?.cancel()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        engine.onPause = nil
        saveNow()
        airPlaySubtitles.tearDown()
        engine.tearDown()
        if router.player?.id == request.id { router.player = nil }
        if Self.current === self { Self.current = nil }
    }

    /// Saves where playback is now (in the library at once, then to put.io), finishing even if the app is leaving.
    private func saveNow() {
        let position = engine.position
        let duration = engine.duration
        guard position > 0 else { return }
        let session = session
        BackgroundSave.run("Save playback position") { await session.finish(seconds: position, duration: duration) }
    }

    // MARK: Next episode (Netflix-style)

    /// What comes after this episode, from TMDB, wherever playback started.
    private func findNextUp() async {
        guard let played = request.played, played.kind == .tv, let season = request.season, let episode = request.episode else { return }
        let next = await NextUpFinder.find(tmdbID: played.tmdbID, season: season, episode: episode, catalog: app.catalog,
                                           library: app.library)
        chrome.nextUp = next
        chrome.nextLabel = next?.label
    }

    /// The card shows when the credits start (or at the end after Watch Credits), and hides if you seek back.
    private func updateNextUpCard(remaining: Double, duration: Double) {
        chrome.nextUpAutoplay = app.settings.autoPlayNextEpisode && !countdownDismissed
        if let next = chrome.nextUp, !next.isInPutio, chrome.nextUpGetting == nil {
            let resolved = next.resolved(in: app.library)
            if resolved != next { chrome.nextUp = resolved }
        }
        guard chrome.nextUp != nil, duration > 0, !countdownDismissed || chrome.nextUpGetting != nil else {
            if chrome.nextUpCard != .hidden { chrome.nextUpCard = .hidden }
            return
        }
        let credits = NextUp.creditsLength(duration: duration)
        let state: NextUpCardState
        if remaining < 1.5 {
            state = .end
        } else if remaining <= credits {
            state = creditsDismissed && chrome.nextUpGetting == nil ? .hidden : .credits
        } else {
            creditsDismissed = false
            state = chrome.nextUpGetting != nil ? .credits : .hidden
        }
        if chrome.nextUpCard != state { chrome.nextUpCard = state }
    }

    /// In put.io: play it. Not yet: send the best version to put.io and play it as soon as it's ready.
    /// The movie or show being played (from the library when it knows the file, with its artwork).
    private var titleItem: CatalogItem? {
        if let item = app.library.entries.first(where: { $0.id == request.file.id })?.titleItem { return item }
        return request.played.map { CatalogItem(tmdbID: $0.tmdbID, mediaType: $0.kind, title: $0.title) }
    }

    private func playNext() {
        guard let next = chrome.nextUp else { return }
        if let entry = next.entry {
            let app = app, router = router
            controller.dismiss(animated: true) {
                router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry))
            }
            return
        }
        guard gettingNext == nil, let query = next.query else {
            if next.query == nil { chrome.nextUpGetting = .failed("Couldn't look this episode up. Try from the show's page.") }
            return
        }
        chrome.nextUpGetting = .searching
        gettingNext = Task { [weak self] in
            guard let self else { return }
            switch await app.smartGet(query, target: next.target) {
            case .sent:
                await waitForNext(next)
            case .noMatch:
                chrome.nextUpGetting = .failed("No good version found automatically.")
            case .failed:
                chrome.nextUpGetting = .failed("Couldn't send it to put.io.")
            }
            gettingNext = nil
        }
    }

    private func waitForNext(_ next: NextUp) async {
        while !Task.isCancelled, !finished {
            if let transfer = app.transfers.latest(tmdbID: next.target.tmdbID, season: next.season, episode: next.episode) {
                if transfer.playableFile != nil {
                    let router = router
                    controller.dismiss(animated: true) { router.play(transfer) }
                    return
                }
                if case .failed = transfer.phase {
                    chrome.nextUpGetting = .failed("put.io couldn't download this version.")
                    return
                }
                chrome.nextUpGetting = .downloading(percent: transfer.percent)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func chooseNextVersion() {
        guard let next = chrome.nextUp, let query = next.query else { return }
        let router = router
        controller.dismiss(animated: true) {
            router.versions = VersionsRequest(query: query, target: next.target, playNow: [])
        }
    }

}
