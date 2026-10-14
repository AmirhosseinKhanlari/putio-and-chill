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
    private var triedFallback = false
    private var finished = false

    init(request: PlayerRequest, putio: any PutioService, app: AppModel, router: Router, localURL: URL? = nil) {
        self.request = request
        self.putio = putio
        self.app = app
        self.router = router
        session = PlaybackSession(fileID: request.file.id, resumeFrom: request.resumeFrom, putio: putio,
                                  library: app.library, store: app.store)
        // Offline copy when downloaded; otherwise put.io's HLS stream.
        engine = PlayerEngine(url: localURL ?? session.streamURL)
        let episode = request.season.map { season in request.episode.map { "Season \(season) · Episode \($0)" } ?? "Season \(season)" }
        chrome = PlayerChrome(title: request.played?.title ?? request.title, subtitle: episode,
                              subtitles: app.subtitleFinder(for: request.subtitleContext, fileSize: request.file.size))

        chrome.playingFromDevice = localURL != nil
        chrome.subtitleStyle = app.settings.subtitleStyle
        chrome.failureLink = localURL == nil ? URL(string: "https://app.put.io/files/\(request.file.id)") : nil
        controller = PlayerViewController(engine: engine, chrome: chrome)
    }

    func start(from seconds: Int, on presenter: UIViewController) {
        chrome.onClose = { [weak self] in self?.controller.dismiss(animated: true) }
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
        if seconds > 0 { engine.seek(to: Double(seconds)) }
        presenter.present(controller, animated: true) { [engine] in engine.play() }
        progressTask = Task { [weak self] in await self?.run() }
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
            let status = engine.status
            chrome.preparing = status != .readyToPlay && !triedFallback
            if status == .readyToPlay, !appliedLanguages, let item = engine.player.currentItem {
                appliedLanguages = true
                await applyLanguagePreferences(to: item)
            }
            if status != .readyToPlay { waitedForReady += 1 }
            if status == .failed || (status != .readyToPlay && waitedForReady >= 60) {
                await handleUnplayable()
                waitedForReady = 0
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
            if engine.player.volume < 1 { engine.player.volume = 1 }
            chrome.sleepLabel = nil
            return
        }
        let now = Date()
        chrome.sleepLabel = timer.label(now: now, position: position, duration: duration)
        engine.player.volume = timer.volume(now: now, position: position, duration: duration)
        if timer.option == .endOfEpisode { countdownDismissed = true }
        if timer.shouldStop(now: now, position: position, duration: duration) {
            engine.pause()
            engine.player.volume = 1
            chrome.sleepTimer = nil
            chrome.sleepLabel = nil
            chrome.nextUpCard = .hidden
            chrome.controlsVisible = true
        }
    }

    private func handleUnplayable() async {
        guard !triedFallback else { return }
        triedFallback = true
        if chrome.playingFromDevice {
            chrome.preparing = false
            chrome.failure = "This download couldn't be played. Remove it and download it again, or stream it from put.io."
        } else if request.file.contentType == "video/mp4", let original = try? await putio.originalURL(fileID: request.file.id) {
            engine.replace(with: original)
        } else {
            chrome.preparing = false
            chrome.failure = "This video isn't ready to stream yet. Try again in a few minutes."
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        progressTask?.cancel()
        gettingNext?.cancel()
        let position = engine.position
        let duration = engine.duration
        engine.tearDown()
        let session = session
        if position > 0 {
            Task { await session.finish(seconds: position, duration: duration) }
        }
        if router.player?.id == request.id { router.player = nil }
        if Self.current === self { Self.current = nil }
    }

    /// Picks the preferred audio track (Settings → Playback). Subtitles are drawn by the app (put.io + OpenSubtitles),
    /// so any subtitle track inside the stream (older offline copies) stays off.
    private func applyLanguagePreferences(to item: AVPlayerItem) async {
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), group.allowsEmptySelection {
            item.select(nil, in: group)
        }
        if let language = app.settings.audioLanguage, let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
           let index = LanguageMatcher.bestIndex(available: group.options.map { $0.extendedLanguageTag ?? $0.locale?.identifier },
                                                 preferred: language) {
            item.select(group.options[index], in: group)
        }
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
