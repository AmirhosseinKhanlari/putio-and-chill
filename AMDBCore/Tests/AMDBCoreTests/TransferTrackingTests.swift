import Foundation
import Testing
@testable import AMDBCore

@Suite struct TransferTrackingTests {
    @Test func phaseMapping() {
        #expect(TransferPhase(PutioTransfer(id: 1, status: "IN_QUEUE")) == .queued)
        #expect(TransferPhase(PutioTransfer(id: 1, status: "WAITING")) == .queued)
        #expect(TransferPhase(PutioTransfer(id: 1, status: "DOWNLOADING")) == .downloading)
        #expect(TransferPhase(PutioTransfer(id: 1, status: "COMPLETING")) == .finishing)
        #expect(TransferPhase(PutioTransfer(id: 1, status: "SEEDING", fileId: 9)) == .completed(fileID: 9))
        #expect(TransferPhase(PutioTransfer(id: 1, status: "COMPLETED", fileId: 9)) == .completed(fileID: 9))
        #expect(TransferPhase(PutioTransfer(id: 1, status: "ERROR", errorMessage: "dead")) == .failed(message: "dead"))
        #expect(TransferPhase(PutioTransfer(id: 1, status: "ERROR")) == .failed(message: "put.io reported an error"))
    }

    @Test func stallsAfterThresholdWithNoPeersAndNoProgress() {
        var detector = StallDetector(threshold: 180)
        let t0 = Date(timeIntervalSince1970: 0)
        let stuck = PutioTransfer(id: 1, status: "DOWNLOADING", peersConnected: 0, downloaded: 100)
        let atStart = detector.isStalled(stuck, now: t0)
        #expect(!atStart)
        let after2Min = detector.isStalled(stuck, now: t0.addingTimeInterval(120))
        #expect(!after2Min)
        let after3Min = detector.isStalled(stuck, now: t0.addingTimeInterval(181))
        #expect(after3Min)
    }

    @Test func progressResetsTimer() {
        var detector = StallDetector(threshold: 180)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = detector.isStalled(PutioTransfer(id: 1, status: "DOWNLOADING", peersConnected: 0, downloaded: 100), now: t0)
        _ = detector.isStalled(PutioTransfer(id: 1, status: "DOWNLOADING", peersConnected: 0, downloaded: 200), now: t0.addingTimeInterval(170))
        let afterProgress = detector.isStalled(PutioTransfer(id: 1, status: "DOWNLOADING", peersConnected: 0, downloaded: 200), now: t0.addingTimeInterval(300))
        #expect(!afterProgress)
    }

    @Test func peersPreventStall() {
        var detector = StallDetector(threshold: 180)
        let t0 = Date(timeIntervalSince1970: 0)
        let slow = PutioTransfer(id: 1, status: "DOWNLOADING", peersConnected: 3, downloaded: 100)
        _ = detector.isStalled(slow, now: t0)
        let slowButAlive = detector.isStalled(slow, now: t0.addingTimeInterval(600))
        #expect(!slowButAlive)
    }
}
