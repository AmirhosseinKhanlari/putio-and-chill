#if canImport(AetherEngine) && !targetEnvironment(macCatalyst)
import AetherEngine
import AMDBKit
import AVKit
import Combine
import UIKit

/// The built-in player: AetherEngine (FFmpeg demux, hardware decode where Apple has it, software decode for the
/// rest) on the ORIGINAL file, for videos Apple's player can't play. No put.io conversion needed.
/// AirPlay sends only the sound from here (the picture stays on the device), and Picture in Picture uses the
/// engine's own layer.
@MainActor
final class AetherBackend: NSObject, PlayerBackend {
    let kind = PlaybackEngineKind.builtIn
    private let player: AetherEngine?
    private let surface = AetherPlayerView()
    private var url: URL
    private let audioLanguage: String?
    /// A fresh download link when put.io's has expired (nil for a file on this device).
    private let refreshURL: (() async -> URL?)?
    private weak var engine: PlayerEngine?
    private var subscriptions: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var refreshedOnce = false
    private var hasStarted = false
    private var routeObserver: NSObjectProtocol?

    var videoView: UIView { surface }
    var volume: Float {
        get { player?.volume ?? 1 }
        set { player?.volume = newValue }
    }

    init(url: URL, audioLanguage: String?, refreshURL: (() async -> URL?)?) {
        self.url = url
        self.audioLanguage = audioLanguage
        self.refreshURL = refreshURL
        player = try? AetherEngine()
        super.init()
        surface.backgroundColor = .black
        player?.bind(view: surface)
    }

    func attach(to engine: PlayerEngine) {
        self.engine = engine
        guard let player else {
            engine.status = .failed("The built-in player couldn't start.")
            return
        }
        player.$state.combineLatest(player.$playbackPhase)
            .sink { [weak self] state, phase in self?.stateChanged(state, phase: phase) }
            .store(in: &subscriptions)
        player.$hasFirstFrameReadyForDisplay.combineLatest(player.$isSessionReady, player.$videoRoute)
            .sink { [weak self] frame, ready, route in
                // Audio-only files never show a frame: ready is enough there.
                if frame || (ready && route == .audio) { self?.becameReady() }
            }
            .store(in: &subscriptions)
        player.clock.$currentTime
            .sink { [weak self] time in
                guard let self, let engine = self.engine, time.isFinite, self.hasStarted else { return }
                engine.position = time
            }
            .store(in: &subscriptions)
        player.clock.$bufferedPosition
            .sink { [weak self] value in self?.engine?.buffered = value.isFinite ? value : 0 }
            .store(in: &subscriptions)
        player.$duration
            .sink { [weak self] value in self?.engine?.reportDuration(value) }
            .store(in: &subscriptions)
        player.$audioTracks.combineLatest(player.$activeAudioTrackIndex)
            .sink { [weak self] tracks, active in
                self?.engine?.audioTracks = tracks.map { PlayerAudioTrack(id: String($0.id), name: Self.audioName($0)) }
                self?.engine?.currentAudioID = active.map(String.init)
            }
            .store(in: &subscriptions)
        player.$subtitleTracks
            .sink { [weak self] tracks in
                self?.engine?.embeddedSubtitles = tracks.filter { !$0.isExternal }.map {
                    PlayerSubtitleTrack(id: $0.id, name: Self.subtitleName($0), isImage: Self.imageCodecs.contains($0.codec))
                }
            }
            .store(in: &subscriptions)
        player.$subtitleCues.combineLatest(player.clock.$sourceTime)
            .sink { [weak self] cues, time in self?.showCues(cues, at: time) }
            .store(in: &subscriptions)
        player.$softwareDisplaySize.combineLatest(player.$sourceVideoWidth, player.$sourceVideoHeight)
            .sink { [weak self] display, width, height in
                guard let self, let player = self.player else { return }
                let size = display ?? CGSize(width: Double(width) * player.sourceVideoPixelAspectRatio, height: Double(height))
                if size.width > 0, size.height > 0, self.engine?.presentationSize != size { self.engine?.presentationSize = size }
            }
            .store(in: &subscriptions)
        // The layer exists only once the file has loaded, and can change (the engine moved this file to its software
        // path, say): Picture in Picture is rebuilt for whatever draws the picture now.
        player.$videoRoute.combineLatest(player.$softwarePiPSource.map { $0 != nil }, player.$hasFirstFrameReadyForDisplay)
            .map { "\($0.0.rawValue) \($0.1) \($0.2)" }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.engine?.onPictureSourceChanged?() }
            .store(in: &subscriptions)
        // Video AirPlay only works with Apple's player: here the receiver gets the sound only, never a fake picture.
        player.$currentAVPlayer
            .sink { $0?.allowsExternalPlayback = false }
            .store(in: &subscriptions)
        player.$airPlayPictureStaysLocal
            .sink { [weak self] _ in self?.updateAirPlayNotice() }
            .store(in: &subscriptions)
        // put.io's download link expired mid-film: get a fresh one and carry on where it was.
        player.sourceAuthorizationRefused
            .sink { [weak self] _ in self?.reloadWithFreshURL() }
            .store(in: &subscriptions)
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAirPlayNotice() }
        }
        updateAirPlayNotice()
    }

    func tearDown() {
        loadTask?.cancel()
        subscriptions.removeAll()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        player?.pictureInPictureActive = false
        player?.stop()
        engine = nil
    }

    // MARK: Controls

    func start(at seconds: Double, rate: Float) {
        guard let player else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load(at: seconds, rate: rate, player: player) }
    }

    private func load(at seconds: Double, rate: Float, player: AetherEngine) async {
        var options = LoadOptions()
        if let audioLanguage { options.preferredAudioLanguages = [audioLanguage] }
        // The app's sessions own the audio session (category set at launch); activate it for the software path.
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try await player.load(url: url, startPosition: seconds > 0 ? seconds : nil, options: options)
            hasStarted = true
            if rate != 1 { player.setRate(rate) }
        } catch is CancellationError {
            return
        } catch {
            // put.io's link expired before it opened (401/403/410): one retry with a fresh link.
            if !refreshedOnce, player.errorInfo?.kind == .sourceRefused, let refreshURL, let fresh = await refreshURL() {
                refreshedOnce = true
                url = fresh
                await load(at: seconds, rate: rate, player: player)
                return
            }
            engine?.status = .failed(player.errorInfo?.message ?? error.localizedDescription)
        }
    }

    func play(rate: Float) {
        guard let player else { return }
        if player.state == .ended { start(at: 0, rate: rate); return }
        player.setRate(rate)
        player.play()
    }

    func pause() { player?.pause() }

    func seek(to seconds: Double, completion: @escaping @Sendable @MainActor () -> Void) {
        guard let player else { return }
        Task {
            await player.seek(to: seconds)
            completion()
        }
    }

    func setRate(_ rate: Float, playing: Bool) { player?.setRate(rate) }

    func selectAudio(id: String) {
        guard let index = Int(id) else { return }
        player?.selectAudioTrack(index: index)
    }

    func selectEmbeddedSubtitle(id: Int?) {
        guard let player else { return }
        if let id { player.selectSubtitleTrack(index: id) } else { player.clearSubtitle() }
    }

    func setFill(_ fill: Bool) { player?.videoGravity = fill ? .resizeAspectFill : .resizeAspect }

    // MARK: Picture in Picture

    #if os(iOS)
    private var pipDelegate: SampleBufferPiPDelegate?
    #endif

    func makePictureInPicture() -> AVPictureInPictureController? {
        guard let player, AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        #if os(iOS)
        // Software path: sample-buffer PiP around the engine's display layer (not on tvOS, which can't).
        if player.videoRoute == .software, let source = player.softwarePiPSource {
            let delegate = SampleBufferPiPDelegate(source: source)
            pipDelegate = delegate
            return AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: source.layer, playbackDelegate: delegate))
        }
        #endif
        if let layer = player.nativePlayerLayer { return AVPictureInPictureController(playerLayer: layer) }
        return nil
    }

    func pictureInPictureChanged(active: Bool) { player?.pictureInPictureActive = active }

    // MARK: State

    private func stateChanged(_ state: PlaybackState, phase: PlaybackPhase) {
        guard let engine else { return }
        switch state {
        case let .error(message):
            engine.report(playing: false, buffering: false)
            engine.status = .failed(message)
            return
        case .playing:
            engine.report(playing: true, buffering: Self.isWaiting(phase))
        case .seeking, .loading:
            engine.report(playing: engine.isPlaying || state == .loading, buffering: true)
        case .paused, .ended, .idle:
            engine.report(playing: false, buffering: false)
        }
    }

    private func becameReady() {
        guard let engine, !engine.status.isFailed, engine.status != .ready else { return }
        engine.status = .ready
    }

    private static func isWaiting(_ phase: PlaybackPhase) -> Bool {
        switch phase {
        case .loading, .rebuffering, .seeking, .stalled: true
        default: false
        }
    }

    private func reloadWithFreshURL() {
        guard let refreshURL, let player else { return }
        let resumeAt = player.currentTime
        Task { [weak self] in
            guard let fresh = await refreshURL(), let self else { return }
            self.url = fresh
            self.start(at: resumeAt, rate: self.engine?.rate ?? 1)
        }
    }

    private func updateAirPlayNotice() {
        let airPlay = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        let notice = airPlay || player?.airPlayPictureStaysLocal == true
            ? "AirPlay plays only the sound of this video. The built-in player keeps the picture and subtitles on this device."
            : nil
        if engine?.airPlayNotice != notice { engine?.airPlayNotice = notice }
    }

    // MARK: Subtitles inside the file

    private func showCues(_ cues: [SubtitleCue], at time: Double) {
        guard let engine else { return }
        guard engine.embeddedSubtitleID != nil else {
            if engine.embeddedSubtitle != nil { engine.embeddedSubtitle = nil }
            return
        }
        let active = cues.filter { $0.startTime <= time && time < $0.endTime }
        var shown: EmbeddedSubtitle?
        let images = active.compactMap { cue -> EmbeddedSubtitleImage? in
            guard case let .image(image) = cue.body else { return nil }
            return EmbeddedSubtitleImage(image: image.cgImage, frame: frame(of: image))
        }
        if !images.isEmpty {
            shown = .images(images)
        } else {
            let lines = active.compactMap(\.text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !lines.isEmpty { shown = .text(lines.joined(separator: "\n")) }
        }
        if engine.embeddedSubtitle != shown { engine.embeddedSubtitle = shown }
    }

    /// Where a picture subtitle goes, relative (0…1) to the video: its canvas is laid width-aligned and centered on
    /// the picture (a cropped rip can have a canvas taller than the video).
    private func frame(of image: SubtitleImage) -> CGRect {
        let position = image.position
        guard let video = engine?.presentationSize, video.width > 0, video.height > 0,
              image.canvasSize.width > 0, image.canvasSize.height > 0 else { return position }
        let canvasHeight = video.width * image.canvasSize.height / image.canvasSize.width
        let offset = (video.height - canvasHeight) / 2
        return CGRect(x: position.minX, y: (offset + position.minY * canvasHeight) / video.height,
                      width: position.width, height: position.height * canvasHeight / video.height)
    }

    static let imageCodecs: Set<String> = ["hdmv_pgs_subtitle", "pgssub", "dvb_subtitle", "dvbsub", "dvd_subtitle", "dvdsub", "xsub"]

    /// "English · DTS 5.1"
    static func audioName(_ track: TrackInfo) -> String {
        let language = track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        let codec = ["dts": "DTS", "truehd": "TrueHD", "ac3": "Dolby Digital", "eac3": "Dolby Digital+", "aac": "AAC", "mp3": "MP3",
                     "flac": "FLAC", "opus": "Opus", "vorbis": "Vorbis"][track.codec] ?? track.codec.uppercased()
        let channels = switch track.channels { case 1: "Mono"; case 2: "Stereo"; case 6: "5.1"; case 8: "7.1"; default: "" }
        let detail = [codec, channels].filter { !$0.isEmpty }.joined(separator: " ")
        let name = track.name.isEmpty ? nil : track.name
        return [language ?? name ?? "Track \(track.id)", detail].joined(separator: " · ")
    }

    static func subtitleName(_ track: TrackInfo) -> String {
        let language = track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        var parts = [language ?? (track.name.isEmpty ? "Subtitles \(track.id)" : track.name)]
        // A name that only repeats the language code and format ("ENG (srt)") adds nothing.
        let code = track.language?.lowercased() ?? ""
        if language != nil, !track.name.isEmpty, track.name != language, code.isEmpty || !track.name.lowercased().hasPrefix(code) {
            parts.append(track.name)
        }
        if track.isForced { parts.append("Forced") }
        if track.isHearingImpaired { parts.append("SDH") }
        return parts.joined(separator: " · ")
    }
}

#if os(iOS)
/// Answers Picture in Picture's transport questions for the software path, from the engine's own clock.
@MainActor
private final class SampleBufferPiPDelegate: NSObject, @MainActor AVPictureInPictureSampleBufferPlaybackDelegate {
    private let source: SoftwarePiPSource

    init(source: SoftwarePiPSource) { self.source = source }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        source.setPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        source.timeRange()
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { source.isPaused }

    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        source.skip(by: skipInterval.seconds)
    }
}
#endif
#endif
