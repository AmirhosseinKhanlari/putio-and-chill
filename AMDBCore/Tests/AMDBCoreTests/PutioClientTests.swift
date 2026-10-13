import Foundation
import Testing
@testable import AMDBCore

@Suite struct PutioClientTests {
    static let transferJSON = #"{"id":77,"name":"Furiosa","status":"DOWNLOADING","percent_done":64,"down_speed":48000000,"peers_connected":112,"estimated_time":60,"downloaded":1900000000,"size":2900000000,"hash":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","file_id":null,"save_parent_id":5,"error_message":null}"#

    @Test func addTransferPostsFormWithAuth() async throws {
        let stub = StubTransport(json: #"{"status":"OK","transfer":\#(Self.transferJSON)}"#)
        let client = PutioClient(token: "T", transport: stub)
        let transfer = try await client.addTransfer(url: "magnet:?xt=urn:btih:ee", saveParentID: 5)
        #expect(transfer.id == 77)
        #expect(transfer.percentDone == 64)
        #expect(transfer.peersConnected == 112)
        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "https://api.put.io/v2/transfers/add")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "token T")
        #expect(request.bodyString == "url=magnet%3A%3Fxt%3Durn%3Abtih%3Aee&save_parent_id=5")
    }

    @Test func listFilesDecodesFolderAndVideo() async throws {
        let json = #"{"status":"OK","parent":{"id":0,"name":"Your Files","file_type":"FOLDER"},"files":[{"id":1,"name":"AMDB","file_type":"FOLDER","parent_id":0},{"id":2,"name":"Dune.Part.Two.2024.1080p.mkv","file_type":"VIDEO","size":3000000000,"parent_id":0,"start_from":125,"updated_at":"2026-10-01T10:00:00"}]}"#
        let stub = StubTransport(json: json)
        let list = try await PutioClient(token: "T", transport: stub).listFiles(parentID: 0)
        #expect(list.parent?.name == "Your Files")
        #expect(list.files.map(\.isFolder) == [true, false])
        #expect(list.files[1].isVideo)
        #expect(list.files[1].startFrom == 125)
        #expect(stub.requests.first?.queryItems["parent_id"] == "0")
    }

    @Test func startFromRoundTrip() async throws {
        let stub = StubTransport { request in
            request.url!.path.hasSuffix("/start-from/set") ? (200, Data(#"{"status":"OK"}"#.utf8)) : (200, Data(#"{"status":"OK","start_from":4360}"#.utf8))
        }
        let client = PutioClient(token: "T", transport: stub)
        #expect(try await client.startFrom(fileID: 9) == 4360)
        try await client.setStartFrom(fileID: 9, seconds: 4400)
        #expect(stub.requests[1].url?.path == "/v2/files/9/start-from/set")
        #expect(stub.requests[1].bodyString == "time=4400")
    }

    @Test func hlsURLCarriesTokenAndSubtitles() {
        let url = PutioClient(token: "T", transport: StubTransport(json: "{}")).hlsURL(fileID: 42)
        #expect(url.absoluteString == "https://api.put.io/v2/files/42/hls/media.m3u8?subtitle_key=all&oauth_token=T")
    }

    @Test func authorizeURLAndCallbackParsing() throws {
        let url = PutioClient.authorizeURL(clientID: "9877", redirectURI: "amdb://oauth/putio")
        #expect(url.absoluteString == "https://api.put.io/v2/oauth2/authenticate?client_id=9877&response_type=token&redirect_uri=amdb://oauth/putio")
        #expect(PutioClient.token(fromCallback: URL(string: "amdb://oauth/putio#access_token=ABC123")!) == "ABC123")
        #expect(PutioClient.token(fromCallback: URL(string: "amdb://oauth/putio#error=access_denied")!) == nil)
    }

    @Test func cancelSendsCommaSeparatedIDs() async throws {
        let stub = StubTransport(json: #"{"status":"OK"}"#)
        try await PutioClient(token: "T", transport: stub).cancelTransfers(ids: [1, 2])
        #expect(stub.requests.first?.bodyString == "transfer_ids=1%2C2")
    }

    @Test func accountInfoIncludesDisk() async throws {
        let stub = StubTransport(json: #"{"status":"OK","info":{"username":"ameerr","mail":"a@b.c","disk":{"avail":700000000000,"size":1000000000000,"used":300000000000}}}"#)
        let info = try await PutioClient(token: "T", transport: stub).accountInfo()
        #expect(info.disk?.used == 300_000_000_000)
        #expect(info.disk?.size == 1_000_000_000_000)
        #expect(info.disk?.fractionUsed == 0.3)
    }

    @Test func deleteFilesPostsCommaSeparatedIDs() async throws {
        let stub = StubTransport(json: #"{"status":"OK"}"#)
        try await PutioClient(token: "T", transport: stub).deleteFiles(ids: [5, 9])
        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/v2/files/delete")
        #expect(request.bodyString == "file_ids=5%2C9")
    }
}
