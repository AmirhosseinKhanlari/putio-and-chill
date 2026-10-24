import Foundation

/// The subtitle rendition added to a stream for AirPlay: the receiver loads `uri` itself, so it must be absolute and
/// reachable from the TV.
public struct HLSSubtitleRendition: Sendable, Equatable {
    public let uri: String
    /// BCP 47 / ISO 639 code ("en", "eng"); empty when unknown.
    public let language: String
    public let name: String

    public init(uri: String, language: String, name: String) {
        self.uri = uri; self.language = language; self.name = name
    }
}

/// What the app needs to know about one media playlist (one variant of the video).
public struct HLSMediaPlaylistInfo: Sendable, Equatable {
    public let firstSegment: URL?
    /// The fMP4 init segment (`EXT-X-MAP`), when the segments aren't MPEG-TS.
    public let initSegment: URL?
    /// Sum of the segment durations.
    public let duration: Double
}

/// Reads and rewrites put.io's HLS playlists for AirPlay, where the TV fetches every URL itself.
public enum HLSPlaylist {
    /// Group id of the rendition the app adds.
    public static let subtitleGroup = "chill-subs"

    /// A master playlist lists variants; a media playlist lists segments.
    public static func isMaster(_ text: String) -> Bool { text.contains("#EXT-X-STREAM-INF") }

    /// `playlist` (put.io's, fetched from `playlistURL`) as a master playlist whose URLs are all absolute, with
    /// `rendition` as its only subtitles, on by default. A media playlist gets a one-variant master around it.
    /// Any subtitle renditions already there are dropped so the TV can't pick another one by default.
    public static func addingSubtitles(to playlist: String, playlistURL: URL, rendition: HLSSubtitleRendition) -> String {
        var media = ["TYPE=SUBTITLES", "GROUP-ID=\"\(subtitleGroup)\""]
        if !rendition.language.isEmpty { media.append("LANGUAGE=\"\(quoted(rendition.language))\"") }
        media += ["NAME=\"\(quoted(rendition.name))\"", "DEFAULT=YES", "AUTOSELECT=YES", "FORCED=NO", "URI=\"\(quoted(rendition.uri))\""]
        let mediaTag = "#EXT-X-MEDIA:" + media.joined(separator: ",")

        guard isMaster(playlist) else {
            return ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-INDEPENDENT-SEGMENTS", mediaTag,
                    // BANDWIDTH is required; the real rate isn't known without reading the segments, so a typical HD one.
                    "#EXT-X-STREAM-INF:BANDWIDTH=6000000,SUBTITLES=\"\(subtitleGroup)\"",
                    playlistURL.absoluteString, ""].joined(separator: "\n")
        }

        var output: [String] = []
        var addedMedia = false
        for rawLine in lines(of: playlist) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA:"), HLSAttributes(line.dropFirst("#EXT-X-MEDIA:".count))["TYPE"] == "SUBTITLES" { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                if !addedMedia {
                    output.append(mediaTag)
                    addedMedia = true
                }
                var attributes = HLSAttributes(line.dropFirst("#EXT-X-STREAM-INF:".count))
                attributes.set("SUBTITLES", quoted: subtitleGroup)
                output.append("#EXT-X-STREAM-INF:" + attributes.text)
                continue
            }
            output.append(absolutized(line, base: playlistURL))
        }
        return output.joined(separator: "\n") + "\n"
    }

    /// The first variant's media playlist (the TV may pick another; they share timestamps).
    public static func firstVariant(in master: String, playlistURL: URL) -> URL? {
        var afterStreamInf = false
        for rawLine in lines(of: master) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") { afterStreamInf = true; continue }
            if afterStreamInf, !line.isEmpty, !line.hasPrefix("#") { return URL(string: line, relativeTo: playlistURL)?.absoluteURL }
        }
        return nil
    }

    public static func mediaInfo(_ playlist: String, playlistURL: URL) -> HLSMediaPlaylistInfo {
        var first: URL?, initSegment: URL?, duration = 0.0
        for rawLine in lines(of: playlist) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", omittingEmptySubsequences: false).first ?? ""
                duration += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-MAP:"), initSegment == nil,
                      let uri = HLSAttributes(line.dropFirst("#EXT-X-MAP:".count))["URI"] {
                initSegment = URL(string: uri, relativeTo: playlistURL)?.absoluteURL
            } else if first == nil, !line.isEmpty, !line.hasPrefix("#") {
                first = URL(string: line, relativeTo: playlistURL)?.absoluteURL
            }
        }
        return HLSMediaPlaylistInfo(firstSegment: first, initSegment: initSegment, duration: duration)
    }

    /// A one-segment subtitle playlist: the TV loads the whole file once, so it never needs this device mid-film.
    public static func subtitlePlaylist(duration: Double, segmentURI: String) -> String {
        let length = max(1, duration)
        return ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(Int(length.rounded(.up)))", "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXT-X-PLAYLIST-TYPE:VOD", String(format: "#EXTINF:%.3f,", length), segmentURI, "#EXT-X-ENDLIST", ""]
            .joined(separator: "\n")
    }

    // MARK: Plumbing

    private static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
    }

    /// A URI line, or a tag's URI="…" attribute, made absolute against the playlist's own URL (as a player would).
    private static func absolutized(_ line: String, base: URL) -> String {
        if !line.hasPrefix("#") { return URL(string: line, relativeTo: base)?.absoluteString ?? line }
        guard let colon = line.firstIndex(of: ":"), line.contains("URI=\"") else { return line }
        var attributes = HLSAttributes(line[line.index(after: colon)...])
        guard let uri = attributes["URI"], let absolute = URL(string: uri, relativeTo: base)?.absoluteString else { return line }
        attributes.set("URI", quoted: absolute)
        return String(line[...colon]) + attributes.text
    }

    private static func quoted(_ value: String) -> String { value.replacingOccurrences(of: "\"", with: "'") }
}
