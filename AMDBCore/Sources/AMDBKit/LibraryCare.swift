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

    public func remove(fileID: Int64) async {
        records.removeAll { $0.fileID == fileID }
        await persist()
    }

    private func persist() async {
        let snapshot = records
        await store.update { $0.downloads = snapshot }
    }
}
