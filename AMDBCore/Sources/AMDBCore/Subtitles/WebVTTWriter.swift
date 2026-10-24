import Foundation

/// Writes the app's subtitles (SRT, VTT, any source) as one WebVTT file for an HLS subtitle rendition, which is what
/// an AirPlay receiver can draw.
public enum WebVTTWriter {
    /// - Parameters:
    ///   - offset: the user's timing shift in seconds (positive shows subtitles later), baked into the cue times.
    ///   - mpegTimestamp: the stream's 90 kHz timestamp at playback time 0. HLS ties WebVTT times to the video's
    ///     timestamps through `X-TIMESTAMP-MAP`; put.io's video doesn't start at timestamp 0, so without it every cue
    ///     would be early by that much.
    public static func make(_ track: SubtitleTrack, offset: Double, mpegTimestamp: UInt64) -> String {
        var out = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:\(mpegTimestamp),LOCAL:00:00:00.000\n"
        var number = 0
        for cue in track.cues {
            let start = max(0, cue.start + offset)
            let end = cue.end + offset
            guard end > start else { continue }
            number += 1
            out += "\n\(number)\n\(time(start)) --> \(time(end))\n\(escape(cue.text))\n"
        }
        return out
    }

    /// "01:02:03.456". WebVTT needs the dot and, past an hour, the hours.
    static func time(_ seconds: Double) -> String {
        let millis = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", millis / 3_600_000, millis / 60000 % 60, millis / 1000 % 60, millis % 1000)
    }

    /// Cue text can't hold a raw "&", "<" or "-->" (escaping ">" covers that), or an empty line (it ends the cue).
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
