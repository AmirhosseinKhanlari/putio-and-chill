import Foundation

enum Format {
    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Time left to watch: "7m left", "1h 5m left", "Almost done".
    static func left(_ seconds: Int) -> String {
        seconds < 60 ? "Almost done" : "\(runtime(seconds / 60) ?? "") left"
    }

    static func runtime(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func bytes(_ count: Int64?) -> String {
        guard let count, count > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Int64?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file) + "/s"
    }

    static func eta(_ seconds: Int64?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds < 60 { return "less than a minute left" }
        if seconds < 3600 { return "about \(seconds / 60) min left" }
        return "about \(seconds / 3600) h left"
    }
}
