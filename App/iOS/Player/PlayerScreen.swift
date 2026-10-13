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

@MainActor
final class PlayerCoordinator: NSObject, @MainActor AVPlayerViewControllerDelegate, @MainActor UIGestureRecognizerDelegate {
    static var current: PlayerCoordinator?

    let request: PlayerRequest
    private let controller = AVPlayerViewController()
    private let session: PlaybackSession
    private let putio: any PutioService
    private let app: AppModel
    private let router: Router
    private var progressTask: Task<Void, Never>?
    private var nextHost: UIViewController?
    private var preparingHost: UIViewController?
    private var countdownHost: UIViewController?
    private var countdownDismissed = false
    private var appliedLanguages = false
    private var inPictureInPicture = false
    private var triedFallback = false
    private var finished = false
    private let localURL: URL?
    private let subtitles: SubtitleFinder
    private let subtitleLine = SubtitleLine()
    private var subtitleButtonHost: UIViewController?
    private var subtitleButtonHideTask: Task<Void, Never>?
    private var timeObserver: Any?

    init(request: PlayerRequest, putio: any PutioService, app: AppModel, router: Router, localURL: URL? = nil) {
        self.request = request
        self.putio = putio
        self.app = app
        self.router = router
        self.localURL = localURL
        session = PlaybackSession(fileID: request.file.id, resumeFrom: request.resumeFrom, putio: putio,
                                  library: app.library, store: app.store)
        subtitles = app.subtitleFinder(for: request.subtitleContext, fileSize: request.file.size)
    }

    func start(from seconds: Int, on presenter: UIViewController) {
        // Offline copy when downloaded; otherwise put.io's HLS stream.
        let player = AVPlayer(url: localURL ?? session.streamURL)
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        controller.modalPresentationStyle = .fullScreen
        if seconds > 0 { player.seek(to: CMTime(seconds: Double(seconds), preferredTimescale: 600)) }
        presenter.present(controller, animated: true) { player.play() }
        progressTask = Task { [weak self] in await self?.run() }
        installSubtitles(on: player)
    }

    private func run() async {
        var waitedForReady = 0
        while !Task.isCancelled, !finished {
            try? await Task.sleep(for: .seconds(1))
            guard let player = controller.player else { continue }
            if controller.presentingViewController == nil, !inPictureInPicture {
                finish()
                return
            }
            let status = player.currentItem?.status
            updatePreparingLabel(visible: status != .readyToPlay && !triedFallback)
            if status == .readyToPlay, !appliedLanguages, let item = player.currentItem {
                appliedLanguages = true
                await applyLanguagePreferences(to: item)
            }
            if status != .readyToPlay { waitedForReady += 1 }
            if status == .failed || (status != .readyToPlay && waitedForReady >= 60) {
                await handleUnplayable()
                waitedForReady = 0
            }
            let position = player.currentTime().seconds
            let duration = player.currentItem?.duration.seconds ?? 0
            let total = duration.isFinite ? duration : 0
            if position.isFinite, position > 0 { await session.tick(seconds: position, duration: total) }
            let remaining = total > 0 && position.isFinite ? total - position : .infinity
            updateNextButton(remaining: remaining)
            if remaining < 1.5 { showNextEpisodeCountdown() }
        }
    }

    private func handleUnplayable() async {
        guard !triedFallback else { return }
        triedFallback = true
        if request.file.contentType == "video/mp4", let original = try? await putio.originalURL(fileID: request.file.id) {
            controller.player?.replaceCurrentItem(with: AVPlayerItem(url: original))
            controller.player?.play()
        } else {
            updatePreparingLabel(visible: false)
            showFailure("This video isn't ready to stream yet. Try again in a few minutes.")
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        progressTask?.cancel()
        subtitleButtonHideTask?.cancel()
        let player = controller.player
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        let position = player?.currentTime().seconds ?? 0
        let duration = player?.currentItem?.duration.seconds ?? 0
        let session = session
        if position.isFinite, position > 0 {
            Task { await session.finish(seconds: position, duration: duration.isFinite ? duration : 0) }
        }
        if router.player?.id == request.id { router.player = nil }
        if Self.current === self { Self.current = nil }
    }

    // MARK: Overlays

    private func updateNextButton(remaining: Double) {
        guard let next = request.next else { return }
        if remaining < 30, nextHost == nil {
            let button = Button { [weak self] in self?.advance(to: next) } label: {
                Label("Next: \(next.label)", systemImage: "forward.end.fill")
            }
            .buttonStyle(.primaryPill)
            .padding(4)
            let host = UIHostingController(rootView: AnyView(button))
            host.sizingOptions = .intrinsicContentSize
            embed(host) { view, container in
                [view.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -32),
                 view.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -96)]
            }
            nextHost = host
        } else if remaining >= 30, let host = nextHost {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            nextHost = nil
        }
    }

    /// Picks the preferred audio and subtitle tracks (Settings → Playback); subtitles off when none is chosen.
    /// An OpenSubtitles pick for this file replaces put.io's subtitle tracks.
    private func applyLanguagePreferences(to item: AVPlayerItem) async {
        let settings = app.settings
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            if subtitles.track != nil, group.allowsEmptySelection {
                item.select(nil, in: group)
            } else if let language = settings.subtitleLanguage,
               let index = LanguageMatcher.bestIndex(available: group.options.map { $0.extendedLanguageTag ?? $0.locale?.identifier },
                                                     preferred: language) {
                item.select(group.options[index], in: group)
            } else if settings.subtitleLanguage == nil, group.allowsEmptySelection {
                item.select(nil, in: group)
            }
        }
        if let language = settings.audioLanguage, let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
           let index = LanguageMatcher.bestIndex(available: group.options.map { $0.extendedLanguageTag ?? $0.locale?.identifier },
                                                 preferred: language) {
            item.select(group.options[index], in: group)
        }
    }

    /// End of an episode: "Next episode in 5…" with Play Now / Cancel (Settings → Auto-play next episode).
    private func showNextEpisodeCountdown() {
        guard let next = request.next, app.settings.autoPlayNextEpisode, countdownHost == nil, !countdownDismissed else { return }
        let view = NextEpisodeCountdown(label: next.label,
                                        onPlay: { [weak self] in self?.advance(to: next) },
                                        onCancel: { [weak self] in self?.dismissCountdown() })
        let host = UIHostingController(rootView: AnyView(view))
        embed(host) { view, container in
            [view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
             view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
             view.topAnchor.constraint(equalTo: container.topAnchor),
             view.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
        }
        countdownHost = host
    }

    private func dismissCountdown() {
        countdownDismissed = true
        guard let host = countdownHost else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        countdownHost = nil
    }

    private func updatePreparingLabel(visible: Bool) {
        if visible, preparingHost == nil {
            let label = Text("Preparing…").font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 14).padding(.vertical, 7).glassCapsule()
            let host = UIHostingController(rootView: AnyView(label))
            host.sizingOptions = .intrinsicContentSize
            host.view.isUserInteractionEnabled = false
            embed(host) { view, container in
                [view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                 view.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 90)]
            }
            preparingHost = host
        } else if !visible, let host = preparingHost {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            preparingHost = nil
        }
    }

    private func showFailure(_ message: String) {
        let fileID = request.file.id
        let view = PlayerFailureView(message: message, fileID: fileID) { [weak self] in self?.controller.dismiss(animated: true) }
        embed(UIHostingController(rootView: AnyView(view))) { view, container in
            [view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
             view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
             view.topAnchor.constraint(equalTo: container.topAnchor),
             view.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
        }
    }

    private func embed(_ host: UIViewController, constraints: (UIView, UIView) -> [NSLayoutConstraint]) {
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        controller.addChild(host)
        controller.view.addSubview(host.view)
        NSLayoutConstraint.activate(constraints(host.view, controller.view))
        host.didMove(toParent: controller)
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

    // MARK: OpenSubtitles

    private func installSubtitles(on player: AVPlayer) {
        let overlay = UIHostingController(rootView: SubtitleOverlayView(line: subtitleLine))
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        if let content = controller.contentOverlayView {
            overlay.view.frame = content.bounds
            overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.addChild(overlay)
            content.addSubview(overlay.view)
            overlay.didMove(toParent: controller)
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let text = self.subtitles.text(at: time.seconds)
                if self.subtitleLine.text != text { self.subtitleLine.text = text }
                // videoBounds is in the player view's space; the overlay lives in contentOverlayView.
                let bounds = self.controller.contentOverlayView.map {
                    self.controller.view.convert(self.controller.videoBounds, to: $0)
                } ?? self.controller.videoBounds
                if self.subtitleLine.videoBounds != bounds { self.subtitleLine.videoBounds = bounds }
            }
        }
        Task { await subtitles.restore() }
        guard subtitles.isAvailable else { return }
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.sizingOptions = .intrinsicContentSize
        subtitleButtonHost = host
        refreshSubtitleButton()
        embed(host) { view, container in
            [view.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -20),
             view.centerYAnchor.constraint(equalTo: container.centerYAnchor)]
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(playerTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        controller.view.addGestureRecognizer(tap)
        showSubtitleButton()
    }

    private func refreshSubtitleButton() {
        (subtitleButtonHost as? UIHostingController<AnyView>)?.rootView = AnyView(
            SubtitlesButton(active: subtitles.track != nil) { [weak self] in self?.openSubtitleSheet() }
        )
    }

    /// AVKit shows its controls on tap and hides them after a few seconds; the button follows the same rhythm.
    @objc private func playerTapped() {
        guard let view = subtitleButtonHost?.view else { return }
        if view.alpha > 0.5 { hideSubtitleButton() } else { showSubtitleButton() }
    }

    private func showSubtitleButton() {
        guard let view = subtitleButtonHost?.view else { return }
        UIView.animate(withDuration: 0.2) { view.alpha = 1 }
        subtitleButtonHideTask?.cancel()
        subtitleButtonHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hideSubtitleButton()
        }
    }

    private func hideSubtitleButton() {
        subtitleButtonHideTask?.cancel()
        guard let view = subtitleButtonHost?.view else { return }
        UIView.animate(withDuration: 0.25) { view.alpha = 0 }
    }

    private func openSubtitleSheet() {
        subtitleButtonHideTask?.cancel()
        let sheet = UIHostingController(rootView: SubtitleSheet(finder: subtitles) { [weak self] in
            Task { @MainActor in await self?.useOpenSubtitles() }
        })
        sheet.modalPresentationStyle = .pageSheet
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        sheet.presentationController?.delegate = self
        controller.present(sheet, animated: true)
    }

    /// Turns off put.io's own subtitle track so the two don't stack.
    private func useOpenSubtitles() async {
        refreshSubtitleButton()
        guard let item = controller.player?.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), group.allowsEmptySelection else { return }
        item.select(nil, in: group)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let button = subtitleButtonHost?.view, let touched = touch.view else { return true }
        return !touched.isDescendant(of: button)
    }

    // MARK: Picture in Picture

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = false
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard controller.presentingViewController == nil, let presenter = PlayerPresenter.topViewController() else {
            completionHandler(true)
            return
        }
        presenter.present(controller, animated: true) { completionHandler(true) }
    }
}

extension PlayerCoordinator: @MainActor UIAdaptivePresentationControllerDelegate {
    /// Subtitle sheet closed (swipe or Done): refresh the button and show it briefly.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        refreshSubtitleButton()
        showSubtitleButton()
    }
}

private struct PlayerFailureView: View {
    let message: String
    let fileID: Int64
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(message).multilineTextAlignment(.center)
                Link("Open in put.io", destination: URL(string: "https://app.put.io/files/\(fileID)")!)
                    .buttonStyle(.glassPill)
                Button("Close", action: close).buttonStyle(.primaryPill)
            }
            .padding(28)
            .glassRounded(24)
            .padding(40)
        }
    }
}

private struct NextEpisodeCountdown: View {
    let label: String
    let onPlay: () -> Void
    let onCancel: () -> Void
    @State private var remaining = 5
    @State private var started = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    ProgressRing(progress: Double(5 - remaining) / 5, lineWidth: 5)
                    Text("\(remaining)").font(.system(size: 34, weight: .ultraLight)).monospacedDigit()
                }
                .frame(width: 88, height: 88)
                Text("Next episode").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.white.opacity(0.7))
                Text(label).font(.title3.weight(.semibold))
                HStack(spacing: 12) {
                    Button { go() } label: { Label("Play Now", systemImage: "play.fill") }.buttonStyle(.primaryPill)
                    Button("Cancel", action: onCancel).buttonStyle(.glassPill)
                }
            }
            .padding(32)
            .glassRounded(28)
        }
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                remaining -= 1
            }
            go()
        }
    }

    private func go() {
        guard !started else { return }
        started = true
        onPlay()
    }
}
