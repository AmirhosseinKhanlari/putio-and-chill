import Foundation

/// Finds where a stream's timestamps start (90 kHz units) from the first bytes of its first segment, so subtitles
/// added for AirPlay line up with the picture (see WebVTTWriter's X-TIMESTAMP-MAP).
public enum MediaTimestampProbe {
    /// The earliest audio or video presentation time in an MPEG-TS segment (or its first bytes).
    public static func mpegTS(_ data: Data) -> UInt64? {
        let bytes = [UInt8](data)
        let size = 188
        guard let sync = (0..<min(bytes.count, size)).first(where: { start in
            bytes[start] == 0x47 && (start + size >= bytes.count || bytes[start + size] == 0x47)
        }) else { return nil }
        var earliest: UInt64?
        var offset = sync
        while offset + size <= bytes.count {
            defer { offset += size }
            let packet = bytes[offset..<(offset + size)]
            let base = packet.startIndex
            guard packet[base] == 0x47, packet[base + 1] & 0x40 != 0 else { continue }
            let adaptation = (packet[base + 3] >> 4) & 0x3
            var payload = base + 4
            if adaptation == 2 { continue }
            if adaptation == 3 { payload += 1 + Int(packet[base + 4]) }
            guard payload + 14 <= base + size, packet[payload] == 0, packet[payload + 1] == 0, packet[payload + 2] == 1 else { continue }
            let stream = packet[payload + 3]
            // Audio, video, or private stream 1 (AC-3).
            guard (0xC0...0xEF).contains(stream) || stream == 0xBD, packet[payload + 7] & 0x80 != 0 else { continue }
            let p = payload + 9
            let pts = (UInt64(packet[p] >> 1) & 0x7) << 30 | UInt64(packet[p + 1]) << 22 | UInt64(packet[p + 2] >> 1) << 15
                | UInt64(packet[p + 3]) << 7 | UInt64(packet[p + 4] >> 1)
            earliest = min(earliest ?? pts, pts)
        }
        return earliest
    }

    /// fMP4 segments: each track's timescale from the init segment, then the earliest `tfdt` decode time in the
    /// segment, in 90 kHz units.
    public static func fragmentedMP4(initSegment: Data, segment: Data) -> UInt64? {
        let header = [UInt8](initSegment)
        var timescales: [UInt32: UInt32] = [:]
        for trak in boxes(header, in: 0..<header.count, path: ["moov", "trak"]) {
            guard let tkhd = boxes(header, in: trak, path: ["tkhd"]).first,
                  let mdhd = boxes(header, in: trak, path: ["mdia", "mdhd"]).first else { continue }
            let trackID = uint32(header, tkhd.lowerBound + (header[tkhd.lowerBound] == 1 ? 20 : 12))
            let scale = uint32(header, mdhd.lowerBound + (header[mdhd.lowerBound] == 1 ? 20 : 12))
            if let trackID, let scale, scale > 0 { timescales[trackID] = scale }
        }
        let media = [UInt8](segment)
        var earliest: UInt64?
        for traf in boxes(media, in: 0..<media.count, path: ["moof", "traf"]) {
            guard let tfhd = boxes(media, in: traf, path: ["tfhd"]).first, let tfdt = boxes(media, in: traf, path: ["tfdt"]).first,
                  let trackID = uint32(media, tfhd.lowerBound + 4), let scale = timescales[trackID] ?? timescales.values.first else { continue }
            let decode: UInt64?
            if media[tfdt.lowerBound] == 1 {
                decode = uint32(media, tfdt.lowerBound + 4).flatMap { high in
                    uint32(media, tfdt.lowerBound + 8).map { UInt64(high) << 32 | UInt64($0) }
                }
            } else {
                decode = uint32(media, tfdt.lowerBound + 4).map(UInt64.init)
            }
            guard let decode else { continue }
            let ticks = UInt64((Double(decode) * 90000 / Double(scale)).rounded())
            earliest = min(earliest ?? ticks, ticks)
        }
        return earliest
    }

    // MARK: ISO BMFF boxes

    /// The payload ranges of the boxes at `path` (each step one level deeper) within `range`.
    private static func boxes(_ bytes: [UInt8], in range: Range<Int>, path: [String]) -> [Range<Int>] {
        guard let type = path.first else { return [range] }
        var found: [Range<Int>] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound, let size32 = uint32(bytes, offset) {
            var header = 8
            var size = Int(size32)
            if size32 == 1, let high = uint32(bytes, offset + 8), let low = uint32(bytes, offset + 12) {
                size = Int(UInt64(high) << 32 | UInt64(low))
                header = 16
            } else if size32 == 0 {
                size = range.upperBound - offset
            }
            guard size >= header else { break }
            let end = min(offset + size, range.upperBound)
            let name = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if name == type {
                // Full boxes (tkhd, mdhd, tfhd, tfdt) keep their version byte at the start of the range.
                found += boxes(bytes, in: (offset + header)..<end, path: Array(path.dropFirst()))
            }
            offset += size
        }
        return found
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
