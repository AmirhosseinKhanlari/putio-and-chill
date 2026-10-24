import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@Suite struct AirPlaySubtitleRouteTests {
    private let putio = SubtitleChoice(subtitleFileID: 0, language: "eng", release: "English", offset: 1, putioKey: "k1")
    private let openSubtitles = SubtitleChoice(subtitleFileID: 77, language: "en", release: "Movie.2014.1080p", offset: -0.5)

    private func route(external: Bool = true, apple: Bool = true, choice: SubtitleChoice?, hasText: Bool = true,
                       fromDevice: Bool = false, network: Bool = true) -> AirPlaySubtitleRoute {
        AirPlaySubtitleRoute.decide(externalPlayback: external, appleEngine: apple, choice: choice, hasText: hasText,
                                    fromDevice: fromDevice, localNetwork: network)
    }

    @Test func onTheDeviceTheAppAlwaysDraws() {
        for choice in [putio, openSubtitles, SubtitleChoice.off, nil] {
            #expect(route(external: false, choice: choice) == .appDrawn)
        }
    }

    @Test func airPlayWithoutASubtitleKeepsThePlainStream() {
        #expect(route(choice: nil) == .appDrawn)
        #expect(route(choice: .off) == .appDrawn)
        #expect(route(choice: openSubtitles, hasText: false) == .appDrawn, "still loading: nothing to send yet")
    }

    @Test func putioTracksComeFromPutioAndOthersFromTheDevice() {
        #expect(route(choice: putio) == .putioRendition(key: "k1"))
        #expect(route(choice: putio, network: false) == .putioRendition(key: "k1"), "put.io's stream needs no local network")
        #expect(route(choice: openSubtitles) == .deviceRendition(id: "os-77--0.5"))
        #expect(route(choice: openSubtitles, network: false) == .unavailable(.noLocalNetwork))
    }

    @Test func timingChangesGiveTheTVANewCopy() {
        var shifted = openSubtitles
        shifted.offset = 0
        #expect(route(choice: shifted) != route(choice: openSubtitles))
    }

    @Test func downloadsAndTheBuiltInPlayerCantSendSubtitles() {
        #expect(route(choice: putio, fromDevice: true) == .unavailable(.download))
        #expect(route(choice: openSubtitles, fromDevice: true) == .unavailable(.download))
        // The built-in player sends only the sound: the picture (and subtitles) stay on the device.
        #expect(route(apple: false, choice: openSubtitles) == .appDrawn)
    }

    @Test func receiverDrawsOnlyRenditions() {
        #expect(AirPlaySubtitleRoute.putioRendition(key: "k").drawnByReceiver)
        #expect(AirPlaySubtitleRoute.deviceRendition(id: "x").drawnByReceiver)
        #expect(!AirPlaySubtitleRoute.appDrawn.drawnByReceiver)
        #expect(!AirPlaySubtitleRoute.unavailable(.failed).drawnByReceiver)
    }

    @Test func menuSaysWhatTheTVDoes() {
        #expect(AirPlaySubtitleCopy.menuNote(.putioRendition(key: "k"), externalPlayback: false) == nil)
        #expect(AirPlaySubtitleCopy.menuNote(.putioRendition(key: "k"), externalPlayback: true)?.contains("Timing changes here don't reach the TV") == true)
        #expect(AirPlaySubtitleCopy.menuNote(.deviceRendition(id: "x"), externalPlayback: true)?.contains("same Wi-Fi") == true)
        #expect(AirPlaySubtitleCopy.menuNote(.unavailable(.download), externalPlayback: true) == AirPlaySubtitleCopy.problemNotice(.download))
        #expect(AirPlaySubtitleCopy.menuNote(.appDrawn, externalPlayback: true)?.contains("caption style") == true)
        #expect(AirPlaySubtitleCopy.menuNote(.appDrawn, externalPlayback: true, fromDevice: true) == AirPlaySubtitleCopy.problemNotice(.download))
    }
}

@Suite struct StreamSubtitleOptionTests {
    private let options = [
        StreamSubtitleOption(name: "English", language: "en", isClosedCaption: true),
        StreamSubtitleOption(name: "French", language: "fr"),
        StreamSubtitleOption(name: "English (forced)", language: "en", isForcedOnly: true),
        StreamSubtitleOption(name: "English SDH", language: "en"),
    ]

    @Test func matchesNameThenLanguageNeverCaptions() {
        #expect(StreamSubtitleOption.bestIndex(options, name: "english sdh", language: "") == 3)
        #expect(StreamSubtitleOption.bestIndex(options, name: "Something else", language: "eng") == 3)
        #expect(StreamSubtitleOption.bestIndex(options, name: "x", language: "fre") == 1)
        #expect(StreamSubtitleOption.bestIndex(options, name: "x", language: "de") == nil)
    }

    @Test func theOnlySubtitleWinsWhenNothingMatches() {
        let single = [StreamSubtitleOption(name: "CC", language: "en", isClosedCaption: true), StreamSubtitleOption(name: "Sub 1", language: nil)]
        #expect(StreamSubtitleOption.bestIndex(single, name: "Movie.srt", language: "per") == 1)
        #expect(StreamSubtitleOption.bestIndex([], name: "a", language: "en") == nil)
    }
}

@Suite struct DeviceSubtitleStreamTests {
    private let master = URL(string: "https://api.put.io/v2/files/9/hls/media.m3u8?max_subtitle_count=0&oauth_token=T")!

    /// put.io: the master redirects to a stream host; segments start at timestamp 10 s.
    private func fetch(timestamp: UInt64) -> DeviceSubtitleStream.Fetch {
        let host = URL(string: "https://s1.put.io/hls/9/master.m3u8?sig=abc")!
        return { url, prefix in
            switch url.absoluteString {
            case self.master.absoluteString:
                return (Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,CODECS=\"avc1.640028,mp4a.40.2\"\nv0/index.m3u8?sig=abc\n".utf8), host)
            case "https://s1.put.io/hls/9/v0/index.m3u8?sig=abc":
                return (Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg0.ts?sig=abc\n#EXTINF:4,\nseg1.ts?sig=abc\n#EXT-X-ENDLIST\n".utf8), url)
            case "https://s1.put.io/hls/9/v0/seg0.ts?sig=abc":
                #expect(prefix != nil, "only the first bytes")
                return (Data(Self.tsPacket(pts: timestamp)), url)
            default:
                throw AppError.http(service: "test", status: 404)
            }
        }
    }

    static func tsPacket(pts: UInt64) -> [UInt8] {
        var bytes: [UInt8] = [0x47, 0x41, 0x00, 0x10, 0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 5]
        bytes += [UInt8(0x21 | ((pts >> 29) & 0x0E)), UInt8((pts >> 22) & 0xFF), UInt8(0x01 | ((pts >> 14) & 0xFE)),
                  UInt8((pts >> 7) & 0xFF), UInt8(0x01 | ((pts << 1) & 0xFE))]
        return bytes + [UInt8](repeating: 0xFF, count: 188 - bytes.count)
    }

    @Test func buildsMasterSubtitlePlaylistAndWebVTT() async throws {
        let track = SubtitleTrack(cues: [SubtitleCue(start: 1, end: 2, text: "Hi")])
        let built = try await DeviceSubtitleStream.build(stream: master, track: track, offset: 0.5, language: "en", name: "English",
                                                         baseURL: URL(string: "http://192.168.1.20:52000")!, fallbackDuration: 0,
                                                         fetch: fetch(timestamp: 900_000))
        #expect(built.mpegTimestamp == 900_000)
        #expect(built.files.count == 3)
        let text = { (path: String) in String(decoding: built.files[path]!.data, as: UTF8.self) }
        let masterText = text(built.masterPath)
        // Variants point at put.io's stream host (after the redirect), subtitles at this device.
        #expect(masterText.contains("\nhttps://s1.put.io/hls/9/v0/index.m3u8?sig=abc\n"))
        #expect(masterText.contains("URI=\"\(built.rendition.uri)\""))
        #expect(built.rendition.uri.hasPrefix("http://192.168.1.20:52000/"))
        let playlistPath = String(built.rendition.uri.dropFirst("http://192.168.1.20:52000".count))
        let playlist = text(playlistPath)
        #expect(playlist.contains("#EXT-X-TARGETDURATION:10\n"))
        #expect(playlist.contains("#EXTINF:10.000,\nhttp://192.168.1.20:52000/"))
        let vttPath = built.files.keys.first { $0.hasSuffix(".vtt") }!
        #expect(built.files[vttPath]?.contentType == "text/vtt")
        #expect(text(vttPath) == "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n1\n00:00:01.500 --> 00:00:02.500\nHi\n")
        // Unguessable, per build.
        #expect(built.masterPath.count > 30)
    }

    @Test func refusesSomethingThatIsntAPlaylist() async {
        let fetch: DeviceSubtitleStream.Fetch = { url, _ in (Data("<html>".utf8), url) }
        await #expect(throws: AppError.self) {
            _ = try await DeviceSubtitleStream.build(stream: master, track: SubtitleTrack(cues: []), offset: 0, language: "", name: "x",
                                                     baseURL: URL(string: "http://h:1")!, fallbackDuration: 0, fetch: fetch)
        }
    }
}

@Suite(.serialized) struct LocalHLSServerTests {
    @Test func servesPublishedFilesOnly() async throws {
        let server = LocalHLSServer()
        let port = try await server.start()
        defer { server.stop() }
        #expect(try await server.start() == port, "starting again keeps the same port")
        server.publish(["/abc/master.m3u8": .init(data: Data("#EXTM3U\n".utf8), contentType: "application/vnd.apple.mpegurl")])

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/abc/master.m3u8?x=1")!)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(String(decoding: data, as: UTF8.self) == "#EXTM3U\n")

        let (_, missing) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/other.vtt")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
        #expect(server.servedPaths == ["/abc/master.m3u8"])

        server.stop()
        #expect(!server.isRunning)
    }

    @Test func picksAPrivateAddress() {
        #expect(LocalNetworkAddress.pick(["169.254.3.4", "17.5.6.7", "192.168.1.20"]) == "192.168.1.20")
        #expect(LocalNetworkAddress.pick(["169.254.3.4", "17.5.6.7"]) == "17.5.6.7")
        #expect(LocalNetworkAddress.pick(["169.254.3.4"]) == nil)
        #expect(LocalNetworkAddress.isPrivate("172.20.1.1"))
        #expect(!LocalNetworkAddress.isPrivate("172.40.1.1"))
        #expect(LocalNetworkAddress.isPrivate("10.0.0.2"))
    }
}
