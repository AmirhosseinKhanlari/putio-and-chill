import AMDBCore
import Foundation

/// How subtitles reach the screen. On the device the app draws them over the video, but with AirPlay video the TV
/// fetches and plays the stream itself, so the subtitles have to be inside the stream it gets.
public enum AirPlaySubtitleRoute: Sendable, Equatable {
    /// put.io's stream without subtitles; the app draws them (or none are on).
    case appDrawn
    /// put.io's stream with this put.io track in it as a WebVTT rendition: the TV gets everything from put.io.
    case putioRendition(key: String)
    /// put.io's stream behind a playlist served from this device that adds the subtitle (OpenSubtitles, a cached
    /// file), with the timing shift baked in. `id` changes whenever the TV needs a new copy.
    case deviceRendition(id: String)
    /// AirPlay is on but this subtitle can't go to the TV: it stays on the device's screen.
    case unavailable(AirPlaySubtitleProblem)

    public enum Kind: Sendable { case appDrawn, putio, device, unavailable }

    public var kind: Kind {
        switch self {
        case .appDrawn: .appDrawn
        case .putioRendition: .putio
        case .deviceRendition: .device
        case .unavailable: .unavailable
        }
    }

    /// The TV draws the subtitle (so the app doesn't draw it on the device too).
    public var drawnByReceiver: Bool { kind == .putio || kind == .device }

    /// - Parameters:
    ///   - externalPlayback: AirPlay video (or a cable to a TV) is playing the picture.
    ///   - appleEngine: Apple's player. The built-in one never sends the picture over AirPlay (only the sound).
    ///   - hasText: the chosen subtitle's text is loaded.
    ///   - fromDevice: playing a download: there's no put.io stream to hand the TV.
    ///   - localNetwork: this device has an address the TV can reach.
    public static func decide(externalPlayback: Bool, appleEngine: Bool, choice: SubtitleChoice?, hasText: Bool,
                              fromDevice: Bool, localNetwork: Bool) -> AirPlaySubtitleRoute {
        guard externalPlayback, appleEngine, let choice, !choice.isOff, hasText else { return .appDrawn }
        if fromDevice { return .unavailable(.download) }
        if let key = choice.putioKey { return .putioRendition(key: key) }
        guard localNetwork else { return .unavailable(.noLocalNetwork) }
        return .deviceRendition(id: "os-\(choice.subtitleFileID)-\(choice.offset)")
    }
}

public enum AirPlaySubtitleProblem: Sendable, Equatable {
    case download
    case noLocalNetwork
    /// The stream with the subtitle didn't play: back to the plain one.
    case failed
}

/// What the subtitles menu (and the player, for problems) says during AirPlay. Plain words: the TV's own caption
/// settings decide the look, and what the timing control does there.
public enum AirPlaySubtitleCopy {
    public static func menuNote(_ route: AirPlaySubtitleRoute, externalPlayback: Bool, fromDevice: Bool = false) -> String? {
        guard externalPlayback else { return nil }
        switch route {
        case .appDrawn:
            return fromDevice ? problemNotice(.download)
                : "Playing on AirPlay. A subtitle you pick here shows on the TV, in the TV's own caption style."
        case .putioRendition:
            return "The TV shows this put.io subtitle in its own caption style (Settings on the TV). Timing changes here "
                + "don't reach the TV."
        case .deviceRendition:
            return "This device sends the subtitle to the TV, which shows it in its own caption style. Keep both on the "
                + "same Wi-Fi. A timing change reloads the video for a moment."
        case let .unavailable(problem):
            return problemNotice(problem)
        }
    }

    public static func problemNotice(_ problem: AirPlaySubtitleProblem) -> String {
        switch problem {
        case .download:
            "Subtitles of a downloaded video can't be sent over AirPlay. Stream it from put.io to see them on the TV."
        case .noLocalNetwork:
            "This subtitle can't be sent over AirPlay without Wi-Fi. Join the TV's Wi-Fi, or pick a put.io subtitle."
        case .failed:
            "The TV couldn't load this subtitle, so it shows only on this device. Try another subtitle."
        }
    }
}

/// One subtitle option of a stream (AVMediaSelectionOption, reduced to what matching needs).
public struct StreamSubtitleOption: Sendable, Equatable {
    public let name: String
    public let language: String?
    public let isClosedCaption: Bool
    public let isForcedOnly: Bool

    public init(name: String, language: String?, isClosedCaption: Bool = false, isForcedOnly: Bool = false) {
        self.name = name; self.language = language; self.isClosedCaption = isClosedCaption; self.isForcedOnly = isForcedOnly
    }

    /// The option to select for the chosen subtitle: same name, else same language, else the only real subtitle.
    /// Closed captions (CEA-608 inside the video) and forced-only tracks never count.
    public static func bestIndex(_ options: [StreamSubtitleOption], name: String, language: String) -> Int? {
        let candidates = options.indices.filter { !options[$0].isClosedCaption && !options[$0].isForcedOnly }
        if let exact = candidates.first(where: { options[$0].name.caseInsensitiveCompare(name) == .orderedSame }) { return exact }
        if !language.isEmpty {
            let wanted = LanguageMatcher.normalize(language)
            if let match = candidates.first(where: { options[$0].language.map(LanguageMatcher.normalize) == wanted }) { return match }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

/// Builds the AirPlay stream for a subtitle put.io doesn't have: put.io's playlist with every URL made absolute
/// (the TV loads the video straight from put.io) plus a subtitle rendition served by `LocalHLSServer`.
public enum DeviceSubtitleStream {
    /// Fetches a URL (or its first `prefix` bytes); returns the data and the URL it finally came from (redirects).
    public typealias Fetch = @Sendable (_ url: URL, _ prefix: Int?) async throws -> (Data, URL)

    public struct Built: Sendable {
        /// Path → file, to publish on the server.
        public let files: [String: LocalHLSServer.File]
        /// The master playlist's path.
        public let masterPath: String
        public let rendition: HLSSubtitleRendition
        public let mpegTimestamp: UInt64
    }

    /// - Parameters:
    ///   - stream: put.io's subtitle-free HLS URL.
    ///   - baseURL: where the server is, as the TV reaches it ("http://192.168.1.20:52000").
    ///   - fallbackDuration: the video's length when the playlist doesn't say.
    public static func build(stream: URL, track: SubtitleTrack, offset: Double, language: String, name: String,
                             baseURL: URL, fallbackDuration: Double, fetch: Fetch) async throws -> Built {
        let (masterData, masterURL) = try await fetch(stream, nil)
        let master = String(decoding: masterData, as: UTF8.self)
        guard master.hasPrefix("#EXTM3U") else { throw AppError.decoding(service: "putio", detail: "not a playlist") }

        // The first variant tells where timestamps start and how long the video is.
        var mediaText = master, mediaURL = masterURL
        if HLSPlaylist.isMaster(master), let variant = HLSPlaylist.firstVariant(in: master, playlistURL: masterURL) {
            let (data, url) = try await fetch(variant, nil)
            mediaText = String(decoding: data, as: UTF8.self)
            mediaURL = url
        }
        let info = HLSPlaylist.mediaInfo(mediaText, playlistURL: mediaURL)
        let timestamp = await firstTimestamp(info, fetch: fetch) ?? 0

        let prefix = "/\(UUID().uuidString.lowercased())"
        let vttPath = "\(prefix)/subtitles.vtt", playlistPath = "\(prefix)/subtitles.m3u8", masterPath = "\(prefix)/master.m3u8"
        let rendition = HLSSubtitleRendition(uri: baseURL.absoluteString + playlistPath, language: language, name: name)
        let duration = info.duration > 0 ? info.duration : fallbackDuration
        let files: [String: LocalHLSServer.File] = [
            masterPath: .init(data: Data(HLSPlaylist.addingSubtitles(to: master, playlistURL: masterURL, rendition: rendition).utf8),
                              contentType: "application/vnd.apple.mpegurl"),
            playlistPath: .init(data: Data(HLSPlaylist.subtitlePlaylist(duration: duration, segmentURI: baseURL.absoluteString + vttPath).utf8),
                                contentType: "application/vnd.apple.mpegurl"),
            vttPath: .init(data: Data(WebVTTWriter.make(track, offset: offset, mpegTimestamp: timestamp).utf8), contentType: "text/vtt"),
        ]
        return Built(files: files, masterPath: masterPath, rendition: rendition, mpegTimestamp: timestamp)
    }

    /// Where the video's timestamps start, from the first segment's first bytes (TS) or its init + first fragment (fMP4).
    static func firstTimestamp(_ info: HLSMediaPlaylistInfo, fetch: Fetch) async -> UInt64? {
        guard let segment = info.firstSegment else { return nil }
        if let initSegment = info.initSegment {
            guard let header = try? await fetch(initSegment, nil).0, let media = try? await fetch(segment, 256 * 1024).0 else { return nil }
            return MediaTimestampProbe.fragmentedMP4(initSegment: header, segment: media)
        }
        guard let data = try? await fetch(segment, 128 * 1024).0 else { return nil }
        return MediaTimestampProbe.mpegTS(data)
    }

    /// URLSession: the first `prefix` bytes as a Range request (servers that ignore Range send it all, also fine).
    public static let urlSession: Fetch = { url, prefix in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if let prefix { request.setValue("bytes=0-\(prefix - 1)", forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError.http(service: "putio", status: http.statusCode)
        }
        return (data, response.url ?? url)
    }
}
