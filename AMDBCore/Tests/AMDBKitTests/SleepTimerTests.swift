import Foundation
import Testing
@testable import AMDBKit

@Suite struct SleepTimerTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func minutesCountFromWhenItWasSet() {
        let timer = SleepTimer(.minutes(30), startedAt: start)
        #expect(!timer.shouldStop(now: start.addingTimeInterval(29 * 60), position: 0, duration: 0))
        #expect(timer.shouldStop(now: start.addingTimeInterval(30 * 60), position: 0, duration: 0))
        #expect(timer.label(now: start.addingTimeInterval(19), position: 0, duration: 0) == "29:41 left")
    }

    @Test func endOfEpisodeFollowsThePlayhead() {
        let timer = SleepTimer(.endOfEpisode, startedAt: start)
        #expect(!timer.shouldStop(now: start, position: 3000, duration: 3300))
        #expect(timer.shouldStop(now: start, position: 3299.8, duration: 3300))
        #expect(timer.remaining(now: start, position: 0, duration: .nan) == nil)
    }

    @Test func soundFadesOverTheLastFifteenSeconds() {
        let timer = SleepTimer(.minutes(1), startedAt: start)
        #expect(timer.volume(now: start.addingTimeInterval(30), position: 0, duration: 0) == 1)
        #expect(timer.volume(now: start.addingTimeInterval(52.5), position: 0, duration: 0) == 0.5)
        #expect(timer.volume(now: start.addingTimeInterval(60), position: 0, duration: 0) == 0)
    }
}
