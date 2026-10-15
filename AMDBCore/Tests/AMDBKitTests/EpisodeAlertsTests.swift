import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct EpisodeAlertsTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    let show = CatalogItem(tmdbID: 1396, mediaType: .tv, title: "Marshals")

    @Test func alertOnReleaseDayAtTheChosenHour() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 20))!
        let episodes = [UpcomingEpisode(show: show, season: 2, episode: 3, name: "Falling Sky", airDate: "2026-10-18", stillPath: nil),
                        // Today, but 9:00 has passed: no alert.
                        UpcomingEpisode(show: show, season: 2, episode: 2, name: "Old", airDate: "2026-10-14", stillPath: nil)]
        let alerts = EpisodeAlerts.alerts(for: episodes, hour: 9, now: now, calendar: calendar)
        #expect(alerts.count == 1)
        let alert = try #require(alerts.first)
        #expect(alert.title == "New episode of Marshals")
        #expect(alert.body == "S2 E3 · Falling Sky is out today.")
        #expect(calendar.dateComponents([.year, .month, .day, .hour], from: alert.date)
            == DateComponents(year: 2026, month: 10, day: 18, hour: 9))
        #expect(alert.id == "episode-1396-2-3")
    }

    @Test func followingIsSaved() async {
        let store = LocalStore(fileURL: nil)
        let alerts = EpisodeAlerts(store: store)
        await alerts.setFollowing(show, true)
        #expect(alerts.isFollowing(1396))
        let again = EpisodeAlerts(store: store)
        await again.load()
        #expect(again.followed.map(\.tmdbID) == [1396])
        await again.setFollowing(show, false)
        #expect(!again.isFollowing(1396))
    }
}
