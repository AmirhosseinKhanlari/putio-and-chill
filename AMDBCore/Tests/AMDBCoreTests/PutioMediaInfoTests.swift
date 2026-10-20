import Foundation
import Testing
@testable import AMDBCore

@Suite struct PutioMediaInfoTests {
    /// put.io's media_info is FFmpeg's stream list: codec names and types, plus the container.
    @Test func readsStreamsFromMediaInfo() async throws {
        let json = #"""
        {"status":"OK","file":{"id":7,"name":"Old.Movie.avi","file_type":"VIDEO","need_convert":true,"is_mp4_available":false,
         "content_type_and_codecs":"video/x-msvideo","media_info":{"format":{"name":"avi","duration":20.0},"mime_type":"video/x-msvideo",
         "playback_issues":[],"streams":[{"codec_type":"video","codec_name":"mpeg4","width":640,"height":360,"level":-99},
         {"codec_type":"audio","codec_name":"mp3","channels":2},{"codec_type":"subtitle","codec_name":"subrip"}]}}}
        """#
        let stub = StubTransport(json: json)
        let info = try await PutioClient(token: "T", transport: stub).mediaInfo(fileID: 7)
        #expect(info.videoCodecs == ["mpeg4"])
        #expect(info.audioCodecs == ["mp3"])
        #expect(info.container == "avi")
        #expect(info.needConvert == true)
        #expect(info.isMp4Available == false)
        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/v2/files/7")
        #expect(request.queryItems["codecs"] == "1")
        #expect(request.queryItems["media_info"] == "1")
        #expect(request.queryItems["mp4_status"] == "1")
    }

    /// Without media_info: the RFC 6381 codecs in the MIME type, or video_metadata's codec.
    @Test func fallsBackToMIMECodecsAndVideoMetadata() throws {
        let mime = try decode(#"{"content_type_and_codecs":"video/mp4; codecs=\"avc1.640028, mp4a.40.2\""}"#)
        #expect(mime.videoCodecs == ["h264"])
        #expect(mime.audioCodecs == ["aac"])
        let metadata = try decode(#"{"video_metadata":{"codec":"MPEG4","height":360},"content_type_and_codecs":"video/x-msvideo"}"#)
        #expect(metadata.videoCodecs == ["mpeg4"])
        #expect(metadata.audioCodecs.isEmpty)
    }

    /// Unexpected shapes are skipped, never an error: the player then just tries Apple's first.
    @Test func oddShapesDecodeAsUnknown() throws {
        let odd = try decode(#"{"media_info":{"streams":[{"codec_type":"video","codec_name":null},{"codec_type":7},"x",{"codec_type":"audio","codec_name":"DTS"}]},"need_convert":"yes"}"#)
        #expect(odd.videoCodecs.isEmpty)
        #expect(odd.audioCodecs == ["dts"])
        #expect(odd.needConvert == nil)
        let empty = try decode(#"{"media_info":null,"video_metadata":null}"#)
        #expect(empty.isEmpty)
    }

    private func decode(_ json: String) throws -> PutioMediaInfo {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PutioMediaInfo.self, from: Data(json.utf8))
    }
}
