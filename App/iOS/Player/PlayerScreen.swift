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
    private var countdownDismissed = false
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
        chrome.nextLabel = request.next?.label
        chrome.playingFromDevice = localURL != nil
        chrome.subtitleStyle = app.settings.subtitleStyle
        chrome.failureLink = URL(string: "https://app.put.io/files/\(request.file.id)")
        controller = PlayerViewController(engine: engine, chrome: chrome)
    }

    func start(from seconds: Int, on presenter: UIViewController) {
        chrome.onClose = { [weak self] in self?.controller.dismiss(animated: true) }
        chrome.onNext = { [weak self] in
            guard let self, let next = request.next else { return }
            advance(to: next)
        }
        chrome.onStyleChanged = { [weak app] style in app?.updateSubtitleStyle(style) }
        chrome.onCancelCountdown = { [weak self] in
            self?.countdownDismissed = true
            self?.chrome.showCountdown = false
        }
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
            chrome.showNextButton = request.next != nil && remaining < 30
            if remaining < 1.5, request.next != nil, app.settings.autoPlayNextEpisode, !countdownDismissed {
                chrome.showCountdown = true
            }
        }
    }

    private func handleUnplayable() async {
        guard !triedFallback else { return }
        triedFallback = true
        if request.file.contentType == "video/mp4", let original = try? await putio.originalURL(fileID: request.file.id) {
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

    private func advance(to next: NextEpisode) {
        let app = app, router = router
        controller.dismiss(animated: true) {
            let library = app.library
            if let entry = library.matching(tmdbID: next.target.tmdbID, season: next.target.season, episode: next.target.episode).first {
                router.play(entry, resumeFrom: library.resumeSeconds(for: entry))
            } else if let query = next.query {
                router.versions = VersionsRequest(query: query, target: next.target, playNow: [])
            }
        }
    }
}
