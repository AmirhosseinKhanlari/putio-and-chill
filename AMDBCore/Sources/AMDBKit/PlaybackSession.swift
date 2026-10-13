import AMDBCore
import Foundation

/// Bridges the player to put.io's `start_from`: periodic saves, and a reset once the video is basically over.
@MainActor
public final class PlaybackSession {
    public let fileID: Int64
    public let resumeFrom: Int
    private let putio: any PutioService
    private weak var library: LibraryIndex?
    private let store: LocalStore?
    private let saveEvery: Int
    private var lastSaved: Int

    public init(fileID: Int64, resumeFrom: Int, putio: any PutioService, library: LibraryIndex?,
                store: LocalStore? = nil, saveEvery: Int = 10) {
        self.fileID = fileID
        self.resumeFrom = resumeFrom
        self.putio = putio
        self.library = library
        self.store = store
        self.saveEvery = saveEvery
        self.lastSaved = resumeFrom
    }

    public var shouldOfferResume: Bool { resumeFrom > 30 }
    public var streamURL: URL { putio.hlsURL(fileID: fileID) }

    public func tick(seconds: Double, duration: Double) async {
        let position = Int(seconds)
        guard abs(position - lastSaved) >= saveEvery else { return }
        await save(position, duration: duration)
    }

    public func finish(seconds: Double, duration: Double) async {
        await save(Int(seconds), duration: duration)
    }

    private func save(_ position: Int, duration: Double) async {
        lastSaved = position
        let watchedToEnd = duration > 0 && Double(position) >= duration * 0.95
        let value = watchedToEnd ? 0 : position
        library?.noteProgress(fileID: fileID, seconds: value)
        if watchedToEnd, let store {
            let id = fileID
            await store.update { state in
                if !state.finished.contains(where: { $0.fileID == id }) { state.finished.append(FinishedFile(fileID: id, at: Date())) }
            }
        }
        try? await putio.setStartFrom(fileID: fileID, seconds: value)
    }
}
