import Foundation

/// "Stop playing in 30 minutes" / "at the end of this episode". The sound fades over the last few seconds.
public struct SleepTimer: Sendable, Equatable {
    public enum Option: Sendable, Hashable {
        case minutes(Int)
        case endOfEpisode

        public static let choices: [Option] = [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfEpisode]

        public var title: String {
            switch self {
            case let .minutes(value): "\(value) minutes"
            case .endOfEpisode: "End of episode"
            }
        }
    }

    public static let fadeSeconds: Double = 15

    public let option: Option
    public let startedAt: Date

    public init(_ option: Option, startedAt: Date) {
        self.option = option
        self.startedAt = startedAt
    }

    /// Seconds until playback stops (nil when the video's length isn't known yet).
    public func remaining(now: Date, position: Double, duration: Double) -> Double? {
        switch option {
        case let .minutes(value):
            return max(0, Double(value) * 60 - now.timeIntervalSince(startedAt))
        case .endOfEpisode:
            guard duration.isFinite, duration > 0, position.isFinite else { return nil }
            return max(0, duration - position)
        }
    }

    public func shouldStop(now: Date, position: Double, duration: Double) -> Bool {
        guard let left = remaining(now: now, position: position, duration: duration) else { return false }
        return left <= 0.5
    }

    /// Volume to use now: 1 until the last 15 seconds, then down to 0.
    public func volume(now: Date, position: Double, duration: Double) -> Float {
        guard let left = remaining(now: now, position: position, duration: duration), left < Self.fadeSeconds else { return 1 }
        return Float(max(0, left / Self.fadeSeconds))
    }

    /// "29:41 left" for the menu.
    public func label(now: Date, position: Double, duration: Double) -> String {
        guard let left = remaining(now: now, position: position, duration: duration) else { return option.title }
        let seconds = Int(left.rounded())
        return String(format: "%d:%02d left", seconds / 60, seconds % 60)
    }
}
