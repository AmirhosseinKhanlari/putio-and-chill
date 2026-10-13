import AMDBKit
import AVFoundation
import SwiftUI

@main
struct AMDBApp: App {
    @State private var model: AppModel
    @State private var router = Router()
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
                       bundledTraktClientID: Bundle.main.object(forInfoDictionaryKey: "TraktClientID") as? String)
        _model = State(initialValue: model)
        _downloader = State(initialValue: OfflineDownloader(app: model))
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
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active where model.isReady:
                        Task {
                            await model.transfers.restore()
                            await model.library.refresh()
                        }
                    case .background:
                        BackgroundRefresh.schedule()
                    default:
                        break
                    }
                }
        }
    }
}
