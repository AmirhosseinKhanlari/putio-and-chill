import AMDBCore
import Foundation

/// What a finished put.io download turned out to hold. Fakes carry a program, or files with no video at all; those
/// are never played, are deleted (put.io keeps deleted files in its trash), and their release is never offered again.
/// A disc image isn't a fake: it gets the usual "no video in it" message and stays.
public enum DownloadCheck: Sendable, Equatable {
    /// A video is in it (or a real disc image, which the usual "no video" message covers).
    case video
    /// A program is in it: fake whatever else is there.
    case program(String)
    /// Files, but no video. put.io can list a finished folder before every file is in it, so this only counts
    /// once the transfer has had `TransferMonitor.fileGrace` to settle.
    case noVideo
    /// Nothing listed yet.
    case unknown

    public static let fakeMessage = "This download didn't contain a video — it looks fake. Removed it."

    /// Looks through a finished download, three folder levels down like `PlaybackResolver`.
    public static func inspect(_ fileID: Int64, putio: any PutioService) async -> DownloadCheck {
        guard let root = try? await putio.file(id: fileID) else { return .unknown }
        guard root.isFolder else { return verdict([root]) }
        var files: [PutioFile] = []
        var level = [root.id]
        for _ in 0..<3 where !level.isEmpty {
            var next: [Int64] = []
            for folderID in level {
                guard let listed = try? await putio.listFiles(parentID: folderID).files else { return .unknown }
                for file in listed {
                    if file.isFolder { next.append(file.id) } else { files.append(file) }
                }
            }
            level = next
        }
        return verdict(files)
    }

    static func verdict(_ files: [PutioFile]) -> DownloadCheck {
        guard !files.isEmpty else { return .unknown }
        if let program = files.first(where: { ReleaseSafety.isProgram($0.name) }) { return .program(program.name) }
        if files.contains(where: { $0.isVideo || ReleaseSafety.isDiscImage($0.name) }) { return .video }
        return .noVideo
    }

    /// The keys a fake release is remembered by: its lowercased info-hash and link (what `ReleaseAggregator.isBlocked`
    /// looks up).
    public static func badReleaseKeys(hash: String?, link: String?) -> Set<String> {
        Set([hash, link].compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }
}
