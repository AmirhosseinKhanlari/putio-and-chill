import AMDBKit
import AppIntents
import AVFoundation
import SwiftUI

@main
struct AMDBApp: App {
    @State private var model: AppModel
    @State private var router: Router
    @State private var ambient = AmbientController()
    @State private var charts = ChartCenter()
    @State private var downloader: OfflineDownloader
    @Environment(\.scenePhase) private var scenePhase

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let model = DemoMode.isEnabled
            ? DemoMode.makeModel()
            : AppModel(tokens: KeychainTokenStore(), store: LocalStore(fileURL: LocalStore.defaultURL()),
                       bundledTMDBToken: Bundle.main.object(forInfoDictionaryKey: "TMDBReadToken") as? String,
                       ratingsCache: RatingsCache(fileURL: RatingsCache.defaultURL()),
                       bundledTraktClientID: Bundle.main.object(forInfoDictionaryKey: "TraktClientID") as? String,
                       bundledOpenSubtitlesKey: Bundle.main.object(forInfoDictionaryKey: "OpenSubtitlesAPIKey") as? String,
                       subtitleCache: SubtitleFileCache(directory: SubtitleFileCache.defaultDirectory()),
                       libraryCache: LibraryCache(fileURL: LibraryCache.defaultURL()))
        _model = State(initialValue: model)
        _downloader = State(initialValue: OfflineDownloader(app: model))
        let router = Router()
        _router = State(initialValue: router)
        // Siri / Shortcuts intents run in this process and use the same models.
        AppDependencyManager.shared.add(dependency: model)
        AppDependencyManager.shared.add(dependency: router)
        BackgroundRefresh.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .environment(ambient)
                .environment(charts)
                .environment(downloader)
                .preferredColorScheme(.dark)
                .tint(.white)
                #if DEBUG
                .overlay { if WidgetGallery.isEnabled { WidgetGallery() } }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active where model.isReady:
                        Task {
                            await model.transfers.restore()
                            // Cached library is already on screen; fetch only when the update interval has passed.
                            await model.refreshLibraryIfDue()
                        }
                    case .background:
                        BackgroundRefresh.schedule(every: model.settings.libraryUpdateMinutes)
                    default:
                        break
                    }
                }
        }
    }
}
