import Testing
@testable import AMDBCore

@Suite struct MagnetTests {
    let hex = "0123456789abcdef0123456789abcdef01234567"

    @Test func extractsHexHashLowercased() {
        #expect(Magnet.infoHash(from: "magnet:?xt=urn:btih:\(hex.uppercased())&dn=X") == hex)
    }

    @Test func convertsBase32Hash() {
        #expect(Magnet.infoHash(from: "magnet:?dn=X&xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH") == hex)
    }

    @Test func nonMagnetHasNoHash() {
        #expect(Magnet.infoHash(from: "https://example.com/file.torrent") == nil)
    }

    @Test func normalizeRejectsGarbage() {
        #expect(Magnet.normalize("xyz") == nil)
        #expect(Magnet.normalize(hex.uppercased()) == hex)
    }

    @Test func buildsMagnet() {
        let link = Magnet.make(infoHash: hex, name: "Dune Part Two", trackers: ["udp://t.test:1337/announce"])
        #expect(link == "magnet:?xt=urn:btih:\(hex)&dn=Dune%20Part%20Two&tr=udp%3A%2F%2Ft.test%3A1337%2Fannounce")
        #expect(Magnet.infoHash(from: link) == hex)
    }
}
