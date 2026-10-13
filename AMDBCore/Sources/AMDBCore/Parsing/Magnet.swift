import Foundation

public enum Magnet {
    public static let defaultTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
    ]

    public static func infoHash(from link: String) -> String? {
        guard link.lowercased().hasPrefix("magnet:"),
              let match = link.firstMatch(of: /(?i)xt=urn:btih:([a-z0-9]+)/) else { return nil }
        return normalize(String(match.1))
    }

    /// Returns a lowercased 40-char hex infohash from hex or base32 input.
    public static func normalize(_ hash: String) -> String? {
        let trimmed = hash.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 40, trimmed.allSatisfy(\.isHexDigit) { return trimmed.lowercased() }
        if trimmed.count == 32 { return base32ToHex(trimmed.uppercased()) }
        return nil
    }

    public static func make(infoHash: String, name: String, trackers: [String] = defaultTrackers) -> String {
        var link = "magnet:?xt=urn:btih:\(infoHash)&dn=\(formEncode(name))"
        for tracker in trackers { link += "&tr=\(formEncode(tracker))" }
        return link
    }

    private static func base32ToHex(_ input: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer = 0
        var bits = 0
        var bytes: [UInt8] = []
        for char in input {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            buffer = ((buffer << 5) | index) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        guard bytes.count == 20 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
