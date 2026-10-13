import Foundation

public enum TransferPhase: Sendable, Equatable {
    case queued
    case downloading
    case finishing
    case completed(fileID: Int64?)
    case failed(message: String)

    public init(_ transfer: PutioTransfer) {
        switch (transfer.status ?? "").uppercased() {
        case "COMPLETED", "SEEDING": self = .completed(fileID: transfer.fileId)
        case "ERROR": self = .failed(message: transfer.errorMessage ?? "put.io reported an error")
        case "DOWNLOADING", "PREPARING_DOWNLOAD": self = .downloading
        case "COMPLETING": self = .finishing
        default: self = .queued
        }
    }
}

/// Flags a transfer that is downloading with zero peers and no progress for `threshold` seconds.
public struct StallDetector: Sendable {
    public let threshold: TimeInterval
    private var lastProgress: Int64?
    private var lastProgressAt: Date?

    public init(threshold: TimeInterval = 180) { self.threshold = threshold }

    public mutating func isStalled(_ transfer: PutioTransfer, now: Date) -> Bool {
        guard TransferPhase(transfer) == .downloading else {
            lastProgress = nil
            lastProgressAt = nil
            return false
        }
        let progress = transfer.downloaded ?? Int64(transfer.percentDone ?? 0)
        guard progress == lastProgress, let since = lastProgressAt else {
            lastProgress = progress
            lastProgressAt = now
            return false
        }
        return (transfer.peersConnected ?? 0) == 0 && now.timeIntervalSince(since) >= threshold
    }
}
