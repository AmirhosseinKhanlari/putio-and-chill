import AMDBKit
import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Playback state for the app's own player controls, whichever player plays: Apple's or the built-in one (see
/// PlayerBackend). Publishes what the controls draw, passes their commands on, and can switch players mid-way
/// (Apple's failed: the built-in player takes over at the same position). Also feeds Lock Screen / Control Center
/// "Now Playing".
@Observable @MainActor
final class PlayerEngine {
    private(set) var backend: any PlayerBackend
    var kind: PlaybackEngineKind { backend.kind }

    // Reported by the backend.
    private(set) var isPlaying = false
    private(set) var isBuffering = true
    var position: Double = 0
    var duration: Double = 0
    var buffered: Double = 0
    var presentationSize: CGSize = .zero
    var status: PlayerStatus = .loading
    var audioTracks: [PlayerAudioTrack] = []
    var currentAudioID: String?
    /// Subtitle tracks inside the file (built-in player), and the one showing.
    var embeddedSubtitles: [PlayerSubtitleTrack] = []
    var embeddedSubtitleID: Int?
    var embeddedSubtitle: EmbeddedSubtitle?
    /// Shown while AirPlay is the audio route on the built-in player: only the sound goes to the receiver.
    var airPlayNotice: String?

    /// Speed used whenever playback runs.
    var rate: Float = 1 {
        didSet {
            backend.setRate(rate, playing: isPlaying)
            updateNowPlaying()
        }
    }
    /// The sleep timer fades the sound out with this.
    var volume: Float = 1 { didSet { backend.volume = volume } }

    /// Playback stopped (the user paused, or it ended): a moment to save the position.
    @ObservationIgnored var onPause: (() -> Void)?
    /// The player changed (the screen swaps the picture and rebuilds Picture in Picture).
    @ObservationIgnored var onBackendChanged: (() -> Void)?
    /// The picture's layer changed within the same player (the built-in one moved to its software path).
    @ObservationIgnored var onPictureSourceChanged: (() -> Void)?
    @ObservationIgnored private var nowPlayingTitle: String?
    @ObservationIgnored private var commandsRegistered = false

    init(backend: any PlayerBackend) {
        self.backend = backend
        backend.attach(to: self)
    }

    /// Apple's player on `url` (put.io's stream or a downloaded HLS copy).
    convenience init(url: URL) { self.init(backend: AVPlayerBackend(url: url)) }

    func tearDown() {
        backend.tearDown()
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
                        center.skipBackwardCommand, center.changePlaybackPositionCommand] {
            command.removeTarget(nil)
        }
        commandsRegistered = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Controls

    func start(at seconds: Double) {
        position = seconds
        backend.start(at: seconds, rate: rate)
    }

    func play() { backend.play(rate: rate) }
    func pause() { backend.pause() }
    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        position = target
        backend.seek(to: target) { [weak self] in self?.updateNowPlaying() }
    }

    func skip(by seconds: Double) { seek(to: position + seconds) }

    func selectAudio(id: String) {
        backend.selectAudio(id: id)
        currentAudioID = id
    }

    func selectEmbeddedSubtitle(id: Int?) {
        backend.selectEmbeddedSubtitle(id: id)
        embeddedSubtitleID = id
        if id == nil { embeddedSubtitle = nil }
    }

    func setFill(_ fill: Bool) { backend.setFill(fill) }

    /// Another player takes over (Apple's couldn't play it) from `seconds`, playing if this one was meant to.
    func switchTo(_ next: any PlayerBackend, at seconds: Double) {
        backend.tearDown()
        backend = next
        isPlaying = false
        isBuffering = true
        status = .loading
        presentationSize = .zero
        buffered = 0
        audioTracks = []
        currentAudioID = nil
        embeddedSubtitles = []
        embeddedSubtitleID = nil
        embeddedSubtitle = nil
        airPlayNotice = nil
        next.attach(to: self)
        next.volume = volume
        onBackendChanged?()
        start(at: seconds)
    }

    // MARK: Reports from the backend

    func report(playing: Bool, buffering: Bool) {
        if !playing, isPlaying { onPause?() }
        if isPlaying != playing { isPlaying = playing }
        if isBuffering != buffering { isBuffering = buffering }
        updateNowPlaying()
    }

    func reportDuration(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0, seconds != duration else { return }
        duration = seconds
        updateNowPlaying()
    }

    // MARK: Now Playing

    func enableNowPlaying(title: String) {
        nowPlayingTitle = title
        if !commandsRegistered {
            commandsRegistered = true
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
}
