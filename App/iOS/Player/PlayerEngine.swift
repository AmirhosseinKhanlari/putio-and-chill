import AVFoundation
import MediaPlayer
import Observation

/// Playback state for the app's own player controls: wraps AVPlayer and publishes what the controls draw.
/// Also feeds the Lock Screen / Control Center "Now Playing" controls.
@Observable @MainActor
final class PlayerEngine {
    let player: AVPlayer
    private(set) var isPlaying = false
    private(set) var isBuffering = true
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var buffered: Double = 0
    private(set) var presentationSize: CGSize = .zero
    private(set) var status: AVPlayerItem.Status = .unknown
    private(set) var audioOptions: [AVMediaSelectionOption] = []
    private(set) var currentAudio: AVMediaSelectionOption?
    /// Speed used whenever playback runs.
    var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
            updateNowPlaying()
        }
    }

    /// Playback stopped (the user paused, or it ended): a moment to save the position.
    @ObservationIgnored var onPause: (() -> Void)?
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var nowPlayingTitle: String?
    @ObservationIgnored private var remoteTargets: [Any] = []

    init(url: URL) {
        player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
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
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
                        center.skipBackwardCommand, center.changePlaybackPositionCommand] {
            command.removeTarget(nil)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Controls

    func play() { player.playImmediately(atRate: rate) }
    func pause() { player.pause() }
    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func skip(by seconds: Double) { seek(to: position + seconds) }

    func selectAudio(_ option: AVMediaSelectionOption) {
        guard let audioGroup, let item = player.currentItem else { return }
        item.select(option, in: audioGroup)
        currentAudio = option
    }

    /// Switches to another URL (the original file when HLS isn't ready), keeping the position.
    func replace(with url: URL) {
        let resumeAt = position
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        observeItem()
        if resumeAt > 0 { seek(to: resumeAt) }
        play()
    }

    // MARK: Now Playing

    func enableNowPlaying(title: String) {
        nowPlayingTitle = title
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlay() }; return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(by: 10) }; return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(by: -10) }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard let nowPlayingTitle else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
    }

    // MARK: Observation

    private func observeItem() {
        itemObservations.forEach { $0.invalidate() }
        guard let item = player.currentItem else { return }
        itemObservations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let value = item.status
                Task { @MainActor in self?.statusChanged(value) }
            },
            item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
                let size = item.presentationSize
                Task { @MainActor in self?.presentationSize = size }
            },
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
                let end = item.loadedTimeRanges.map(\.timeRangeValue).map { CMTimeRangeGetEnd($0).seconds }.max() ?? 0
                Task { @MainActor in self?.buffered = end.isFinite ? end : 0 }
            },
        ]
    }

    private func timeControlChanged(_ value: AVPlayer.TimeControlStatus) {
        if value == .paused, isPlaying { onPause?() }
        isPlaying = value != .paused
        isBuffering = value == .waitingToPlayAtSpecifiedRate
        updateNowPlaying()
    }

    private func statusChanged(_ value: AVPlayerItem.Status) {
        status = value
        guard value == .readyToPlay, let item = player.currentItem else { return }
        let seconds = item.duration.seconds
        if seconds.isFinite { duration = seconds }
        updateNowPlaying()
        Task { await loadAudioOptions(item) }
    }

    private func loadAudioOptions(_ item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
        audioGroup = group
        audioOptions = group.options
        currentAudio = item.currentMediaSelection.selectedMediaOption(in: group)
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite { position = seconds }
        if duration == 0, let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
    }
}
