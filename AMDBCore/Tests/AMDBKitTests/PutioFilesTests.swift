import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct PutioFilesTests {
    /// Root: Movies/ (Heat.mkv, Dune.mkv), Notes.txt, Big.mkv
    func tree() -> FakePutio {
        let putio = FakePutio()
        putio.add(PutioFile(id: 1, name: "Movies", fileType: "FOLDER", size: 5000, parentId: 0, createdAt: "2026-01-01T00:00:00"), to: 0)
        putio.add(PutioFile(id: 2, name: "notes.txt", fileType: "TEXT", size: 10, parentId: 0, createdAt: "2026-10-01T00:00:00"), to: 0)
        putio.add(PutioFile(id: 3, name: "Big.mkv", fileType: "VIDEO", size: 9000, parentId: 0, createdAt: "2026-05-01T00:00:00"), to: 0)
        putio.add(PutioFile(id: 10, name: "Heat.mkv", fileType: "VIDEO", size: 3000, parentId: 1), to: 1)
        putio.add(PutioFile(id: 11, name: "Dune.mkv", fileType: "VIDEO", size: 2000, parentId: 1), to: 1)
        return putio
    }

    @Test func sortsFoldersFirstExceptBySize() async {
        let model = FileBrowserModel(folderID: 0, putio: tree())
        await model.load()
        #expect(model.files.map(\.name) == ["Movies", "Big.mkv", "notes.txt"])
        model.sort = .newest
        #expect(model.files.map(\.name) == ["Movies", "notes.txt", "Big.mkv"])
        model.sort = .largest
        #expect(model.files.map(\.name) == ["Big.mkv", "Movies", "notes.txt"])
    }

    @Test func renameMoveCopyAndDeleteReportChanges() async throws {
        let putio = tree()
        let model = FileBrowserModel(folderID: 0, putio: putio)
        var changes = 0
        model.onChange = { changes += 1 }
        await model.load()

        try await model.rename(model.files.first { $0.id == 2 }!, to: "  Readme.txt ")
        #expect(model.files.map(\.name) == ["Movies", "Big.mkv", "Readme.txt"])

        try await model.copy([3], to: 0)
        #expect(model.files.filter { $0.name == "Big.mkv" }.count == 2)

        try await model.move([3], to: 1)
        #expect(!model.files.contains { $0.id == 3 })
        #expect(putio.moved.last?.parent == 1)

        try await model.delete([2])
        #expect(!model.files.contains { $0.id == 2 })
        #expect(putio.trashed.map(\.id) == [2])
        #expect(changes == 4)
    }

    @Test func movingAFolderIntoItselfOrHereDoesNothing() async throws {
        let putio = tree()
        let model = FileBrowserModel(folderID: 0, putio: putio)
        await model.load()
        try await model.move([1], to: 1)
        try await model.move([3], to: 0)
        #expect(putio.moved.isEmpty)
    }

    @Test func aFailedCopyReloadsTheFolder() async {
        let putio = tree()
        putio.copyLimit = 1
        let model = FileBrowserModel(folderID: 0, putio: putio)
        await model.load()
        await #expect(throws: AppError.self) { try await model.copy([2, 3], to: 0) }
        // The one copy that went through shows up.
        #expect(model.files.count == 4)
    }

    @Test func newFolderIgnoresBlankNames() async throws {
        let putio = tree()
        let model = FileBrowserModel(folderID: 1, putio: putio)
        await model.load()
        try await model.createFolder(named: "   ")
        try await model.createFolder(named: "Extras")
        #expect(putio.createdFolders == ["Extras"])
        #expect(model.folders.map(\.name) == ["Extras"])
    }

    @Test func searchNeedsTwoLetters() async {
        let model = FileSearchModel(putio: tree())
        await model.search("h")
        #expect(model.results.isEmpty)
        await model.search("mkv")
        #expect(model.results.map(\.name) == ["Big.mkv", "Dune.mkv", "Heat.mkv"])
    }

    @Test func trashRestoreDeleteAndEmpty() async throws {
        let putio = tree()
        let browser = FileBrowserModel(folderID: 1, putio: putio)
        await browser.load()
        try await browser.delete([10, 11])
        let trash = TrashModel(putio: putio)
        await trash.load()
        #expect(trash.size == 5000)
        try await trash.restore([10])
        #expect(trash.files.map(\.id) == [11])
        #expect(trash.size == 2000)
        try await trash.empty()
        #expect(trash.files.isEmpty)
        #expect(putio.trashed.isEmpty)
    }

    @Test func storageShowsTheNewestAnswerEvenWhenAnOldOneArrivesLate() async {
        let putio = tree()
        putio.accountDelays = [.milliseconds(300)]
        let storage = PutioStorage()
        storage.configure(putio: putio)
        let slow = Task { await storage.refresh() }
        try? await Task.sleep(for: .milliseconds(50))
        putio.disk = PutioAccount.Disk(avail: 900, size: 1000, used: 100)
        await storage.refresh()
        await slow.value
        #expect(storage.disk?.avail == 900)
    }

    @Test func storageCountsTheTrash() async throws {
        let putio = tree()
        let browser = FileBrowserModel(folderID: 0, putio: putio)
        await browser.load()
        try await browser.delete([3])
        let storage = PutioStorage()
        storage.configure(putio: putio)
        await storage.refresh()
        #expect(storage.trashSize == 9000)
    }

    @Test func parsesPutioDates() {
        #expect(PutioDate.parse("2026-10-10T10:00:00") == Date(timeIntervalSince1970: 1_791_626_400))
        #expect(PutioDate.parse(nil) == nil)
    }
}
