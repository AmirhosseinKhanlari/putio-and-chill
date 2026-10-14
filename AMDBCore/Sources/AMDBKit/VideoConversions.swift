import AMDBCore
import Foundation

/// Videos Apple devices can't play as they are (old codecs, some audio formats): put.io converts them to MP4, after
/// which they stream and download like any other. Only used once a video has failed to play: put.io's "needs
/// converting" also covers videos only web browsers can't play. Tracks each conversion so every screen agrees.
@Observable @MainActor
public final class VideoConversions {
    public enum State: Equatable, Sendable {
        case converting(percent: Int)
        case failed
    }

    /// Conversions under way (or failed) by file id; a file that plays as it is never appears.
    public private(set) var states: [Int64: State] = [:]
    @ObservationIgnored private var putio: (any PutioService)?
    @ObservationIgnored private var watchers: [Int64: Task<Bool, Never>] = [:]
    @ObservationIgnored private let pollInterval: Duration

    public init(pollInterval: Duration = .seconds(5)) { self.pollInterval = pollInterval }

    public func configure(putio: (any PutioService)?) {
        if putio == nil { watchers.values.forEach { $0.cancel() }; watchers = [:]; states = [:] }
        self.putio = putio
    }

    /// Whether put.io has to convert the file before Apple devices can play it (and the MP4 isn't ready yet).
    public func needsConversion(fileID: Int64) async -> Bool {
        guard let putio, let file = try? await putio.fileStatus(id: fileID) else { return false }
        return !file.isStreamable
    }

    /// Makes the file playable: nothing to do when it already is; otherwise starts put.io's conversion (if it isn't
    /// running) and waits for it. Returns false if it fails. Several callers share one conversion.
    @discardableResult
    public func makePlayable(fileID: Int64) async -> Bool {
        if let running = watchers[fileID] { return await running.value }
        guard await needsConversion(fileID: fileID) else {
            states[fileID] = nil
            return true
        }
        let task = Task { await self.convert(fileID: fileID) }
        watchers[fileID] = task
        let ok = await task.value
        watchers[fileID] = nil
        return ok
    }

    private func convert(fileID: Int64) async -> Bool {
        guard let putio else { return false }
        states[fileID] = .converting(percent: 0)
        var status = try? await putio.mp4Status(fileID: fileID)
        if status == nil || status?.status == .notAvailable || status?.status == .error {
            status = try? await putio.convertToMp4(fileID: fileID)
        }
        // Up to about six hours: put.io queues conversions when it's busy.
        for _ in 0..<4320 {
            guard !Task.isCancelled else { return false }
            switch status?.status {
            case .completed?:
                states[fileID] = nil
                return true
            case .error?:
                states[fileID] = .failed
                return false
            default:
                states[fileID] = .converting(percent: status?.percentDone ?? 0)
            }
            try? await Task.sleep(for: pollInterval)
            if let next = try? await putio.mp4Status(fileID: fileID) { status = next }
        }
        states[fileID] = .failed
        return false
    }
}
