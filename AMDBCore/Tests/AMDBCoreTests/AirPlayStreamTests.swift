import Foundation
import Testing
@testable import AMDBCore

@Suite struct WebVTTWriterTests {
    private let track = SubtitleParser.parse("""
    1
    00:00:00,500 --> 00:00:02,000
    <i>Starts</i> early

    2
    00:01:01,250 --> 00:01:03,000
    Fish & chips <3
    --> arrow

    3
    01:00:00,000 --> 01:00:01,500
    An hour in
    """)

    @Test func writesCuesWithTimestampMapAndEscapes() {
        let vtt = WebVTTWriter.make(track, offset: 0, mpegTimestamp: 900_000)
        #expect(vtt.hasPrefix("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n1\n00:00:00.500 --> 00:00:02.000\nStarts early\n"))
        #expect(vtt.contains("2\n00:01:01.250 --> 00:01:03.000\nFish &amp; chips &lt;3\n--&gt; arrow\n"))
        #expect(vtt.contains("3\n01:00:00.000 --> 01:00:01.500\nAn hour in\n"))
        // Reads back as the same cues.
        #expect(SubtitleParser.parse(vtt).cues.map(\.start) == [0.5, 61.25, 3600])
    }

    @Test func bakesInTheTimingShift() {
        let later = SubtitleParser.parse(WebVTTWriter.make(track, offset: 1.5, mpegTimestamp: 0))
        #expect(later.cues.map(\.start) == [2, 62.75, 3601.5])
        // Earlier: a cue pushed before 0 starts at 0; one that ends before 0 is dropped.
        let earlier = SubtitleParser.parse(WebVTTWriter.make(track, offset: -1, mpegTimestamp: 0))
        #expect(earlier.cues.first == SubtitleCue(start: 0, end: 1, text: "Starts early"))
        let gone = SubtitleParser.parse(WebVTTWriter.make(track, offset: -2.5, mpegTimestamp: 0))
        #expect(gone.cues.count == 2)
        #expect(WebVTTWriter.make(track, offset: -2.5, mpegTimestamp: 0).contains("\n1\n00:00:58.750"))
    }

    @Test func formatsTimes() {
        #expect(WebVTTWriter.time(0) == "00:00:00.000")
        #expect(WebVTTWriter.time(3725.0405) == "01:02:05.041")
    }
}

@Suite struct HLSPlaylistTests {
    private let rendition = HLSSubtitleRendition(uri: "http://192.168.1.20:52000/x/subtitles.m3u8", language: "en", name: "English \"SDH\"")
    private let masterURL = URL(string: "https://api.put.io/v2/files/42/hls/media.m3u8?max_subtitle_count=0&oauth_token=T")!

    @Test func rewritesMasterWithAbsoluteURLsAndOneDefaultSubtitleGroup() {
        let master = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="en",NAME="English",DEFAULT=YES,URI="audio/en.m3u8?t=1"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="put",LANGUAGE="fr",NAME="French",DEFAULT=YES,URI="subs/fr.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud",SUBTITLES="put"
        1080/index.m3u8?t=1

        #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aud"
        https://cdn.put.io/abs/480.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="iframes.m3u8"
        """
        let out = HLSPlaylist.addingSubtitles(to: master, playlistURL: masterURL, rendition: rendition)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == "#EXTM3U")
        #expect(!out.contains("GROUP-ID=\"put\""), "put.io's own subtitles are dropped")
        #expect(lines.filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") } == [
            "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"chill-subs\",LANGUAGE=\"en\",NAME=\"English 'SDH'\",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"http://192.168.1.20:52000/x/subtitles.m3u8\"",
        ])
        #expect(lines.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",LANGUAGE=\"en\",NAME=\"English\",DEFAULT=YES,URI=\"https://api.put.io/v2/files/42/hls/audio/en.m3u8?t=1\""))
        #expect(lines.contains("#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS=\"avc1.640028,mp4a.40.2\",AUDIO=\"aud\",SUBTITLES=\"chill-subs\""))
        #expect(lines.contains("#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS=\"avc1.4d401e,mp4a.40.2\",AUDIO=\"aud\",SUBTITLES=\"chill-subs\""))
        #expect(lines.contains("https://api.put.io/v2/files/42/hls/1080/index.m3u8?t=1"))
        #expect(lines.contains("https://cdn.put.io/abs/480.m3u8"))
        #expect(lines.contains("#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI=\"https://api.put.io/v2/files/42/hls/iframes.m3u8\""))
        // The subtitle group is declared before the variants that use it.
        let media = lines.firstIndex { $0.contains("chill-subs") && $0.hasPrefix("#EXT-X-MEDIA") }!
        let firstVariant = lines.firstIndex { $0.hasPrefix("#EXT-X-STREAM-INF") }!
        #expect(media < firstVariant)
        #expect(HLSPlaylist.firstVariant(in: master, playlistURL: masterURL)?.absoluteString == "https://api.put.io/v2/files/42/hls/1080/index.m3u8?t=1")
    }

    @Test func wrapsAMediaPlaylistInAOneVariantMaster() {
        let media = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.0,\nseg0.ts\n#EXT-X-ENDLIST\n"
        let out = HLSPlaylist.addingSubtitles(to: media, playlistURL: masterURL, rendition: rendition)
        #expect(out.contains("#EXT-X-STREAM-INF:BANDWIDTH=6000000,SUBTITLES=\"chill-subs\"\n\(masterURL.absoluteString)\n"))
        #expect(out.contains("TYPE=SUBTITLES,GROUP-ID=\"chill-subs\""))
        #expect(HLSPlaylist.isMaster(out))
        #expect(!HLSPlaylist.isMaster(media))
    }

    @Test func leavesOutLanguageWhenUnknown() {
        let out = HLSPlaylist.addingSubtitles(to: "#EXTM3U\n#EXTINF:1,\na.ts\n", playlistURL: masterURL,
                                              rendition: HLSSubtitleRendition(uri: "http://h/s.m3u8", language: "", name: "Subtitle"))
        #expect(!out.contains("LANGUAGE="))
    }

    @Test func readsMediaPlaylistInfo() {
        let url = URL(string: "https://cdn.put.io/v/1080/index.m3u8?t=1")!
        let ts = HLSPlaylist.mediaInfo("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:9.97667,\t\nfileSequence0.ts\n#EXTINF:5.5,\nfileSequence1.ts\n#EXT-X-ENDLIST\n",
                                       playlistURL: url)
        #expect(ts == HLSMediaPlaylistInfo(firstSegment: URL(string: "https://cdn.put.io/v/1080/fileSequence0.ts"), initSegment: nil,
                                           duration: 15.47667))
        let fmp4 = HLSPlaylist.mediaInfo("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\nseg1.m4s\n", playlistURL: url)
        #expect(fmp4.initSegment?.absoluteString == "https://cdn.put.io/v/1080/init.mp4")
        #expect(fmp4.firstSegment?.absoluteString == "https://cdn.put.io/v/1080/seg1.m4s")
    }

    @Test func subtitlePlaylistIsOneSegmentVOD() {
        let playlist = HLSPlaylist.subtitlePlaylist(duration: 5400.4, segmentURI: "http://h/x/subtitles.vtt")
        #expect(playlist == "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5401\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:5400.400,\nhttp://h/x/subtitles.vtt\n#EXT-X-ENDLIST\n")
    }

    @Test func parsesQuotedAttributesWithCommas() {
        var attributes = HLSAttributes("BANDWIDTH=1,CODECS=\"avc1,mp4a\",SUBTITLES=\"a\"")
        #expect(attributes["CODECS"] == "avc1,mp4a")
        attributes.set("SUBTITLES", quoted: "b")
        attributes.set("NEW", quoted: "c")
        #expect(attributes.text == "BANDWIDTH=1,CODECS=\"avc1,mp4a\",SUBTITLES=\"b\",NEW=\"c\"")
    }
}

@Suite struct MediaTimestampProbeTests {
    /// One 188-byte TS packet starting a PES with this PTS.
    private func packet(pts: UInt64, stream: UInt8, adaptation: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = [0x47, 0x41, 0x00, adaptation ? 0x30 : 0x10]
        if adaptation { bytes += [3, 0x00, 0xFF, 0xFF] }
        bytes += [0, 0, 1, stream, 0, 0, 0x80, 0x80, 5]
        bytes += [UInt8(0x21 | ((pts >> 29) & 0x0E)), UInt8((pts >> 22) & 0xFF), UInt8(0x01 | ((pts >> 14) & 0xFE)),
                  UInt8((pts >> 7) & 0xFF), UInt8(0x01 | ((pts << 1) & 0xFE))]
        return bytes + [UInt8](repeating: 0xFF, count: 188 - bytes.count)
    }

    @Test func findsTheEarliestPTSInTheFirstBytes() {
        let continuation: [UInt8] = [0x47, 0x01, 0x00, 0x11] + [UInt8](repeating: 0xFF, count: 184)
        let data = Data([0x00, 0x00] + packet(pts: 900_000, stream: 0xE0) + continuation + packet(pts: 891_380, stream: 0xC0, adaptation: true)
                        + packet(pts: 8_589_934_000, stream: 0xE0).prefix(100))
        #expect(MediaTimestampProbe.mpegTS(data) == 891_380)
        #expect(MediaTimestampProbe.mpegTS(Data([1, 2, 3])) == nil)
    }

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + payload.count)
        return [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + Array(type.utf8) + payload
    }

    private func be32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

    @Test func readsFragmentedMP4DecodeTime() {
        let tkhd = box("tkhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(1) + [UInt8](repeating: 0, count: 60))
        let mdhd = box("mdhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(90_000) + be32(0) + [0, 0, 0, 0])
        let audioTkhd = box("tkhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(2) + [UInt8](repeating: 0, count: 60))
        let audioMdhd = box("mdhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(48_000) + be32(0) + [0, 0, 0, 0])
        let initSegment = box("ftyp", Array("iso6".utf8) + be32(0)) + box("moov", box("mvhd", [UInt8](repeating: 0, count: 100))
            + box("trak", tkhd + box("mdia", mdhd)) + box("trak", audioTkhd + box("mdia", audioMdhd)))
        let videoTraf = box("traf", box("tfhd", [0, 0, 0, 0] + be32(1)) + box("tfdt", [1, 0, 0, 0] + be32(0) + be32(900_000)))
        let audioTraf = box("traf", box("tfhd", [0, 0, 0, 0] + be32(2)) + box("tfdt", [0, 0, 0, 0] + be32(475_000)))
        let segment = box("styp", Array("msdh".utf8)) + box("moof", box("mfhd", [0, 0, 0, 0] + be32(1)) + videoTraf + audioTraf)
            + box("mdat", [1, 2, 3])
        // Audio at 475000 / 48000 s = 890625 ticks, before the video's 900000.
        #expect(MediaTimestampProbe.fragmentedMP4(initSegment: Data(initSegment), segment: Data(segment)) == 890_625)
        #expect(MediaTimestampProbe.fragmentedMP4(initSegment: Data(), segment: Data(segment)) == nil)
    }
}
