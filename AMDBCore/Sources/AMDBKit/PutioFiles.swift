import AMDBCore
import Foundation

/// put.io's space: used, free, and how much sits in the trash. Refreshed on demand (pull to refresh, after every
/// file change); a slower, older answer never overwrites a newer one.
@Observable @MainActor
public final class PutioStorage {
    public private(set) var disk: PutioAccount.Disk?
    public private(set) var trashSize: Int64 = 0
    @ObservationIgnored private var putio: (any PutioService)?
    @ObservationIgnored private var latestRequest = 0

    public init() {}

    public func configure(putio: (any PutioService)?) {
        self.putio = putio
        latestRequest += 1
        if putio == nil { disk = nil; trashSize = 0 }
    }

    public func refresh() async {
        guard let putio else { return }
        latestRequest += 1
        let request = latestRequest
        guard let info = try? await putio.accountInfo(), request == latestRequest else { return }
        disk = info.disk
        trashSize = info.trashSize ?? 0
    }
}

/// How a folder is ordered. Name and date keep folders on top, like Finder; size mixes them to find what's big.
public enum FileSort: String, CaseIterable, Sendable {
    case name, newest, largest

    public func sorted(_ files: [PutioFile]) -> [PutioFile] {
        files.sorted { a, b in
            if self != .largest, a.isFolder != b.isFolder { return a.isFolder }
            switch self {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .newest: return (a.createdAt ?? "") > (b.createdAt ?? "")
            case .largest: return (a.size ?? 0) > (b.size ?? 0)
            }
        }
    }
}

extension PutioFile {
    func renamed(_ name: String) -> PutioFile {
        PutioFile(id: id, name: name, fileType: fileType, contentType: contentType, size: size, parentId: parentId,
                  createdAt: createdAt, updatedAt: updatedAt, firstAccessedAt: firstAccessedAt, startFrom: startFrom,
                  screenshot: screenshot)
    }

    /// put.io's timestamps ("2026-10-10T10:00:00", UTC).
    public var createdDate: Date? { PutioDate.parse(createdAt) }
}

public enum PutioDate {
    public static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: String(text.prefix(26))) { return date }
        }
        return nil
    }
}

/// One put.io folder in the file manager: list, sort, and change what's in it.
@Observable @MainActor
public final class FileBrowserModel {
    public let folderID: Int64
    public private(set) var folder: PutioFile?
    public private(set) var files: [PutioFile] = []
    public private(set) var loaded = false
    public private(set) var errorMessage: String?
    public var sort: FileSort { didSet { files = sort.sorted(files) } }
    /// Called after anything changes put.io (to update the library and free space).
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private let putio: any PutioService

    public init(folderID: Int64, putio: any PutioService, sort: FileSort = .name) {
        self.folderID = folderID
        self.putio = putio
        self.sort = sort
    }

    public var folders: [PutioFile] { files.filter(\.isFolder) }

    public func load() async {
        do {
            let list = try await putio.listFiles(parentID: folderID)
            folder = list.parent
            files = sort.sorted(list.files)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Couldn't read this folder from put.io."
        }
        loaded = true
    }

    public func createFolder(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let created = try await putio.createFolder(name: trimmed, parentID: folderID)
        files = sort.sorted(files + [created])
        onChange?()
    }

    public func rename(_ file: PutioFile, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != file.name else { return }
        try await putio.renameFile(id: file.id, name: trimmed)
        files = sort.sorted(files.map { $0.id == file.id ? $0.renamed(trimmed) : $0 })
        onChange?()
    }

    public func move(_ ids: Set<Int64>, to parentID: Int64) async throws {
        guard !ids.isEmpty, parentID != folderID, !ids.contains(parentID) else { return }
        try await putio.moveFiles(ids: ordered(ids), to: parentID)
        files.removeAll { ids.contains($0.id) }
        onChange?()
    }

    /// put.io copies one item at a time; a failure part-way reloads the folder so it shows what really happened.
    public func copy(_ ids: Set<Int64>, to parentID: Int64) async throws {
        guard !ids.isEmpty else { return }
        defer { onChange?() }
        var copies: [PutioFile] = []
        do {
            for id in ordered(ids) { copies.append(try await putio.copyFile(id: id, to: parentID)) }
        } catch {
            if parentID == folderID { await load() }
            throw error
        }
        if parentID == folderID { files = sort.sorted(files + copies) }
    }

    /// Moves them to put.io's trash (restorable until it's emptied).
    public func delete(_ ids: Set<Int64>) async throws {
        guard !ids.isEmpty else { return }
        try await putio.deleteFiles(ids: ordered(ids))
        files.removeAll { ids.contains($0.id) }
        onChange?()
    }

    private func ordered(_ ids: Set<Int64>) -> [Int64] {
        files.map(\.id).filter(ids.contains) + ids.subtracting(files.map(\.id)).sorted()
    }
}

/// Search across the whole put.io account.
@Observable @MainActor
public final class FileSearchModel {
    public private(set) var results: [PutioFile] = []
    public private(set) var searching = false
    @ObservationIgnored private let putio: any PutioService

    public init(putio: any PutioService) { self.putio = putio }

    public func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { results = []; return }
        searching = true
        defer { searching = false }
        guard let found = try? await putio.searchFiles(trimmed), !Task.isCancelled else { return }
        results = FileSort.name.sorted(found)
    }
}

/// put.io's trash: restore, delete for good, or empty it to free the space.
@Observable @MainActor
public final class TrashModel {
    public private(set) var files: [PutioTrashFile] = []
    public private(set) var size: Int64 = 0
    public private(set) var loaded = false
    public private(set) var errorMessage: String?
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private let putio: any PutioService

    public init(putio: any PutioService) { self.putio = putio }

    public func load() async {
        do {
            let trash = try await putio.trash()
            files = trash.files.sorted { ($0.deletedAt ?? "") > ($1.deletedAt ?? "") }
            size = trash.trashSize ?? trash.files.reduce(0) { $0 + ($1.size ?? 0) }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Couldn't read the trash from put.io."
        }
        loaded = true
    }

    public func restore(_ ids: Set<Int64>) async throws {
        guard !ids.isEmpty else { return }
        try await putio.restoreFromTrash(ids: files.map(\.id).filter(ids.contains))
        remove(ids)
    }

    public func deleteForever(_ ids: Set<Int64>) async throws {
        guard !ids.isEmpty else { return }
        try await putio.deleteFromTrash(ids: files.map(\.id).filter(ids.contains))
        remove(ids)
    }

    public func empty() async throws {
        try await putio.emptyTrash()
        files = []
        size = 0
        onChange?()
    }

    private func remove(_ ids: Set<Int64>) {
        files.removeAll { ids.contains($0.id) }
        size = files.reduce(0) { $0 + ($1.size ?? 0) }
        onChange?()
    }
}
