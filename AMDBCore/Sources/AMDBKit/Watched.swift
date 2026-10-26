import Foundation

/// When a video counts as watched: it's then out of Continue Watching (a show's next episode takes its place), put.io's
/// position is reset, and the user's other devices are told.
public enum Watched {
    /// The position from which a video is watched: 95% of it, or where the credits start, whichever comes first
    /// (the credits only come first in videos under about 7 minutes).
    public static func threshold(duration: Double) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        return min(duration * 0.95, duration - NextUp.creditsLength(duration: duration))
    }

    public static func isReached(position: Double, duration: Double) -> Bool {
        guard let threshold = threshold(duration: duration) else { return false }
        return position >= threshold
    }

    /// A play shorter than this (opened by mistake, a peek) doesn't un-mark a watched video: it would then be neither
    /// watched nor resumable, and drop out of Continue Watching altogether.
    public static let rewatchSeconds = 30
}
