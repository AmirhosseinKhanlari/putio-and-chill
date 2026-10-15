import Foundation

public enum ReleaseNameParser {
    public static func parse(_ raw: String) -> ParsedRelease {
        var r = ParsedRelease()
        var name = raw.replacingOccurrences(of: "_", with: ".")
        if let m = name.firstMatch(of: /^\s*\[[^\]]*\]\s*/.simple) { name.removeSubrange(m.range) }
        if let m = name.firstMatch(of: /(?i)\.(mkv|mp4|avi|m4v|torrent)$/.simple) { name.removeSubrange(m.range) }

        var cut = name.endIndex
        func mark(_ index: String.Index) { if index < cut { cut = index } }

        // Season / episode
        if let m = name.firstMatch(of: /(?i)\bS(\d{1,2})[ .]?E(\d{1,3})(?:-?E(\d{1,3}))?\b/.simple) {
            r.season = Int(m.1); r.episode = Int(m.2); r.episodeEnd = m.3.flatMap { Int($0) }
            mark(m.range.lowerBound)
        } else if let m = name.firstMatch(of: /(?i)\b(\d{1,2})x(\d{2,3})\b/.simple) {
            r.season = Int(m.1); r.episode = Int(m.2)
            mark(m.range.lowerBound)
        } else if let m = name.firstMatch(of: /(?i)\b(?:S|Season[ .]?)(\d{1,2})\b/.simple) {
            r.season = Int(m.1)
            mark(m.range.lowerBound)
        }

        // Resolution
        if let m = name.firstMatch(of: /(?i)\b(4320|2160|1080|720|480)[pi]\b/.simple) {
            r.resolution = Resolution(rawValue: Int(m.1) ?? 0) ?? .unknown
            mark(m.range.lowerBound)
        } else if let m = name.firstMatch(of: /(?i)\b(?:8K|FUHD)\b/.simple) {
            r.resolution = .uhd4320
            mark(m.range.lowerBound)
        } else if let m = name.firstMatch(of: /(?i)\b(?:4K|UHD)\b/.simple) {
            r.resolution = .uhd2160
            mark(m.range.lowerBound)
        }

        // Source, codec, audio: first matching rule wins
        let sourceRules: [(Regex<Substring>, String)] = [
            (/(?i)\bREMUX\b/.simple, "REMUX"), (/(?i)\bWEB[ .-]?DL\b/.simple, "WEB-DL"), (/(?i)\bWEB[ .-]?Rip\b/.simple, "WEBRip"),
            (/(?i)\b(?:Blu[ .-]?Ray|BDRip|BRRip)\b/.simple, "BluRay"), (/(?i)\bHDTV\b/.simple, "HDTV"),
            (/(?i)\bDVD[ .-]?Rip\b/.simple, "DVDRip"), (/(?i)\bHDRip\b/.simple, "HDRip"),
            (/(?i)\b(?:CAM|HDCAM|TS|TELESYNC|HDTS)\b/.simple, "CAM"), (/(?i)\bWEB\b/.simple, "WEB"),
        ]
        let codecRules: [(Regex<Substring>, String)] = [
            (/(?i)\b(?:x265|HEVC|H[ .]?265)\b/.simple, "H.265"), (/(?i)\b(?:x264|AVC|H[ .]?264)\b/.simple, "H.264"),
            (/(?i)\bAV1\b/.simple, "AV1"), (/(?i)\bXviD\b/.simple, "XviD"),
        ]
        let audioRules: [(Regex<Substring>, String)] = [
            (/(?i)\bAtmos\b/.simple, "Atmos"), (/(?i)\bTrueHD\b/.simple, "TrueHD"), (/(?i)\bDTS[ .-]?HD\b/.simple, "DTS-HD"),
            (/(?i)\bDTS\b/.simple, "DTS"), (/(?i)\b(?:DDP|DD\+|EAC3)/.simple, "DD+"),
            (/(?i)\b(?:DD|AC3)(?:[ .]?\d[ .]\d)?\b/.simple, "DD"), (/(?i)\bAAC/.simple, "AAC"),
        ]
        func firstRule(_ rules: [(Regex<Substring>, String)]) -> String? {
            for (regex, label) in rules {
                if let m = name.firstMatch(of: regex) { mark(m.range.lowerBound); return label }
            }
            return nil
        }
        r.source = firstRule(sourceRules)
        r.codec = firstRule(codecRules)
        r.audio = firstRule(audioRules)

        // HDR flags
        if let m = name.firstMatch(of: /(?i)\bHDR10(?:\+|Plus)/.simple) {
            r.hdr.append("HDR10+"); mark(m.range.lowerBound)
        } else if let m = name.firstMatch(of: /(?i)\bHDR(?:10)?\b/.simple) {
            r.hdr.append("HDR"); mark(m.range.lowerBound)
        }
        if let m = name.firstMatch(of: /(?i)\b(?:DV|DoVi|Dolby[ .]?Vision)\b/.simple) {
            r.hdr.append("DV"); mark(m.range.lowerBound)
        }

        // Flags
        if let m = name.firstMatch(of: /(?i)\bPROPER\b/.simple) { r.isProper = true; mark(m.range.lowerBound) }
        if let m = name.firstMatch(of: /(?i)\bREPACK\b/.simple) { r.isRepack = true; mark(m.range.lowerBound) }
        if let m = name.firstMatch(of: /(?i)\bEXTENDED\b/.simple) { r.isExtended = true; mark(m.range.lowerBound) }
        if let m = name.firstMatch(of: /(?i)\bCOMPLETE\b/.simple) { r.isComplete = true; mark(m.range.lowerBound) }

        // Release group: trailing "-GROUP", optionally followed by "[site]"
        if let m = name.firstMatch(of: /-([A-Za-z0-9]+)(?:\[[^\]]*\])?\s*$/.simple) {
            let group = String(m.1)
            if !["dl", "rip"].contains(group.lowercased()) { r.group = group }
        }

        // Year: last 19xx/20xx before the cut that isn't at the very start
        let years = name.matches(of: /\b(19\d{2}|20\d{2})\b/.simple)
            .filter { $0.range.lowerBound > name.startIndex && $0.range.lowerBound < cut }
        if let last = years.last {
            r.year = Int(last.1)
            mark(last.range.lowerBound)
        }

        // Title
        var title = String(name[name.startIndex..<cut])
        if !title.contains(" ") { title = title.replacingOccurrences(of: ".", with: " ") }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .-_([{").union(.whitespaces))
        r.title = title.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return r
    }
}

extension Regex {
    /// ASCII word boundaries. Unicode rules treat "Dune.Part.Two" as one word; scene names use "." as a separator.
    fileprivate var simple: Regex<Output> { wordBoundaryKind(.simple) }
}
