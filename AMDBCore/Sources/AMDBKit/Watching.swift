import AMDBCore
import Foundation

/// Chooses the release Smart Get sends.
public enum SmartPicker {
    /// Preferred resolution first, then the nearest lower one, then higher; within a resolution, most seeders.
    /// Dead (0 seeders) and oversized releases are never picked; unknown sizes are allowed.
    public static func pick(_ releases: [Release], rule: SmartGetRule) -> Release? {
        let cap = rule.maxSizeGB.map { Int64($0 * 1_000_000_000) }
        let live = releases.filter { release in
            guard (release.seeders ?? 0) > 0 else { return false }
            guard let cap, let size = release.sizeBytes else { return true }
            return size <= cap
        }
        guard !live.isEmpty else { return nil }
        let preferred = rule.resolution ?? Resolution.uhd2160.rawValue
        func priority(_ release: Release) -> Int {
            let value = release.parsed.resolution.rawValue
            if value == preferred { return 0 }
            if release.parsed.resolution == .unknown { return 10_000 }
            return value < preferred ? 10 + (preferred - value) : 5_000 + (value - preferred)
        }
        return live.min { a, b in
            (priority(a), -(a.seeders ?? 0)) < (priority(b), -(b.seeders ?? 0))
        }
    }
}

/// Matches stream language tags (2- or 3-letter, with or without region) to a preferred ISO 639-1 code.
public enum LanguageMatcher {
    private static let bibliographic = [
        "per": "fa", "ger": "de", "fre": "fr", "chi": "zh", "dut": "nl", "gre": "el", "cze": "cs", "rum": "ro",
        "slo": "sk", "arm": "hy", "geo": "ka", "ice": "is", "mac": "mk", "may": "ms", "bur": "my", "wel": "cy",
        "alb": "sq", "baq": "eu",
    ]

    public static func normalize(_ tag: String) -> String {
        let base = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        if base.count == 3 {
            if let mapped = bibliographic[base] { return mapped }
            if let alpha2 = Locale.LanguageCode(base).identifier(.alpha2) { return alpha2 }
        }
        return base
    }

    public static func bestIndex(available: [String?], preferred: String) -> Int? {
        let wanted = normalize(preferred)
        return available.firstIndex { $0.map(normalize) == wanted }
    }
}

public enum SmartGetResult: Sendable, Equatable {
    case sent(Release)
    case noMatch
    case failed(AppError)
}
