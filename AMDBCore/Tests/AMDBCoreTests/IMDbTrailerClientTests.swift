import Foundation
import Testing
@testable import AMDBCore

@Suite struct IMDbTrailerClientTests {
    static let json = #"""
    {"data":{"title":{"primaryVideos":{"edges":[
      {"node":{"id":"vi1","name":{"value":"Featurette"},"contentType":{"displayName":{"value":"Featurette"}},
               "playbackURLs":[{"url":"https://v.test/f.mp4","videoMimeType":"MP4","videoDefinition":"DEF_1080p"}]}},
      {"node":{"id":"vi2","name":{"value":"Trailer #4"},"contentType":{"displayName":{"value":"Trailer"}},
               "playbackURLs":[{"url":"https://v.test/t-1080.mp4","videoMimeType":"MP4","videoDefinition":"DEF_1080p"},
                               {"url":"https://v.test/t.m3u8","videoMimeType":"M3U8","videoDefinition":"DEF_AUTO"},
                               {"url":"https://v.test/t-480.mp4","videoMimeType":"MP4","videoDefinition":"DEF_480p"}]}}
    ]}}}}
    """#

    @Test func prefersTrailerAndHLS() async throws {
        let stub = StubTransport(json: Self.json)
        let trailer = try await IMDbTrailerClient(transport: stub).trailer(imdbID: "tt0816692")
        #expect(trailer?.name == "Trailer #4")
        #expect(trailer?.url.absoluteString == "https://v.test/t.m3u8")
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.host() == "caching.graphql.imdb.com")
        #expect(request.bodyString.contains("tt0816692"))
    }

    @Test func fallsBackToBestMP4AndFirstVideo() async throws {
        let json = #"{"data":{"title":{"primaryVideos":{"edges":[{"node":{"id":"v","name":{"value":"Clip"},"playbackURLs":[{"url":"https://v.test/480.mp4","videoMimeType":"MP4","videoDefinition":"DEF_480p"},{"url":"https://v.test/1080.mp4","videoMimeType":"MP4","videoDefinition":"DEF_1080p"}]}}]}}}}"#
        let trailer = try await IMDbTrailerClient(transport: StubTransport(json: json)).trailer(imdbID: "tt1")
        #expect(trailer?.url.absoluteString == "https://v.test/1080.mp4")
    }

    @Test func noVideosIsNil() async throws {
        let json = #"{"data":{"title":{"primaryVideos":{"edges":[]}}}}"#
        #expect(try await IMDbTrailerClient(transport: StubTransport(json: json)).trailer(imdbID: "tt1") == nil)
        let missing = #"{"data":{"title":null}}"#
        #expect(try await IMDbTrailerClient(transport: StubTransport(json: missing)).trailer(imdbID: "tt1") == nil)
    }
}
