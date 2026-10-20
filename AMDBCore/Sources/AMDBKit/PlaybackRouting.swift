import AMDBCore
import Foundation

/// Which player plays a video.
public enum PlaybackEngineKind: String, Codable, Sendable, CaseIterable {
    /// Apple's player on put.io's HLS stream: AirPlay, Picture in Picture and the system's controls all work.
    case apple
    /// The built-in player (FFmpeg) on the original file: plays what Apple's can't, without put.io converting it.
    case builtIn
}

/// Settings → Playback: what happens to a video Apple's player can't play.
public enum UnsupportedVideoPlayer: String, Codable, Sendable, CaseIterable {
    /// Play the original file with the built-in player (put.io converts it only if that fails too).
    case builtIn
    /// Have put.io convert it to MP4 first, as before.
    case convert
}

/// One step of playing a file.
public enum PlaybackStep: Equatable, Sendable {
    case play(PlaybackEngineKind)
    /// put.io converts it to MP4, then Apple's player plays the stream.
    case convert
    /// Nothing left to try.
    case fail
}

/// Whether Apple's player can decode what's in a file, from put.io's codec info.
public enum CodecVerdict: Equatable, Sendable {
    case applePlays
    /// The codec it can't decode ("mpeg4", "dts"…).
    case appleCannotPlay(String)
    case unknown

    /// Decides from the codecs. Only a codec known not to play makes it `appleCannotPlay`; anything not on either
    /// list leaves it `unknown` (the failure path decides then). Several audio tracks: one Apple can play is enough.
    /// `hardwareVP9` / `hardwareAV1`: this device decodes them in hardware (Apple's player needs that).
    public static func of(_ info: PutioMediaInfo, hardwareVP9: Bool = false, hardwareAV1: Bool = false) -> CodecVerdict {
        // Cover art in a file shows up as a video stream: ignore stills.
        let video = info.videoCodecs.first { !stillCodecs.contains($0) }
        if let video {
            if unsupportedVideo.contains(video)
                || (video == "vp9" && !hardwareVP9) || (video == "av1" && !hardwareAV1) {
                return .appleCannotPlay(video)
            }
        }
        if !info.audioCodecs.isEmpty, info.audioCodecs.allSatisfy(unsupportedAudio.contains) {
            return .appleCannotPlay(info.audioCodecs[0])
        }
        let videoKnown = video.map { supportedVideo.contains($0) || ($0 == "vp9" && hardwareVP9) || ($0 == "av1" && hardwareAV1) }
        let audioKnown = info.audioCodecs.isEmpty || info.audioCodecs.contains(where: supportedAudio.contains)
        return videoKnown == true && audioKnown ? .applePlays : .unknown
    }

    static let stillCodecs: Set<String> = ["mjpeg", "png", "bmp", "gif", "webp"]
    static let supportedVideo: Set<String> = ["h264", "hevc", "h265", "avc", "avc1", "hvc1", "prores"]
    static let unsupportedVideo: Set<String> = [
        "mpeg4", "xvid", "divx", "dx50", "div3", "msmpeg4", "msmpeg4v1", "msmpeg4v2", "msmpeg4v3", "mpeg1video",
        "mpeg2video", "mpeg2", "vc1", "wmv1", "wmv2", "wmv3", "vp8", "vp6", "vp6f", "vp6a", "flv1", "theora",
        "rv10", "rv20", "rv30", "rv40",
    ]
    static let supportedAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "flac", "alac", "opus", "pcm_s16le", "pcm_s24le"]
    static let unsupportedAudio: Set<String> = [
        "dts", "dca", "truehd", "mlp", "wmav1", "wmav2", "wmapro", "wmalossless", "wmavoice", "vorbis", "cook", "sipr",
        "atrac3", "ralf", "ra_144", "ra_288", "nellymoser", "speex", "pcm_dvd", "pcm_bluray",
    ]
}

/// The routing rules, without side effects (so they can be tested on their own).
public enum PlaybackRoute {
    /// The first player to try. Apple's stays the default: most files play there, with AirPlay and the system's
    /// Picture in Picture. The built-in player goes first only when it worked for this file before, or when put.io
    /// says the file needs converting and its codecs confirm Apple's player can't decode it.
    public static func first(remembered: PlaybackEngineKind?, needsConvert: Bool, verdict: CodecVerdict,
                             preference: UnsupportedVideoPlayer, builtInAvailable: Bool) -> PlaybackStep {
        guard builtInAvailable, preference == .builtIn else { return .play(.apple) }
        if let remembered { return .play(remembered) }
        if needsConvert, case .appleCannotPlay = verdict { return .play(.builtIn) }
        return .play(.apple)
    }

    /// What to do after `failed` didn't play. put.io's conversion comes last, and only when put.io says the
    /// file needs it (it also flags videos that only web browsers can't play).
    public static func after(failed: PlaybackEngineKind, tried: Set<PlaybackEngineKind>, needsConvert: Bool,
                             verdict: CodecVerdict, preference: UnsupportedVideoPlayer, builtInAvailable: Bool) -> PlaybackStep {
        let builtIn = builtInAvailable && preference == .builtIn
        switch failed {
        case .apple:
            if builtIn, !tried.contains(.builtIn) { return .play(.builtIn) }
        case .builtIn:
            // Went straight to the built-in player (remembered, say) and it failed: Apple's may still play it.
            if case .appleCannotPlay = verdict {} else if !tried.contains(.apple) { return .play(.apple) }
        }
        return needsConvert ? .convert : .fail
    }
}

/// Remembers which player worked for each file, so the next play goes straight there.
@MainActor
public final class PlaybackEngineMemory {
    private let defaults: UserDefaults
    private let key: String
    private let limit: Int
    private var entries: [String: String]

    public init(defaults: UserDefaults, key: String = "amdb.playbackEngines", limit: Int = 2000) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        entries = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    public func engine(fileID: Int64) -> PlaybackEngineKind? { entries[String(fileID)].flatMap(PlaybackEngineKind.init) }

    public func remember(_ engine: PlaybackEngineKind, fileID: Int64) {
        guard entries[String(fileID)] != engine.rawValue else { return }
        // Only files that needed the built-in player matter much; keep the list from growing without bound.
        if entries.count >= limit, let oldest = entries.keys.first { entries[oldest] = nil }
        entries[String(fileID)] = engine.rawValue
        defaults.set(entries, forKey: key)
    }

    public func forget(fileID: Int64) {
        guard entries[String(fileID)] != nil else { return }
        entries[String(fileID)] = nil
        defaults.set(entries, forKey: key)
    }
}

/// Runs the routing for one playback: asks put.io about the file (briefly), picks the first player, and the next
/// one when a player fails. The player screen does the playing; this only decides.
@MainActor
public final class PlaybackPlan {
    public struct Options: Sendable {
        public var preference: UnsupportedVideoPlayer
        /// The built-in player exists on this platform (it doesn't in the Mac app).
        public var builtInAvailable: Bool
        public var hardwareVP9: Bool
        public var hardwareAV1: Bool
        /// How long to wait for put.io's codec info before just starting with Apple's player.
        public var infoTimeout: Duration

        public init(preference: UnsupportedVideoPlayer, builtInAvailable: Bool, hardwareVP9: Bool = false,
                    hardwareAV1: Bool = false, infoTimeout: Duration = .seconds(4)) {
            self.preference = preference; self.builtInAvailable = builtInAvailable
            self.hardwareVP9 = hardwareVP9; self.hardwareAV1 = hardwareAV1; self.infoTimeout = infoTimeout
        }
    }

    public let fileID: Int64
    public private(set) var options: Options
    public private(set) var verdict: CodecVerdict = .unknown
    public private(set) var tried: Set<PlaybackEngineKind> = []
    public private(set) var converted = false
    private let memory: PlaybackEngineMemory
    private let mediaInfo: @Sendable (Int64) async -> PutioMediaInfo?
    private let needsConversion: (Int64) async -> Bool
    private var info: PutioMediaInfo?

    /// - Parameters:
    ///   - mediaInfo: put.io's codec info for the file (nil when unknown or unreachable).
    ///   - needsConversion: whether put.io says the file needs converting for Apple devices right now.
    public init(fileID: Int64, options: Options, memory: PlaybackEngineMemory,
                mediaInfo: @escaping @Sendable (Int64) async -> PutioMediaInfo?,
                needsConversion: @escaping (Int64) async -> Bool) {
        self.fileID = fileID
        self.options = options
        self.memory = memory
        self.mediaInfo = mediaInfo
        self.needsConversion = needsConversion
    }

    /// The player to start with.
    public func firstStep() async -> PlaybackStep {
        let remembered = memory.engine(fileID: fileID)
        var needsConvert = false
        if options.builtInAvailable, options.preference == .builtIn, remembered == nil {
            info = await Self.within(options.infoTimeout) { [mediaInfo, fileID] in await mediaInfo(fileID) }
            if let info {
                verdict = CodecVerdict.of(info, hardwareVP9: options.hardwareVP9, hardwareAV1: options.hardwareAV1)
                needsConvert = info.needConvert == true && info.isMp4Available != true
            }
        }
        let step = PlaybackRoute.first(remembered: remembered, needsConvert: needsConvert, verdict: verdict,
                                       preference: options.preference, builtInAvailable: options.builtInAvailable)
        if case let .play(engine) = step { tried.insert(engine) }
        return step
    }

    /// `engine` didn't play: the next thing to try.
    public func step(afterFailureOf engine: PlaybackEngineKind) async -> PlaybackStep {
        tried.insert(engine)
        // A remembered player that stops working (the file changed, say) is forgotten.
        if memory.engine(fileID: fileID) == engine { memory.forget(fileID: fileID) }
        let needsConvert = converted ? false : await needsConversion(fileID)
        let step = PlaybackRoute.after(failed: engine, tried: tried, needsConvert: needsConvert, verdict: verdict,
                                       preference: options.preference, builtInAvailable: options.builtInAvailable)
        if case let .play(next) = step { tried.insert(next) }
        if step == .convert { converted = true }
        return step
    }

    /// `engine` is playing: remembered for next time. Apple's player is the default anyway, so it's only remembered
    /// for a file where the built-in one was tried or would have been picked (the list stays small).
    public func succeeded(_ engine: PlaybackEngineKind) {
        let routed: Bool = if case .appleCannotPlay = verdict { true } else { false }
        guard engine == .builtIn || tried.contains(.builtIn) || routed || memory.engine(fileID: fileID) != nil else { return }
        memory.remember(engine, fileID: fileID)
    }

    /// `work`'s answer, or nil after `timeout` (the work is left to finish on its own).
    static func within<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
