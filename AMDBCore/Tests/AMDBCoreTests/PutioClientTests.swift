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

    @Test func hlsURLCarriesTokenAndOptionalSubtitles() {
        let client = PutioClient(token: "T", transport: StubTransport(json: "{}"))
        #expect(client.hlsURL(fileID: 42).absoluteString == "https://api.put.io/v2/files/42/hls/media.m3u8?subtitle_key=all&oauth_token=T")
        #expect(client.hlsURL(fileID: 42, subtitles: false).absoluteString == "https://api.put.io/v2/files/42/hls/media.m3u8?oauth_token=T")
    }

    @Test func listsAndDownloadsSubtitles() async throws {
        let list = StubTransport(json: #"{"subtitles":[{"key":"abc","language":"English","language_code":"eng","name":"Movie.srt","source":"folder"}],"default":"abc"}"#)
        let tracks = try await PutioClient(token: "T", transport: list).subtitles(fileID: 7)
        #expect(tracks == [PutioSubtitle(key: "abc", language: "English", languageCode: "eng", name: "Movie.srt", source: "folder")])
        let file = StubTransport { _ in (200, Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8)) }
        let text = try await PutioClient(token: "T", transport: file).subtitleText(fileID: 7, key: "abc")
        #expect(text.contains("Hi"))
        let request = try #require(file.requests.first)
        #expect(request.url?.path == "/v2/files/7/subtitles/abc")
        #expect(request.url?.query() == "format=srt")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "token T")
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

    @Test func accountInfoIsNeverServedFromCacheAndIncludesTrash() async throws {
        let stub = StubTransport(json: #"{"status":"OK","info":{"username":"a","disk":{"avail":1,"size":2,"used":1},"trash_size":5000}}"#)
        let info = try await PutioClient(token: "T", transport: stub).accountInfo()
        #expect(info.trashSize == 5000)
        #expect(stub.requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func renameCopyAndSearch() async throws {
        let stub = StubTransport(json: #"{"status":"OK","file":{"id":44,"name":"Heat.mkv","file_type":"VIDEO","parent_id":9},"files":[{"id":3,"name":"Heat.mkv","file_type":"VIDEO"}]}"#)
        let client = PutioClient(token: "T", transport: stub)
        try await client.renameFile(id: 3, name: "Heat (1995).mkv")
        let copy = try await client.copyFile(id: 3, to: 9)
        let found = try await client.searchFiles("heat")
        #expect(copy.id == 44)
        #expect(found.map(\.id) == [3])
        #expect(stub.requests[0].url?.path == "/v2/files/rename")
        #expect(stub.requests[0].bodyString == "file_id=3&name=Heat%20%281995%29.mkv")
        #expect(stub.requests[1].url?.path == "/v2/files/copy")
        #expect(stub.requests[1].bodyString == "file_id=3&parent_id=9")
        #expect(stub.requests[2].queryItems["query"] == "heat")
    }

    @Test func trashListRestoreAndEmpty() async throws {
        let stub = StubTransport(json: #"{"status":"OK","total":1,"cursor":null,"trash_size":2000,"files":[{"id":8,"name":"Old.mkv","file_type":"VIDEO","size":2000,"deleted_at":"2026-10-01T10:00:00","expiration_date":"2026-10-31T10:00:00","parent_id":0,"content_type":null,"created_at":"2026-09-01T10:00:00","extension":"mkv","first_accessed_at":null,"folder_type":"REGULAR","icon":null,"screenshot":null}]}"#)
        let client = PutioClient(token: "T", transport: stub)
        let trash = try await client.trash()
        try await client.restoreFromTrash(ids: [8])
        try await client.deleteFromTrash(ids: [8, 9])
        try await client.emptyTrash()
        #expect(trash.trashSize == 2000)
        #expect(trash.files.first?.expirationDate == "2026-10-31T10:00:00")
        #expect(stub.requests.map { $0.url?.path ?? "" } == ["/v2/trash/list", "/v2/trash/restore", "/v2/trash/delete", "/v2/trash/empty"])
        #expect(stub.requests[2].bodyString == "file_ids=8%2C9")
    }
}
