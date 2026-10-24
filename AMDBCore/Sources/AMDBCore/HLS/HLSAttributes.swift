import Foundation

/// An HLS attribute list (`BANDWIDTH=1,CODECS="avc1,mp4a",SUBTITLES="s"`), kept in order so a rewritten tag reads like
/// the original. Quoted values may hold commas, so this splits by hand rather than on ",".
struct HLSAttributes: Equatable {
    /// Name and raw value (quotes kept, so it's written back unchanged).
    var pairs: [(name: String, raw: String)]

    init(_ text: Substring) {
        var pairs: [(String, String)] = []
        var name = "", value = "", inName = true, quoted = false
        func flush() {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { pairs.append((trimmed, value.trimmingCharacters(in: .whitespaces))) }
            name = ""; value = ""; inName = true
        }
        for character in text {
            if inName {
                if character == "=" { inName = false } else if character == "," { flush() } else { name.append(character) }
            } else {
                if character == "\"" { quoted.toggle() }
                if character == ",", !quoted { flush() } else { value.append(character) }
            }
        }
        flush()
        self.pairs = pairs
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }

    /// The value without quotes.
    subscript(name: String) -> String? {
        pairs.first { $0.name == name }.map { $0.raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }

    mutating func remove(_ name: String) { pairs.removeAll { $0.name == name } }

    mutating func set(_ name: String, quoted value: String) {
        let raw = "\"\(value.replacingOccurrences(of: "\"", with: "'"))\""
        if let index = pairs.firstIndex(where: { $0.name == name }) { pairs[index].raw = raw } else { pairs.append((name, raw)) }
    }

    var text: String { pairs.map { "\($0.name)=\($0.raw)" }.joined(separator: ",") }
}
