import Foundation
import Testing
@testable import AMDBCore

@Suite struct HTTPTests {
    struct Payload: Decodable, Equatable { let value: Int }

    @Test func decodesSuccess() async throws {
        let http = HTTPRequester(service: "x", transport: StubTransport(json: #"{"value": 3}"#))
        let result = try await http.decode(Payload.self, .get(URL(string: "https://e.test/a")!))
        #expect(result == Payload(value: 3))
    }

    @Test func maps401ToUnauthorized() async {
        let http = HTTPRequester(service: "putio", transport: StubTransport(status: 401, json: "{}"))
        await #expect(throws: AppError.unauthorized(service: "putio")) {
            _ = try await http.data(.get(URL(string: "https://e.test/a")!))
        }
    }

    @Test func mapsOtherStatusToHTTPError() async {
        let http = HTTPRequester(service: "yts", transport: StubTransport(status: 503, json: "{}"))
        await #expect(throws: AppError.http(service: "yts", status: 503)) {
            _ = try await http.data(.get(URL(string: "https://e.test/a")!))
        }
    }

    @Test func mapsBadJSONToDecodingError() async {
        let http = HTTPRequester(service: "tmdb", transport: StubTransport(json: "[]"))
        do {
            _ = try await http.decode(Payload.self, .get(URL(string: "https://e.test/a")!))
            Issue.record("expected throw")
        } catch let AppError.decoding(service, _) {
            #expect(service == "tmdb")
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func formBodyIsPercentEncoded() {
        let req = URLRequest.postForm(URL(string: "https://e.test/f")!, fields: [("url", "magnet:?xt=urn:btih:ab&dn=A B")])
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(req.bodyString == "url=magnet%3A%3Fxt%3Durn%3Abtih%3Aab%26dn%3DA%20B")
    }

    @Test func lossyInt64AcceptsStringsAndNumbers() throws {
        struct Row: Decodable { let a: LossyInt64; let b: LossyInt64; let c: LossyInt64 }
        let row = try JSONDecoder().decode(Row.self, from: Data(#"{"a": "42", "b": 7, "c": "x"}"#.utf8))
        #expect(row.a.value == 42)
        #expect(row.b.value == 7)
        #expect(row.c.value == nil)
    }

    @Test func mediaQuerySearchText() {
        #expect(MediaQuery.movie(imdbID: "tt1", title: "Dune", year: 2021).searchText == "Dune 2021")
        #expect(MediaQuery.episode(imdbID: "tt2", title: "Severance", season: 2, episode: 4).searchText == "Severance S02E04")
        #expect(MediaQuery.season(imdbID: "tt2", title: "Severance", season: 1).searchText == "Severance S01")
        #expect(MediaQuery.text("free text").imdbID == nil)
    }
}
