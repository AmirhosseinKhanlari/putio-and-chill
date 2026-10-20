import AMDBKit
import AVKit
import UIKit

/// One player behind the app's controls: Apple's (AVPlayer on put.io's stream) or the built-in one (AetherEngine on
/// the original file). The backend reports its state into the `PlayerEngine` it's attached to and takes the
/// controls' commands; the screen hosts its `videoView`.
@MainActor
protocol PlayerBackend: AnyObject {
    var kind: PlaybackEngineKind { get }
    /// The picture. Hosted full-size by the player screen.
    var videoView: UIView { get }
    var volume: Float { get set }

    /// Starts reporting state into `engine`.
    func attach(to engine: PlayerEngine)
    /// Loads (if it hasn't yet) and plays from `seconds`.
    func start(at seconds: Double, rate: Float)
    func play(rate: Float)
    func pause()
    func seek(to seconds: Double, completion: @escaping @Sendable @MainActor () -> Void)
    func setRate(_ rate: Float, playing: Bool)
    func selectAudio(id: String)
    /// An embedded subtitle track of the file (nil: none). Only the built-in player has them.
    func selectEmbeddedSubtitle(id: Int?)
    func setFill(_ fill: Bool)
    /// A Picture in Picture controller for the current picture, when this player can do one now.
    func makePictureInPicture() -> AVPictureInPictureController?
    /// Picture in Picture started or stopped (the built-in player keeps decoding video for the window).
    func pictureInPictureChanged(active: Bool)
    func tearDown()
}

/// Where loading stands, for the screen's "Preparing…" and the fallback to the next player.
enum PlayerStatus: Equatable {
    case loading
    case ready
    case failed(String?)

    var isFailed: Bool { if case .failed = self { true } else { false } }
}

/// An audio track either player offers.
struct PlayerAudioTrack: Identifiable, Hashable {
    let id: String
    let name: String
}

/// A subtitle track inside the file (built-in player only): offered in the app's subtitles menu.
struct PlayerSubtitleTrack: Identifiable, Hashable {
    let id: Int
    let name: String
    /// A picture-based track (Blu-ray PGS, DVD): drawn as images rather than in the app's subtitle style.
    let isImage: Bool
}

/// What an embedded subtitle shows right now: text (drawn in the app's style) or an image (PGS/DVD), placed in the
/// video's frame. `frame` is relative (0…1) to the picture.
enum EmbeddedSubtitle: Equatable {
    case text(String)
    case images([EmbeddedSubtitleImage])
}

struct EmbeddedSubtitleImage: Equatable {
    let image: CGImage
    let frame: CGRect

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.image === rhs.image && lhs.frame == rhs.frame }
}
