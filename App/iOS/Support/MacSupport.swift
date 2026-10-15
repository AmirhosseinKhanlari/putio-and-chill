import SwiftUI
import UIKit

/// The Mac app's menu bar: Settings (⌘,), Search (⌘F) and the sections (⌘1–⌘5). Also keyboard shortcuts on an iPad.
struct MacCommands: Commands {
    let router: Router

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Home") { router.tab = .home }.keyboardShortcut("1", modifiers: .command)
            Button("Movies") { router.tab = .movies }.keyboardShortcut("2", modifiers: .command)
            Button("TV Shows") { router.tab = .tv }.keyboardShortcut("3", modifiers: .command)
            Button("Coming Up") { router.tab = .upcoming }.keyboardShortcut("4", modifiers: .command)
            Button("Library") { router.tab = .library }.keyboardShortcut("5", modifiers: .command)
            Divider()
            Button("Search") { router.tab = .search }.keyboardShortcut("f", modifiers: .command)
            Button("Surprise Me") { router.showSurprise = true }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Mac window: a sensible minimum size (the layout is the iPad's) and a title.
@MainActor
enum MacWindow {
    static func configure() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 1000, height: 680)
            scene.title = "Putio & Chill"
            scene.titlebar?.titleVisibility = .hidden
        }
    }
}
#endif

#if DEBUG
/// `-demoSnapshot`: saves a picture of the window (temporary folder, snapshot.png) a few seconds after launch,
/// for checking layouts where the screen can't be captured.
@MainActor
enum DemoSnapshot {
    static func takeIfAsked() async {
        guard ProcessInfo.processInfo.arguments.contains("-demoSnapshot") else { return }
        try? await Task.sleep(for: .seconds(8))
        guard let window = UIApplication.shared.connectedScenes.flatMap({ ($0 as? UIWindowScene)?.windows ?? [] }).first else { print("snapshot: no window"); return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "snapshot.png")
        try? image.pngData()?.write(to: url)
        print("snapshot: \(url.path)")
    }
}
#endif
