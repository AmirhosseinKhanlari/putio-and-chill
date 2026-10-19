import UIKit

/// Work that must finish even when the app is leaving the screen (saving where playback stopped to put.io): the
/// system is asked for time to finish it, so a TV or Home button press doesn't suspend the app halfway through.
@MainActor
enum BackgroundSave {
    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let assertion = Assertion()
        assertion.id = UIApplication.shared.beginBackgroundTask(withName: name) { assertion.end() }
        Task {
            await work()
            assertion.end()
        }
    }

    @MainActor private final class Assertion {
        var id = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
