import AMDBCore
import AMDBKit
import AVFoundation
import Observation

/// Offline copies via Apple's HLS download system (same as the Apple TV app): resumable, keeps subtitles,
/// plays in the same native player. Not supported in the iOS Simulator.
@Observable @MainActor
final class OfflineDownloader: NSObject, AVAssetDownloadDelegate {
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var session: AVAssetDownloadURLSession?
    @ObservationIgnored private var tasks: [Int64: AVAssetDownloadTask] = [:]
    /// Where each running download is being written, from willDownloadTo (newer iOS reports it there).
    @ObservationIgnored private var locations: [Int64: String] = [:]

    init(app: AppModel) {
        self.app = app
        super.init()
    }

    private func ensureSession() -> AVAssetDownloadURLSession {
        if let session { return session }
        let made = AVAssetDownloadURLSession(configuration: .background(withIdentifier: "app.amdb.downloads"),
                                             assetDownloadDelegate: self, delegateQueue: .main)
        session = made
        return made
    }

    /// Re-attaches to downloads that continued while the app was closed.
    func restore() {
        guard Self.isSupported else { return }
        ensureSession().getAllTasks { tasks in
            MainActor.assumeIsolated {
                for case let task as AVAssetDownloadTask in tasks {
                    if let id = task.taskDescription.flatMap(Int64.init) { self.tasks[id] = task }
                }
            }
        }
    }

    func start(_ entry: LibraryEntry) async {
        guard Self.isSupported, let putio = app.putio, tasks[entry.id] == nil else { return }
        let match = entry.match
        await app.downloads.upsert(DownloadRecord(
            fileID: entry.id, title: entry.displayTitle, posterPath: match?.posterPath, tmdbID: match?.tmdbID,
            kind: match?.mediaType, season: match?.season, episode: match?.episode, state: .queued))
        // Subtitles aren't muxed into the copy; put.io's subtitle files are saved next to it so the app's own
        // subtitles menu works offline too.
        let fileID = entry.id
        Task { await app.cachePutioSubtitles(fileID: fileID) }
        let asset = AVURLAsset(url: putio.hlsURL(fileID: entry.id, subtitles: false))
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: entry.displayTitle)
        if let selections = try? await asset.load(.allMediaSelections) {
            configuration.primaryContentConfiguration.mediaSelections = selections
        }
        if app.settings.downloadDataSaver {
            configuration.primaryContentConfiguration.variantQualifiers = [
                AVAssetVariantQualifier(predicate: NSPredicate(format: "peakBitRate <= 3000000")),
            ]
        }
        let task = ensureSession().makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = String(entry.id)
        tasks[entry.id] = task
        task.resume()
    }

    func cancel(fileID: Int64) async {
        tasks[fileID]?.cancel()
        tasks[fileID] = nil
        await remove(fileID: fileID)
    }

    /// Deletes the offline copy (the put.io file is untouched).
    func remove(fileID: Int64) async {
        if let url = localURL(fileID: fileID) { try? FileManager.default.removeItem(at: url) }
        await app.downloads.remove(fileID: fileID)
    }

    /// A playable library entry for a download, even when put.io isn't reachable (offline) or the file left put.io.
    func entry(for record: DownloadRecord) -> LibraryEntry {
        if let known = app.library.entries.first(where: { $0.id == record.fileID }) { return known }
        let match = record.tmdbID.map {
            LibraryMatch(tmdbID: $0, mediaType: record.kind ?? .movie, season: record.season, episode: record.episode,
                         confidence: 1, title: record.title, posterPath: record.posterPath)
        }
        return LibraryEntry(file: PutioFile(id: record.fileID, name: record.title, fileType: "VIDEO"), match: match, folderName: nil)
    }

    /// Space the offline copy takes on this device.
    func size(fileID: Int64) -> Int64? {
        guard let url = localURL(fileID: fileID),
              let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func localURL(fileID: Int64) -> URL? {
        guard case let .done(stored)? = app.downloads.record(fileID: fileID)?.state else { return nil }
        let path = DownloadPaths.resolve(stored: stored, home: NSHomeDirectory())
        for candidate in [path, "/private" + path] where FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    // MARK: AVAssetDownloadDelegate (delivered on the main queue)

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                                totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = assetDownloadTask.taskDescription.flatMap(Int64.init) else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let loaded = loadedTimeRanges.map { $0.timeRangeValue.duration.seconds }.reduce(0, +)
        let progress = expected > 0 ? min(1, loaded / expected) : 0
        MainActor.assumeIsolated {
            _ = Task { await self.app.downloads.progress(fileID: id, progress) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        guard let id = assetDownloadTask.taskDescription.flatMap(Int64.init) else { return }
        let stored = DownloadPaths.stored(location: location.path, home: NSHomeDirectory())
        MainActor.assumeIsolated { self.locations[id] = stored }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = assetDownloadTask.taskDescription.flatMap(Int64.init) else { return }
        let stored = DownloadPaths.stored(location: location.path, home: NSHomeDirectory())
        MainActor.assumeIsolated {
            self.locations[id] = stored
            _ = Task { await self.app.downloads.update(fileID: id) { $0.state = .done(relativePath: stored) } }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = task.taskDescription.flatMap(Int64.init) else { return }
        let succeeded = error == nil
        let failure = error.flatMap { ($0 as NSError).code == NSURLErrorCancelled ? nil : $0.localizedDescription }
        MainActor.assumeIsolated {
            self.tasks[id] = nil
            let location = self.locations.removeValue(forKey: id)
            if succeeded, let location {
                // Make sure it's marked done even if didFinishDownloadingTo never came.
                let isDone = if case .done? = self.app.downloads.record(fileID: id)?.state { true } else { false }
                if !isDone { _ = Task { await self.app.downloads.update(fileID: id) { $0.state = .done(relativePath: location) } } }
            }
            guard let failure else { return }
            _ = Task { await self.app.downloads.update(fileID: id) { $0.state = .failed(message: failure) } }
        }
    }
}
