import AMDBCore
import Testing
@testable import AMDBKit

@Suite struct PutioPathsTests {
    @Test func picksLargestNestedVideo() async throws {
        let putio = FakePutio()
        putio.add(PutioFile(id: 500, name: "Release", fileType: "FOLDER"), to: 0)
        putio.add(PutioFile(id: 501, name: "small.mkv", fileType: "VIDEO", size: 10), to: 500)
        putio.add(PutioFile(id: 502, name: "Sub", fileType: "FOLDER"), to: 500)
        putio.add(PutioFile(id: 503, name: "big.mkv", fileType: "VIDEO", size: 900), to: 502)
        putio.add(PutioFile(id: 504, name: "notes.txt", fileType: "TEXT", size: 5000), to: 500)
        #expect(try await PlaybackResolver.playableFile(500, putio: putio)?.id == 503)
    }

    @Test func videoResolvesToItself() async throws {
        let putio = FakePutio()
        putio.add(PutioFile(id: 7, name: "a.mkv", fileType: "VIDEO"), to: 0)
        #expect(try await PlaybackResolver.playableFile(7, putio: putio)?.id == 7)
    }

    @Test func createsMissingFoldersOnceAndCaches() async throws {
        let putio = FakePutio()
        putio.add(PutioFile(id: 3, name: "AMDB", fileType: "FOLDER"), to: 0)
        let store = LocalStore(fileURL: nil)
        let first = try await FolderResolver.folderID(path: ["AMDB", "Movies"], putio: putio, store: store)
        let listsAfterFirst = putio.listCalls
        let second = try await FolderResolver.folderID(path: ["AMDB", "Movies"], putio: putio, store: store)
        #expect(first == second)
        #expect(putio.createdFolders == ["Movies"])
        #expect(putio.listCalls == listsAfterFirst)
        await FolderResolver.forget(path: ["AMDB", "Movies"], store: store)
        #expect(await store.snapshot.folderIDs.isEmpty)
    }
}
