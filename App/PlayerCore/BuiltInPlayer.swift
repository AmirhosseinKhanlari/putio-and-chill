import AMDBKit
import Foundation
import os
import VideoToolbox

/// The built-in player (AetherEngine) for videos Apple's player can't play: whether this build has it, and what
/// the device decodes in hardware (which decides whether Apple's player can do VP9 / AV1).
enum BuiltInPlayer {
    /// Not in the Mac app: AetherEngine's FFmpeg build has no Mac Catalyst slice, so the Mac keeps Apple's player
    /// (and put.io's conversion as the fallback).
    static var isAvailable: Bool {
        #if canImport(AetherEngine) && !targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// Which player each playback used and why it moved on (Console: subsystem app.amdb, category playback).
    static let log = Logger(subsystem: "app.amdb", category: "playback")

    static var hardwareVP9: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9) }
    static var hardwareAV1: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) }

    /// A built-in player on `url`, or nil where there is none.
    /// - Parameter refreshURL: a fresh link when put.io's download link has expired (nil for a downloaded file).
    @MainActor
    static func backend(url: URL, audioLanguage: String?, refreshURL: (() async -> URL?)?) -> (any PlayerBackend)? {
        #if canImport(AetherEngine) && !targetEnvironment(macCatalyst)
        AetherBackend(url: url, audioLanguage: audioLanguage, refreshURL: refreshURL)
        #else
        nil
        #endif
    }

    /// The routing for one playback, with this device's abilities filled in.
    @MainActor
    static func plan(fileID: Int64, app: AppModel) -> PlaybackPlan {
        app.playbackPlan(fileID: fileID, builtInAvailable: isAvailable, hardwareVP9: hardwareVP9, hardwareAV1: hardwareAV1)
    }
}
