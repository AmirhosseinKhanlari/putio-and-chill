import AMDBCore
import AMDBKit
import AVFoundation
import SwiftUI

@main
struct AMDBTVApp: App {
    @State private var model: AppModel
    @State private var router = TVRouter()
    @State private var ambient = AmbientController()

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 256 << 20)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let info = Bundle.main
        _model = State(initialValue: DemoMode.isEnabled ? DemoMode.makeModel() : AppModel(
            tokens: KeychainTokenStore(), store: LocalStore(fileURL: LocalStore.defaultURL()),
            bundledTMDBToken: info.object(forInfoDictionaryKey: "TMDBReadToken") as? String,
            ratingsCache: RatingsCache(fileURL: RatingsCache.defaultURL()),
            bundledTraktClientID: info.object(forInfoDictionaryKey: "TraktClientID") as? String,
            bundledOpenSubtitlesKey: info.object(forInfoDictionaryKey: "OpenSubtitlesAPIKey") as? String,
            subtitleCache: SubtitleFileCache(directory: SubtitleFileCache.defaultDirectory()),
            libraryCache: LibraryCache(fileURL: LibraryCache.defaultURL())))
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .environment(router)
                .environment(ambient)
                .preferredColorScheme(.dark)
        }
    }
}
