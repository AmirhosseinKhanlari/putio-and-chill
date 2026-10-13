import Foundation

public struct SubtitleCue: Sendable, Hashable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// A parsed subtitle file with fast lookup by playback time.
public struct SubtitleTrack: Sendable, Equatable {
    public let cues: [SubtitleCue]

    public init(cues: [SubtitleCue]) { self.cues = cues.sorted { $0.start < $1.start } }

    /// Text on screen at `time` (seconds); overlapping cues are joined.
    public func text(at time: Double) -> String? {
        // Last cue starting at or before `time`, then walk back over any still showing.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var lines: [String] = []
        var index = low - 1
        while index >= 0, low - index <= 8 {
            let cue = cues[index]
            if cue.start <= time, time < cue.end { lines.insert(cue.text, at: 0) }
            index -= 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Reads SRT and WebVTT into cues, dropping styling tags (<i>, <font …>, {\an8}).
public enum SubtitleParser {
    public static func parse(_ raw: String) -> SubtitleTrack {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = time(parts[0]), let end = time(parts[1]), end > start else { continue }
            let text = lines[(timingIndex + 1)...].map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
            if !text.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        return SubtitleTrack(cues: cues)
    }

    /// "01:02:03,456", "01:02:03.456" or "02:03.456" (VTT may drop hours and add cue settings after the time).
    static func time(_ raw: String) -> Double? {
        let token = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let fields = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var seconds = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private static let tags = try! NSRegularExpression(pattern: #"<[^>]+>|\{\\[^}]*\}"#)

    static func clean(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        return tags.stringByReplacingMatches(in: line, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
    }
}
