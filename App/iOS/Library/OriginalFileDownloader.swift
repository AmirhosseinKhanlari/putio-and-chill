import AMDBCore
import AMDBKit
import Foundation

/// Offline copies of the ORIGINAL file, for videos Apple's player can't play: they play in the built-in player, so
/// put.io doesn't have to convert them first. A background download (it carries on while the app is closed) with
/// progress, and when it stops it resumes from where it got to.
@MainActor
final class OriginalFileDownloader: NSObject, URLSessionDownloadDelegate {
    private let app: AppModel
    private let identifier: String
    private var session: URLSession?
    private var tasks: [Int64: URLSessionDownloadTask] = [:]
    /// Highest progress reported per download, so the bar never moves backwards.
    private var reported: [Int64: Double] = [:]

    init(app: AppModel, identifier: String) {
        self.app = app
        self.identifier = identifier
        super.init()
    }

    /// Where finished originals (and the resume data of stopped ones) are kept.
    nonisolated static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Originals", isDirectory: true)
    }

    func isRunning(fileID: Int64) -> Bool { tasks[fileID] != nil }

    private func ensureSession() -> URLSession {
        if let session { return session }
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        let made = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        session = made
        return made
    }

    /// Re-attaches to downloads that continued while the app was closed.
    func restore() async {
        let running = await ensureSession().allTasks
        for case let task as URLSessionDownloadTask in running {
            if let id = Self.fileID(of: task) { tasks[id] = task }
        }
    }

    /// Downloads `url` (put.io's link to the original file) for `fileID`. Picks up a stopped download where it was.
    func start(fileID: Int64, url: URL, fileName: String, expectedBytes: Int64?) {
        guard tasks[fileID] == nil else { return }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let resumeURL = Self.resumeDataURL(fileID)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeURL) {
            task = ensureSession().downloadTask(withResumeData: data)
            // Used once: if it no longer works (the link expired), the next try starts over with a fresh link.
            try? FileManager.default.removeItem(at: resumeURL)
        } else {
            task = ensureSession().downloadTask(with: url)
        }
        task.taskDescription = "\(fileID)|\(ext.isEmpty ? "video" : ext)"
        if let expectedBytes, expectedBytes > 0 { task.countOfBytesClientExpectsToReceive = expectedBytes }
        tasks[fileID] = task
        task.resume()
    }

    func cancel(fileID: Int64) {
        tasks[fileID]?.cancel()
        tasks[fileID] = nil
        reported[fileID] = nil
        try? FileManager.default.removeItem(at: Self.resumeDataURL(fileID))
    }

    nonisolated static func resumeDataURL(_ fileID: Int64) -> URL { folder.appendingPathComponent("\(fileID).resume") }

    nonisolated static func fileID(of task: URLSessionTask) -> Int64? {
        task.taskDescription?.split(separator: "|").first.flatMap { Int64($0) }
    }

    // MARK: URLSessionDownloadDelegate (delivered on the main queue)

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = Self.fileID(of: downloadTask) else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : downloadTask.countOfBytesClientExpectsToReceive
        guard expected > 0 else { return }
        let value = min(1, Double(totalBytesWritten) / Double(expected))
        MainActor.assumeIsolated { self.report(fileID: id, value) }
    }

    /// The file has to be moved before this returns (the system deletes it right after).
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = Self.fileID(of: downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
        let ext = downloadTask.taskDescription?.split(separator: "|").dropFirst().first.map(String.init) ?? "video"
        var destination = Self.folder.appendingPathComponent("\(id).\(ext)")
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: location, to: destination)
            // A copy of what's in put.io: not worth backing up.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? destination.setResourceValues(values)
        } catch {
            return
        }
        let stored = DownloadPaths.stored(location: destination.path, home: NSHomeDirectory())
        MainActor.assumeIsolated {
            _ = Task { await self.app.downloads.update(fileID: id) { $0.state = .done(relativePath: stored) } }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = Self.fileID(of: task) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 200
        let nsError = error.map { $0 as NSError }
        let cancelledByUser = nsError?.code == NSURLErrorCancelled && nsError?.userInfo[NSURLSessionDownloadTaskResumeData] == nil
        // Stopped part-way (network gone, app closed by the system): keep what came, to carry on from there.
        if let data = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try? data.write(to: Self.resumeDataURL(id))
        }
        let failure: String? = if cancelledByUser {
            nil
        } else if error != nil {
            "Stopped. Tap download to carry on."
        } else if !(200..<300).contains(status) {
            "put.io's download link didn't work. Tap download to try again."
        } else {
            nil
        }
        MainActor.assumeIsolated {
            self.tasks[id] = nil
            self.reported[id] = nil
            guard let failure else { return }
            _ = Task { await self.app.downloads.update(fileID: id) { $0.state = .failed(message: failure) } }
        }
    }

    private func report(fileID: Int64, _ value: Double) {
        guard value.isFinite, value > (reported[fileID] ?? 0) + 0.002 || value >= 1 else { return }
        reported[fileID] = min(value, 1)
        Task { await app.downloads.progress(fileID: fileID, min(value, 1)) }
    }
}
