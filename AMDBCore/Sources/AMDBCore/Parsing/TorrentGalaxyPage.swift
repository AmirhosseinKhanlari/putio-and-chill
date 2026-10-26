import Foundation

/// Reads torrentgalaxy.info's HTML. A search page lists name, category, size and seeders per row, with a link to the
/// torrent's detail page but no info-hash; the hash is on the detail page. Tolerant on purpose: whitespace, attribute
/// order and extra markup can change without breaking it.
enum TorrentGalaxyPage {
    struct Row: Sendable, Equatable {
        var name: String
        /// "/post-detail/8a732c/dune-part-two-2024-1080p-bluray/"
        var detailPath: String
        var category: String?
        var sizeBytes: Int64?
        var seeders: Int?
        var leechers: Int?
        /// Only when the row carries its own magnet link (the home page and "similar torrents" lists do).
        var infoHash: String?
    }

    /// Categories that are never a movie or an episode.
    static let skippedCategories: Set<String> = ["XXX", "Music", "Books", "Apps", "Games"]

    static func rows(in html: String) -> [Row] {
        html.components(separatedBy: #"<div class="tgxtablerow"#).dropFirst().compactMap(row)
    }

    static func row(_ html: String) -> Row? {
        // The name is the first detail link with text; the download icons link there too, without text.
        let links = captures(#"<a\b[^>]*\bhref="(/post-detail/[^"]+)"[^>]*>(.*?)</a>"#, in: html)
        guard let link = links.first(where: { !plainText($0[2]).isEmpty }) else { return nil }
        var row = Row(name: plainText(link[2]), detailPath: link[1])
        row.category = captures(#"/get-posts/category:([A-Za-z0-9 ]+)"#, in: html).first?[1]
        // Size and health come after the name, so a size inside the name can't be taken for the torrent's.
        let rest = html.range(of: link[0]).map { String(html[$0.upperBound...]) } ?? html
        if let size = captures(#">(?:\s|&nbsp;)*([\d.,]+)(?:\s|&nbsp;)*([KMGT]i?B|B)(?:\s|&nbsp;)*<"#, in: rest).first {
            row.sizeBytes = bytes(size[1], unit: size[2])
        }
        if let health = captures(#"Seeders/Leechers"[^>]*>.*?<b>\s*([\d,]+)\s*</b>.*?<b>\s*([\d,]+)\s*</b>"#, in: rest).first {
            row.seeders = Int(health[1].replacingOccurrences(of: ",", with: ""))
            row.leechers = Int(health[2].replacingOccurrences(of: ",", with: ""))
        }
        row.infoHash = captures(#"magnet:\?xt=urn:btih:([A-Za-z0-9]{32,40})"#, in: html).first.flatMap { Magnet.normalize($0[1]) }
        return row
    }

    /// The torrent's own hash on its detail page: the "Info Hash" field, else the main Magnet Download button.
    /// Never the first magnet on the page, since "similar torrents" lists carry theirs too.
    static func infoHash(inDetail html: String) -> String? {
        if let field = captures(#"Info Hash:.{0,400}?\b([0-9A-Fa-f]{40})\b"#, in: html).first {
            return Magnet.normalize(field[1])
        }
        let button = captures(#"<a\b[^>]*\bclass="[^"]*\bdl-magnet\b[^"]*"[^>]*\bhref="(magnet:[^"]+)""#, in: html).first
        return button.flatMap { Magnet.infoHash(from: decodeEntities($0[1])) }
    }

    /// The detail page's "File List" table: one row per file, name then size ("3.1 GB", "584 bytes"). Rows whose
    /// second cell isn't a size (the page's tracker table uses the same classes) are skipped.
    static func files(inDetail html: String) -> [TorrentFile] {
        let cells = #"<td\b[^>]*\bclass="[^"]*\btable_col1\b[^"]*"[^>]*>(.*?)</td>\s*<td\b[^>]*\bclass="[^"]*\btable_col2\b[^"]*"[^>]*>(.*?)</td>"#
        return captures(cells, in: html).compactMap { row -> TorrentFile? in
            let name = plainText(row[1])
            guard !name.isEmpty,
                  let size = captures(#"^\s*([\d.,]+)\s*([KMGT]i?B|bytes?|B)\s*$"#, in: plainText(row[2])).first else { return nil }
            return TorrentFile(name: name, sizeBytes: bytes(size[1], unit: size[2]))
        }
    }

    /// "3.1 GB" → bytes. The site counts in 1024s, as torrent sites do.
    static func bytes(_ number: String, unit: String) -> Int64? {
        guard let value = Double(number.replacingOccurrences(of: ",", with: "")) else { return nil }
        let power: Double = switch unit.uppercased().first {
        case "K": 1
        case "M": 2
        case "G": 3
        case "T": 4
        default: 0
        }
        return Int64(value * pow(1024, power))
    }

    /// The words to search with. The site splits its search path on ":", and finds "Grey's" as "Greys".
    static func keywords(_ text: String) -> String {
        text.replacingOccurrences(of: #"['’]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Helpers

    /// Every match's groups (index 0 is the whole match); `.` crosses lines.
    static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    /// Tags removed, entities decoded, whitespace collapsed.
    static func plainText(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, char) in [("&quot;", "\""), ("&#39;", "'"), ("&#039;", "'"), ("&apos;", "'"), ("&lt;", "<"),
                               ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        for match in captures(#"&#(x?)([0-9A-Fa-f]+);"#, in: out) {
            let value = UInt32(match[2], radix: match[1].isEmpty ? 10 : 16).flatMap(Unicode.Scalar.init)
            if let value { out = out.replacingOccurrences(of: match[0], with: String(Character(value))) }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
