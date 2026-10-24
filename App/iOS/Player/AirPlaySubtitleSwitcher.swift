import AMDBCore
import AMDBKit
import AVFoundation
import os

/// Gets subtitles onto the TV during AirPlay. On the device the app draws subtitles over a subtitle-free stream, but
/// with AirPlay video the TV fetches and plays the stream itself and never sees that drawing. So while AirPlay is on
/// and a subtitle is picked, the player switches (same position, a short rebuffer) to a stream that carries it:
/// put.io's own stream with that track for put.io subtitles, or put.io's stream behind a playlist this device serves
/// for the rest (OpenSubtitles, cached files). When AirPlay ends, it goes back to the plain stream and the app's own
/// drawing, so style and timing work again. Runs once a second from the player's loop.
@MainActor
final class AirPlaySubtitleSwitcher {
    /// DEBUG: `-forceExternalPlayback` acts as if AirPlay were on, so the simulator (which can't AirPlay) runs the
    /// same switch, and logs what the TV would get. `-forceExternalPlaybackSeconds N` turns it off again after N
    /// seconds (AirPlay ending).
    static var forcesExternalPlayback: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-forceExternalPlaybackSeconds"), index + 1 < arguments.count,
           let seconds = Double(arguments[index + 1]) {
            return Date().timeIntervalSince(launched) < seconds
        }
        return arguments.contains("-forceExternalPlayback")
        #else
        false
        #endif
    }

    #if DEBUG
    private static let launched = Date()
    #endif

    static let log = Logger(subsystem: "app.amdb", category: "airplay")

    private let engine: PlayerEngine
    private let finder: SubtitleFinder?
    private let putio: any PutioService
    private let fileID: Int64
    private let fromDevice: Bool
    /// put.io's subtitle-free HLS stream; nil while Apple's player plays something else (the original MP4).
    var plainStream: URL?
    /// Switching streams: the player's "can't play" handling waits.
    private(set) var isSwitching = false

    /// What the current stream carries.
    private var current: AirPlaySubtitleRoute = .appDrawn
    private var backendID: ObjectIdentifier?
    /// Seconds AirPlay has looked off: it flickers off for a moment while the TV loads a new stream.
    private var offSeconds = 0
    /// A stream with a subtitle that didn't play: not tried again until the pick changes.
    private var failed: AirPlaySubtitleRoute?
    private let server = LocalHLSServer()
    #if DEBUG
    private var legibleLog: LegibleLog?
    #endif

    init(engine: PlayerEngine, finder: SubtitleFinder?, putio: any PutioService, fileID: Int64, plainStream: URL?, fromDevice: Bool) {
        self.engine = engine
        self.finder = finder
        self.putio = putio
        self.fileID = fileID
        self.plainStream = plainStream
        self.fromDevice = fromDevice
    }

    func tearDown() { server.stop() }

    func update() {
        guard let apple = engine.backend as? AVPlayerBackend else {
            // The built-in player: AirPlay sends only the sound, and it says so itself.
            reset()
            return
        }
        if backendID != ObjectIdentifier(apple) {
            // A new Apple player starts on the plain stream.
            backendID = ObjectIdentifier(apple)
            current = .appDrawn
            failed = nil
        }
        let airPlayNow = engine.isExternalPlayback || Self.forcesExternalPlayback
        offSeconds = airPlayNow ? 0 : offSeconds + 1
        let airPlay = airPlayNow || (current.drawnByReceiver && offSeconds < 3)

        var route = AirPlaySubtitleRoute.decide(externalPlayback: airPlay, appleEngine: true, choice: finder?.choice,
                                                hasText: finder?.isShowing == true, fromDevice: fromDevice,
                                                localNetwork: airPlay && LocalNetworkAddress.current() != nil)
        if route.drawnByReceiver, plainStream == nil { route = .appDrawn }
        if let failed {
            if route == failed { route = .unavailable(.failed) } else { self.failed = nil }
        }
        publish(route, airPlay: airPlay)

        guard !isSwitching, Self.stream(route) != Self.stream(current) else { return }
        isSwitching = true
        Task { await self.switchStream(to: route, on: apple) }
    }

    // MARK: Switching

    private func switchStream(to route: AirPlaySubtitleRoute, on apple: AVPlayerBackend) async {
        defer { isSwitching = false }
        let position = engine.position, playing = engine.isPlaying || engine.status == .loading
        let choice = finder?.choice
        guard let url = await streamURL(for: route, choice: choice, apple: apple), engine.backend === apple else {
            if route.drawnByReceiver { fail(route) }
            return
        }
        Self.log.notice("file \(self.fileID): AirPlay subtitles \(String(describing: route), privacy: .public)")
        #if DEBUG
        debugLog("switch to \(Self.stream(route)) at \(String(format: "%.1f", position))")
        #endif
        apple.replace(with: url, at: position, rate: engine.rate, playing: playing)
        current = route
        guard route.drawnByReceiver else {
            server.stop()
            return
        }
        // Ready (or not) within 30 s; a stream that doesn't play goes back to the plain one.
        var waited = 0
        while engine.status == .loading, engine.backend === apple, waited < 60 {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
        }
        guard engine.backend === apple, current == route else { return }
        guard engine.status == .ready else {
            fail(route)
            return
        }
        let selected = await apple.selectStreamSubtitle()
        let name = await apple.selectedStreamSubtitleName()
        Self.log.notice("file \(self.fileID): subtitle rendition selected \(selected) (\(name ?? "none", privacy: .public))")
        #if DEBUG
        if Self.forcesExternalPlayback {
            debugLog("stream \(url.absoluteString.contains("oauth_token") ? "put.io (token hidden)" : url.absoluteString)")
            debugLog("selected=\(selected) option=\(name ?? "none")")
            if let item = apple.player.currentItem { legibleLog = LegibleLog(item: item) }
        }
        #endif
    }

    /// The stream for `route`: plain, put.io's with the track, or the playlist served from here.
    private func streamURL(for route: AirPlaySubtitleRoute, choice: SubtitleChoice?, apple: AVPlayerBackend) async -> URL? {
        guard let plainStream else { return nil }
        switch route {
        case .appDrawn, .unavailable:
            apple.streamSubtitle = nil
            return plainStream
        case let .putioRendition(key):
            guard let choice else { return nil }
            apple.streamSubtitle = (name: choice.release, language: choice.language)
            return putio.hlsURL(fileID: fileID, subtitleKey: key)
        case .deviceRendition:
            guard let choice, let track = finder?.track, let address = LocalNetworkAddress.current() else { return nil }
            do {
                let port = try await server.start()
                guard let base = URL(string: "http://\(address):\(port)") else { return nil }
                let language = LanguageMatcher.normalize(choice.language)
                let name = Locale.current.localizedString(forLanguageCode: language)?.capitalized ?? "Subtitles"
                let built = try await DeviceSubtitleStream.build(stream: plainStream, track: track, offset: choice.offset,
                                                                 language: language, name: name, baseURL: base,
                                                                 fallbackDuration: engine.duration, fetch: DeviceSubtitleStream.urlSession)
                server.publish(built.files)
                apple.streamSubtitle = (name: name, language: language)
                #if DEBUG
                if Self.forcesExternalPlayback {
                    debugLog("master \(base.absoluteString + built.masterPath) MPEGTS:\(built.mpegTimestamp)")
                }
                #endif
                return URL(string: base.absoluteString + built.masterPath)
            } catch {
                Self.log.error("file \(self.fileID): AirPlay subtitle stream failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// The subtitle didn't reach the TV: back to the plain stream, the subtitle stays on this device, and it says so.
    private func fail(_ route: AirPlaySubtitleRoute) {
        failed = route
        current = .unavailable(.failed)
        if let apple = engine.backend as? AVPlayerBackend, let plainStream {
            apple.streamSubtitle = nil
            apple.replace(with: plainStream, at: engine.position, rate: engine.rate, playing: true)
        }
        server.stop()
        publish(.unavailable(.failed), airPlay: true)
    }

    private func publish(_ route: AirPlaySubtitleRoute, airPlay: Bool) {
        if engine.airPlaySubtitleRoute != route { engine.airPlaySubtitleRoute = route }
        let note = AirPlaySubtitleCopy.menuNote(route, externalPlayback: airPlay, fromDevice: fromDevice)
        if engine.airPlaySubtitleNote != note { engine.airPlaySubtitleNote = note }
        let notice: String? = if airPlay, case let .unavailable(problem) = route { AirPlaySubtitleCopy.problemNotice(problem) } else { nil }
        if engine.airPlayNotice != notice { engine.airPlayNotice = notice }
    }

    private func reset() {
        backendID = nil
        current = .appDrawn
        server.stop()
        if engine.airPlaySubtitleRoute != .appDrawn { engine.airPlaySubtitleRoute = .appDrawn }
        if engine.airPlaySubtitleNote != nil { engine.airPlaySubtitleNote = nil }
    }

    /// Which stream a route plays (two routes on the same stream need no switch).
    private static func stream(_ route: AirPlaySubtitleRoute) -> String {
        switch route {
        case .appDrawn, .unavailable: "plain"
        case let .putioRendition(key): "putio-\(key)"
        case let .deviceRendition(id): "device-\(id)"
        }
    }
}

#if DEBUG
/// DEBUG checks without a TV: stdout, and tmp/airplay-debug.log in the app's container (readable from the Mac).
private func debugLog(_ line: String) {
    print("[airplay-debug] \(line)")
    let file = FileManager.default.temporaryDirectory.appending(path: "airplay-debug.log")
    let data = Data("\(line)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: file)
    }
}

/// DEBUG with `-forceExternalPlayback`: prints the subtitle text the stream delivers and when, which is what the TV
/// would draw, to check the rendition is selected and lines up with the picture.
private final class LegibleLog: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
    private let output = AVPlayerItemLegibleOutput()

    init(item: AVPlayerItem) {
        super.init()
        output.setDelegate(self, queue: .main)
        item.add(output)
    }

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        debugLog(String(format: "cue at %.2f: %@", itemTime.seconds, strings.map(\.string).joined(separator: " / ")))
    }
}
#endif
