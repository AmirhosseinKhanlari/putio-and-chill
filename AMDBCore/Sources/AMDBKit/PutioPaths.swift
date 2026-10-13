import AMDBCore
import Foundation

public enum PlaybackResolver {
    /// The largest video inside `fileID` (the file itself when it is a video), searching up to three folder levels.
    public static func playableFile(_ fileID: Int64, putio: any PutioService) async throws -> PutioFile? {
        let root = try await putio.file(id: fileID)
        if root.isVideo { return root }
        guard root.isFolder else { return nil }
        var best: PutioFile?
        var level = [root.id]
        for _ in 0..<3 where !level.isEmpty {
            var next: [Int64] = []
            for folderID in level {
                for file in try await putio.listFiles(parentID: folderID).files {
                    if file.isFolder {
                        next.append(file.id)
                    } else if file.isVideo, (file.size ?? 0) > (best?.size ?? -1) {
                        best = file
                    }
                }
            }
            level = next
        }
        return best
    }
}

public enum FolderResolver {
    /// Finds or creates `path` (e.g. ["AMDB", "Movies"]) under the put.io root and caches its id.
    public static func folderID(path: [String], putio: any PutioService, store: LocalStore) async throws -> Int64 {
        let key = path.joined(separator: "/")
        if let cached = await store.snapshot.folderIDs[key] { return cached }
        var parent: Int64 = 0
        for name in path {
            let children = try await putio.listFiles(parentID: parent).files
            if let existing = children.first(where: { $0.isFolder && $0.name == name }) {
                parent = existing.id
            } else {
                parent = try await putio.createFolder(name: name, parentID: parent).id
            }
        }
        let id = parent
        await store.update { $0.folderIDs[key] = id }
        return id
    }

    public static func forget(path: [String], store: LocalStore) async {
        let key = path.joined(separator: "/")
        await store.update { $0.folderIDs[key] = nil }
    }
}
