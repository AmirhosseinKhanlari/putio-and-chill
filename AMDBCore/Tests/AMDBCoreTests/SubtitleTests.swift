import Foundation
import Testing
@testable import AMDBCore

@Suite struct SubtitleParserTests {
    @Test func parsesSRTWithTagsAndCRLF() {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i> there\r\n{\\an8}General Kenobi\r\n\r\n2\r\n00:01:00,250 --> 00:01:02,000\r\nSecond\r\n"
        let track = SubtitleParser.parse(srt)
        #expect(track.cues == [SubtitleCue(start: 1, end: 3.5, text: "Hello there\nGeneral Kenobi"),
                               SubtitleCue(start: 60.25, end: 62, text: "Second")])
    }

    @Test func parsesWebVTTWithShortTimesAndSettings() {
        let vtt = "WEBVTT\n\nNOTE comment\n\n00:05.000 --> 00:07.000 align:start\nShort form\n\n01:00:00.000 --> 01:00:01.000\nLong form\n"
        let track = SubtitleParser.parse(vtt)
        #expect(track.cues.map(\.start) == [5, 3600])
        #expect(track.cues.first?.text == "Short form")
    }

    @Test func looksUpTextByTimeIncludingOverlaps() {
        let track = SubtitleTrack(cues: [SubtitleCue(start: 10, end: 20, text: "B"), SubtitleCue(start: 1, end: 4, text: "A"),
                                         SubtitleCue(start: 15, end: 16, text: "C")])
        #expect(track.text(at: 0.5) == nil)
        #expect(track.text(at: 2) == "A")
        #expect(track.text(at: 4) == nil)
        #expect(track.text(at: 15.5) == "B\nC")
        #expect(track.text(at: 25) == nil)
    }

    @Test func skipsBrokenBlocks() {
        #expect(SubtitleParser.parse("1\nnot a time\nText\n\n2\n00:00:05,000 --> 00:00:04,000\nBackwards").cues.isEmpty)
    }
}

@Suite struct OpenSubtitlesHashTests {
    @Test func sumsSizeAndLittleEndianWords() {
        var head = Data(count: OpenSubtitlesHash.chunkSize)
        head[0] = 0x01                       // word 0 = 1
        head[8] = 0x00; head[15] = 0x01      // word 1 = 1 << 56
        var tail = Data(count: OpenSubtitlesHash.chunkSize)
        tail[OpenSubtitlesHash.chunkSize - 8] = 0xFF  // last word = 255
        let hash = OpenSubtitlesHash.compute(size: 200_000, head: head, tail: tail)
        #expect(hash == String(format: "%016llx", UInt64(200_000) &+ 1 &+ (1 << 56) &+ 255))
    }

    @Test func overflowWrapsAndSmallFilesHaveNoHash() {
        let ones = Data(repeating: 0xFF, count: OpenSubtitlesHash.chunkSize)
        #expect(OpenSubtitlesHash.compute(size: 1 << 20, head: ones, tail: ones)?.count == 16)
        #expect(OpenSubtitlesHash.compute(size: 1000, head: Data(), tail: Data()) == nil)
    }

    @Test func readsChunksWithRangeRequests() async throws {
        let stub = StubTransport { _ in (206, Data(count: OpenSubtitlesHash.chunkSize)) }
        let hash = try await OpenSubtitlesHash.compute(url: URL(string: "https://file.test/1")!, size: 1_000_000, transport: stub)
        #expect(hash == String(format: "%016llx", UInt64(1_000_000)))
        let ranges = Set(stub.requests.compactMap { $0.value(forHTTPHeaderField: "Range") })
        #expect(ranges == ["bytes=0-65535", "bytes=934464-999999"])
    }
}

@Suite struct OpenSubtitlesClientTests {
    static let searchJSON = #"""
    {"total_count":3,"data":[
      {"id":"1","type":"subtitle","attributes":{"language":"en","release":"Popular.WEB","download_count":9000,"from_trusted":false,
        "files":[{"file_id":11,"file_name":"a.srt"}]}},
      {"id":"2","type":"subtitle","attributes":{"language":"en","release":"Exact.Match","download_count":10,"moviehash_match":true,
        "files":[{"file_id":22,"file_name":"b.srt"}]}},
      {"id":"3","type":"subtitle","attributes":{"language":"en","release":"Robot","download_count":99999,"ai_translated":true,
        "files":[{"file_id":33}]}},
      {"id":"4","type":"subtitle","attributes":{"language":"en","files":[]}}
    ]}
    """#

    @Test func searchesEpisodesBySortedLowercaseParamsAndRanksResults() async throws {
        let stub = StubTransport(json: Self.searchJSON)
        let client = OpenSubtitlesClient(apiKey: "KEY", transport: stub)
        let results = try await client.search(SubtitleSearch(tmdbID: 95396, kind: .tv, season: 2, episode: 3, query: nil,
                                                             languages: ["FR", "en"], movieHash: "ABCDEF0123456789"))
        #expect(results.map(\.fileID) == [22, 11, 33])
        #expect(results.first?.hashMatch == true)
        #expect(results.last?.machineTranslated == true)
        let request = try #require(stub.requests.first)
        #expect(request.url?.query() == "episode_number=3&languages=en,fr&moviehash=abcdef0123456789&parent_tmdb_id=95396&season_number=2&type=episode")
        #expect(request.value(forHTTPHeaderField: "Api-Key") == "KEY")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "AMDB v1.0")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func moviesUseTMDBID() {
        let url = OpenSubtitlesClient(apiKey: "K", transport: StubTransport(json: "{}"))
            .searchURL(SubtitleSearch(tmdbID: 693134, kind: .movie, season: nil, episode: nil, query: nil, languages: ["en"], movieHash: nil))
        #expect(url.query() == "languages=en&tmdb_id=693134&type=movie")
    }

    @Test func downloadSendsTokenAndReturnsLink() async throws {
        let stub = StubTransport(json: #"{"link":"https://dl.test/x.srt","file_name":"x.srt","requests":3,"remaining":17}"#)
        let download = try await OpenSubtitlesClient(apiKey: "K", transport: stub)
            .download(fileID: 22, login: OpenSubtitlesLogin(token: "JWT", allowedDownloads: 1000, isVIP: true, host: "vip-api.opensubtitles.com"))
        #expect(download == SubtitleDownload(link: URL(string: "https://dl.test/x.srt")!, remaining: 17))
        let request = try #require(stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer JWT")
        #expect(request.url?.absoluteString == "https://vip-api.opensubtitles.com/api/v1/download")
        #expect(request.bodyString.contains(#""file_id":22"#))
    }

    @Test func quotaAndBadLoginMapToFriendlyErrors() async throws {
        let quota = OpenSubtitlesClient(apiKey: "K", transport: StubTransport(status: 406, json: #"{"message":"limit"}"#))
        await #expect(throws: OpenSubtitlesError.quotaReached) { try await quota.download(fileID: 1, login: nil) }
        let login = OpenSubtitlesClient(apiKey: "K", transport: StubTransport(status: 401, json: #"{"message":"no"}"#))
        await #expect(throws: OpenSubtitlesError.badCredentials) { try await login.login(username: "u", password: "p") }
    }

    @Test func loginReturnsToken() async throws {
        let stub = StubTransport(json: #"{"user":{"allowed_downloads":1000,"vip":true},"base_url":"vip-api.opensubtitles.com","token":"JWT","status":200}"#)
        let login = try await OpenSubtitlesClient(apiKey: "K", transport: stub).login(username: "u", password: "p")
        #expect(login == OpenSubtitlesLogin(token: "JWT", allowedDownloads: 1000, isVIP: true, host: "vip-api.opensubtitles.com"))
    }

    @Test func ignoresUnexpectedHosts() {
        let client = OpenSubtitlesClient(apiKey: "K", transport: StubTransport(json: "{}"))
        #expect(client.apiURL(host: "evil.example.com").host() == "api.opensubtitles.com")
        #expect(client.apiURL(host: nil).host() == "api.opensubtitles.com")
    }
}
