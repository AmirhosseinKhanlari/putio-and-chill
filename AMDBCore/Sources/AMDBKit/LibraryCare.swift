import AMDBCore
import Foundation
import Observation

public enum AutoCleaner {
    /// Movies finished in AMDB at least `olderThanDays` ago. Shows and unmatched files are never candidates.
    public static func candidates(entries: [LibraryEntry], finished: [FinishedFile], olderThanDays: Int?, now: Date) -> [LibraryEntry] {
        guard let days = olderThanDays else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let due = Set(finished.filter { $0.at <= cutoff }.map(\.fileID))
        return entries.filter { due.contains($0.id) && $0.match?.mediaType == .movie }
    }
}

/// Where an offline copy lives, kept relative to the app's home: the container path changes with app updates,
/// and the download system reports locations under /private/var while the home directory says /var.
public enum DownloadPaths {
    /// What to save for a finished download's location.
    public static func stored(location: String, home: String) -> String {
        if let library = librarySuffix(location) { return library }
        let homeVariants = [home, "/private" + home, home.replacingOccurrences(of: "/private", with: "")]
        for prefix in homeVariants where location.hasPrefix(prefix + "/") {
            return String(location.dropFirst(prefix.count + 1))
        }
        return location
    }

    /// The absolute path for a saved location in the current container (also fixes records saved by older builds).
    public static func resolve(stored: String, home: String) -> String {
        guard stored.hasPrefix("/") else { return home + "/" + stored }
        if let library = librarySuffix(stored), stored.contains("/Containers/Data/Application/") {
            return home + "/" + library
        }
        return stored
    }

    private static func librarySuffix(_ path: String) -> String? {
        guard let range = path.range(of: "/Library/") else { return nil }
        return String(path[path.index(after: range.lowerBound)...])
    }
}

/// Offline copies on this device.
@Observable @MainActor
public final class DownloadsIndex {
    public private(set) var records: [DownloadRecord] = []
    @ObservationIgnored private let store: LocalStore

    public init(store: LocalStore) { self.store = store }

    public func load() async { records = await store.snapshot.downloads }

    public func record(fileID: Int64) -> DownloadRecord? { records.first { $0.fileID == fileID } }

    public func upsert(_ record: DownloadRecord) async {
        if let index = records.firstIndex(where: { $0.fileID == record.fileID }) { records[index] = record } else { records.insert(record, at: 0) }
        await persist()
    }

    public func update(fileID: Int64, _ mutate: (inout DownloadRecord) -> Void) async {
        guard let index = records.firstIndex(where: { $0.fileID == fileID }) else { return }
        mutate(&records[index])
        await persist()
    }

    /// Download progress. Delegate callbacks can arrive out of order, so a late progress report never turns a
    /// finished download back into a running one.
    public func progress(fileID: Int64, _ value: Double) async {
        guard let index = records.firstIndex(where: { $0.fileID == fileID }) else { return }
        if case .done = records[index].state { return }
        records[index].state = .downloading(progress: value)
        await persist()
    }

    /// Finished downloads, newest first.
    public var finished: [DownloadRecord] {
        records.filter { if case .done = $0.state { true } else { false } }
    }

    public func remove(fileID: Int64) async {
        records.removeAll { $0.fileID == fileID }
        await persist()
    }

    private func persist() async {
        let snapshot = records
        await store.update { $0.downloads = snapshot }
    }
}
