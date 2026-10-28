import Foundation

/// When a video counts as watched: it's then out of Continue Watching (a show's next episode takes its place), put.io's
/// position is reset, and the user's other devices are told.
public enum Watched {
    /// The position from which a video is watched: its last 10%, but at most its last 10 minutes (end credits run
    /// long: a 52-minute episode stopped 3 minutes before the end, when they start, is watched), and never less than
    /// the credits of a very short video.
    public static func threshold(duration: Double) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        return duration - max(NextUp.creditsLength(duration: duration), min(duration * 0.1, 600))
    }

    public static func isReached(position: Double, duration: Double) -> Bool {
        guard let threshold = threshold(duration: duration) else { return false }
        return position >= threshold
    }

    /// A play shorter than this (opened by mistake, a peek) doesn't un-mark a watched video: it would then be neither
    /// watched nor resumable, and drop out of Continue Watching altogether.
    public static let rewatchSeconds = 30
}
