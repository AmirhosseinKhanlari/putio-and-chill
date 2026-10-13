import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@Suite struct DeepLinkTests {
    @Test func roundTrips() {
        for link in [DeepLink.play(fileID: 42), .title(tmdbID: 693134, kind: .movie), .title(tmdbID: 95396, kind: .tv), .library] {
            #expect(DeepLink(url: link.url) == link)
        }
        #expect(DeepLink.play(fileID: 42).url.absoluteString == "amdb://play/42")
        #expect(DeepLink.title(tmdbID: 7, kind: .tv).url.absoluteString == "amdb://title/tv/7")
    }

    @Test func rejectsOtherURLs() {
        #expect(DeepLink(url: URL(string: "amdb://oauth/putio#access_token=x")!) == nil)
        #expect(DeepLink(url: URL(string: "https://example.com/play/1")!) == nil)
        #expect(DeepLink(url: URL(string: "amdb://play/notanumber")!) == nil)
    }
}
