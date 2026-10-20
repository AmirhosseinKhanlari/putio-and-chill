import AMDBKit
import AVKit
import UIKit

/// A view whose backing layer is the AVPlayerLayer.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Apple's player: put.io's HLS stream (or a downloaded copy) in an AVPlayer. AirPlay video, the system's
/// Picture in Picture and media selection all work here.
@MainActor
final class AVPlayerBackend: PlayerBackend {
    let kind = PlaybackEngineKind.apple
    let player: AVPlayer
    private let layerView = PlayerLayerView()
    private weak var engine: PlayerEngine?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var audioGroup: AVMediaSelectionGroup?
    private var audioOptions: [AVMediaSelectionOption] = []

    var videoView: UIView { layerView }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    init(url: URL) {
        player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
        layerView.playerLayer.player = player
        layerView.playerLayer.videoGravity = .resizeAspect
    }

    func attach(to engine: PlayerEngine) {
        self.engine = engine
        let status = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let value = player.timeControlStatus
            Task { @MainActor in self?.timeControlChanged(value) }
        }
        playerObservations = [status]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        observeItem()
    }

    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playerObservations.forEach { $0.invalidate() }
        itemObservations.forEach { $0.invalidate() }
        engine = nil
    }

    // MARK: Controls

    func start(at seconds: Double, rate: Float) {
        if seconds > 0 { seek(to: seconds) {} }
        play(rate: rate)
    }

    func play(rate: Float) { player.playImmediately(atRate: rate) }
    func pause() { player.pause() }

    func seek(to seconds: Double, completion: @escaping @Sendable @MainActor () -> Void) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in completion() }
        }
    }

    func setRate(_ rate: Float, playing: Bool) {
        player.defaultRate = rate
        if playing { player.rate = rate }
    }

    func selectAudio(id: String) {
        guard let index = Int(id), audioOptions.indices.contains(index), let audioGroup, let item = player.currentItem else { return }
        item.select(audioOptions[index], in: audioGroup)
    }

    func selectEmbeddedSubtitle(id: Int?) {}

    func setFill(_ fill: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        layerView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        CATransaction.commit()
    }

    func makePictureInPicture() -> AVPictureInPictureController? {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        return AVPictureInPictureController(playerLayer: layerView.playerLayer)
    }

    func pictureInPictureChanged(active: Bool) {}

    /// Picks the preferred audio track (Settings → Playback). Subtitles are drawn by the app (put.io + OpenSubtitles),
    /// so any subtitle track inside the stream (older offline copies) stays off.
    func applyLanguagePreferences(audioLanguage: String?) async {
        guard let item = player.currentItem else { return }
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), group.allowsEmptySelection {
            item.select(nil, in: group)
        }
        if let audioLanguage, let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
           let index = LanguageMatcher.bestIndex(available: group.options.map { $0.extendedLanguageTag ?? $0.locale?.identifier },
                                                 preferred: audioLanguage) {
            item.select(group.options[index], in: group)
            engine?.currentAudioID = String(index)
        }
    }

    /// Switches to another URL (the original file when HLS isn't ready, or the converted stream), keeping the position.
    func replace(with url: URL, at seconds: Double, rate: Float) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        engine?.status = .loading
        observeItem()
        start(at: seconds, rate: rate)
    }

    // MARK: Observation

    private func observeItem() {
        itemObservations.forEach { $0.invalidate() }
        guard let item = player.currentItem else { return }
        itemObservations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let value = item.status
                let message = item.error?.localizedDescription
                Task { @MainActor in self?.statusChanged(value, message: message) }
            },
            item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
                let size = item.presentationSize
                Task { @MainActor in self?.engine?.presentationSize = size }
            },
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
                let end = item.loadedTimeRanges.map(\.timeRangeValue).map { CMTimeRangeGetEnd($0).seconds }.max() ?? 0
                Task { @MainActor in self?.engine?.buffered = end.isFinite ? end : 0 }
            },
        ]
    }

    private func timeControlChanged(_ value: AVPlayer.TimeControlStatus) {
        engine?.report(playing: value != .paused, buffering: value == .waitingToPlayAtSpecifiedRate)
    }

    private func statusChanged(_ value: AVPlayerItem.Status, message: String?) {
        guard let engine else { return }
        switch value {
        case .readyToPlay:
            guard let item = player.currentItem else { return }
            engine.reportDuration(item.duration.seconds)
            Task { await confirmDecodable(item) }
        case .failed:
            engine.status = .failed(message)
        default:
            engine.status = .loading
        }
    }

    /// "Ready to play" isn't enough: AVFoundation also gets there with a video it can open but not decode (an old
    /// codec), and then runs the clock over a black picture. Such a file counts as failed, so the next player gets it.
    private func confirmDecodable(_ item: AVPlayerItem) async {
        let asset = item.asset
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var videoOK = true
        for track in video where (try? await track.load(.isDecodable)) == false { videoOK = false }
        var audioOK = audio.isEmpty
        for track in audio where (try? await track.load(.isDecodable)) != false { audioOK = true }
        guard let engine, item === player.currentItem else { return }
        if videoOK, audioOK {
            engine.status = .ready
            await loadAudioOptions()
        } else {
            engine.status = .failed(videoOK ? "Apple's player can't decode this video's sound." : "Apple's player can't decode this video.")
        }
    }

    private func loadAudioOptions() async {
        guard let item = player.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
        audioGroup = group
        audioOptions = group.options
        engine?.audioTracks = group.options.enumerated().map { PlayerAudioTrack(id: String($0.offset), name: $0.element.displayName) }
        if let selected = item.currentMediaSelection.selectedMediaOption(in: group), let index = group.options.firstIndex(of: selected) {
            engine?.currentAudioID = String(index)
        }
    }

    private func tick(_ time: CMTime) {
        guard let engine else { return }
        let seconds = time.seconds
        if seconds.isFinite { engine.position = seconds }
        if engine.duration == 0, let itemDuration = player.currentItem?.duration.seconds { engine.reportDuration(itemDuration) }
    }
}
