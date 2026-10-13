import AMDBCore
import Testing
@testable import AMDBKit

@MainActor @Suite struct PlaybackSessionTests {
    @Test func savesAtMostEveryTenSeconds() async {
        let putio = FakePutio()
        let session = PlaybackSession(fileID: 5, resumeFrom: 0, putio: putio, library: nil)
        for second in 0...25 { await session.tick(seconds: Double(second), duration: 1000) }
        #expect(putio.startFromSets.map(\.seconds) == [10, 20])
    }

    @Test func finishingNearTheEndResetsProgress() async {
        let putio = FakePutio()
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        let session = PlaybackSession(fileID: 5, resumeFrom: 400, putio: putio, library: library)
        await session.finish(seconds: 960, duration: 1000)
        #expect(putio.startFromSets.map(\.seconds) == [0])
    }

    @Test func finishingMidwaySavesPosition() async {
        let putio = FakePutio()
        let session = PlaybackSession(fileID: 5, resumeFrom: 0, putio: putio, library: nil)
        await session.finish(seconds: 512.7, duration: 1000)
        #expect(putio.startFromSets.map(\.seconds) == [512])
    }

    @Test func resumeOfferThresholdAndStreamURL() {
        let putio = FakePutio()
        #expect(PlaybackSession(fileID: 1, resumeFrom: 31, putio: putio, library: nil).shouldOfferResume)
        #expect(!PlaybackSession(fileID: 1, resumeFrom: 30, putio: putio, library: nil).shouldOfferResume)
        #expect(PlaybackSession(fileID: 1, resumeFrom: 0, putio: putio, library: nil).streamURL.absoluteString == "https://hls.test/1.m3u8")
    }
}
