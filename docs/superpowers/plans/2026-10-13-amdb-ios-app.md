# AMDB iOS App Implementation Plan (Plan 2b of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the universal iPad and iPhone SwiftUI app on top of `AMDBKit`, in the Cinematic Ambient style. It covers onboarding, Home, Movies/TV, live Search, the title page, the Versions sheet, the transfer wait and countdown, the Library, Settings, and a native player that syncs `start_from`.

**Architecture:** XcodeGen generates `AMDB.xcodeproj` from `project.yml`. It has one iOS app target (`App/iOS`), which depends on the local `AMDBCore` package (products `AMDBCore` and `AMDBKit`). The app's state is the `AppModel` from `AMDBKit`. A small `@Observable` `Router` owns UI state: tab, navigation paths, the sheet, the player, the banner, and the countdown. An `AmbientController` owns the background palette. All screens are SwiftUI. The only UIKit pieces are representables for `AVPlayerViewController` and `WKWebView`. A `-demo` launch argument swaps in fake services, so every screen can be screenshotted in the simulator without credentials. `-demoScreen <name>` opens a given screen at launch.

**Tech Stack:** Swift 6.4, SwiftUI (iOS 17+), Observation, AVKit, AuthenticationServices, WebKit, BackgroundTasks, UserNotifications, XcodeGen 2.44.

## Global Constraints

- The repo root is `/Users/amirhosseinkhanlari/Downloads/chill-ipad/`. Paths are relative to it.
- Deployment target is iOS 17.0, with `TARGETED_DEVICE_FAMILY` set to `1,2`. Swift 6 language mode. Bundle id `app.amdb.ios`.
- `AMDB.xcodeproj` and `build/` are generated, so both are gitignored. Always run `xcodegen generate` before building.
- URL scheme `amdb`. put.io client ID `9877`, redirect `amdb://oauth/putio`. The chill sign-in start URL is `https://api.chill.institute/auth/putio/start?success_url=https%3A%2F%2Fchill.institute%2Fauth%2Fsuccess`, and the token is captured from the `auth_token` fragment.
- The visual direction is Cinematic Ambient:
  - Base background `#07070B`.
  - A glow taken from the focused title's backdrop, animated with a 0.6 s ease.
  - A floating glass tab bar: at the top on iPad (regular width) and at the bottom on iPhone (compact width).
  - Large ultra-light uppercase titles.
- The Versions sheet always opens; nothing is auto-picked. Seeders are colored green when ≥ 50, yellow for 10–49, and red below 10.
- Transfer wait:
  - If the title page is on screen, a ready transfer runs a 5 s countdown (when the setting is on) and then plays.
  - Otherwise it shows a banner, plus a local notification when the app is in the background.
- Build command, run from the repo root:
  `xcodegen generate --quiet && xcodebuild -project AMDB.xcodeproj -scheme AMDB -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath build -quiet build`
- Screenshot command: `scripts/shot.sh "<device>" <name> [launch args…]`. Devices: `iPad Pro 13-inch (M5)` and `iPhone 18 Pro`.
- Commit after every task. Messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File map

```
project.yml                      XcodeGen spec
scripts/shot.sh                  boot, install, launch, screenshot
App/iOS/
  AMDBApp.swift                  @main, AppModel creation, scene phase hooks
  Router.swift                   AppTab, PlayerRequest, VersionsRequest, NextEpisode, Banner, Router
  DemoMode.swift                 -demo services and data, -demoScreen routing
  Support/Format.swift           clock, runtime, bytes, speed, eta
  Support/CallbackToken.swift    token from callback URL fragment/query
  Support/Notifier.swift         local notifications
  Support/BackgroundRefresh.swift BGAppRefreshTask
  Theme/Theme.swift              colors, metrics, button styles, glass modifiers
  Theme/AmbientPalette.swift     RGB, AmbientPalette (extract, seeded)
  Theme/ImagePipeline.swift      actor image + palette cache
  Theme/AmbientController.swift  @Observable palette focus
  Theme/AmbientBackground.swift  background view + .ambientBackground()
  Theme/RemoteImage.swift        TMDB/put.io image view with seeded placeholder
  Components/ProgressRing.swift
  Components/FlowLayout.swift    wrapping chip layout (added during Task 3 for release tags)
  Components/PosterCard.swift    PosterCard, LibraryPoster
  Components/CatalogRowView.swift CatalogRowView, EntryRowView
  Shell/RootView.swift           onboarding vs main
  Shell/MainView.swift           tab stacks, sheets, event wiring
  Shell/GlassTabBar.swift        GlassTabBar, TransferPill
  Shell/ReadyBanner.swift
  Onboarding/OnboardingView.swift
  Onboarding/ChillConnectView.swift
  Settings/SettingsView.swift
  Home/HomeView.swift            HomeView, ContinueWatchingRow
  Home/HeroCarousel.swift        HeroCarousel, HeroPage, MetaLine
  Home/BrowseView.swift
  Title/TitleView.swift          TitleView, TitleHeader, BackButton, CastRow
  Title/ActionViews.swift        PrimaryActions, DownloadStatus, EpisodeActionButton
  Title/EpisodeList.swift
  Title/CountdownOverlay.swift
  Versions/VersionsSheet.swift   VersionsSheet, FilterBar, ReleaseRow
  Search/SearchView.swift
  Library/LibraryView.swift      LibraryView, LibraryCardView, TransferCard
  Player/PlayerScreen.swift      PlayerScreen, VideoPlayerController
AMDBCore/Sources/AMDBKit/TransferMonitor.swift   (modify: skip library record for tmdbID 0)
```

---

### Task 1: Project, theme, onboarding, settings

**Files:**
- Create: `project.yml`, `scripts/shot.sh`, `App/iOS/AMDBApp.swift`, `App/iOS/Router.swift`, `App/iOS/DemoMode.swift`
- Create: `App/iOS/Support/{Format,CallbackToken,Notifier,BackgroundRefresh}.swift`
- Create: `App/iOS/Theme/{Theme,AmbientPalette,ImagePipeline,AmbientController,AmbientBackground,RemoteImage}.swift`
- Create: `App/iOS/Components/ProgressRing.swift`
- Create: `App/iOS/Shell/RootView.swift`, `App/iOS/Onboarding/{OnboardingView,ChillConnectView}.swift`, `App/iOS/Settings/SettingsView.swift`
- Create: `App/iOS/Shell/MainView.swift`, a temporary version with only the Settings entry point. Task 2 replaces it.
- Modify: `.gitignore` (append `AMDB.xcodeproj/` and `build/`)
- Modify: `AMDBCore/Sources/AMDBKit/TransferMonitor.swift` and `AMDBCore/Tests/AMDBKitTests/TransferMonitorTests.swift`

**Interfaces:**
- Produces:
  - `Router`, with `tab`, `homePath`, `moviesPath`, `tvPath`, `searchPath`, `libraryPath`, `versions`, `player`, `banner`, `countdown`, `showSettings` and `activeTitle`, plus the methods `open(_:)`, `popToRoot(_:)`, `play(_:resumeFrom:next:)` and `play(_:)`
  - `PlayerRequest`, `VersionsRequest`, `NextEpisode`, `Banner`
  - `AmbientController` with `focus(_:)`
  - The view helpers `.ambientBackground()`, `.glassCapsule()` and `.glassRounded(_:)`
  - The button styles `.primaryPill`, `.glassPill` and `.lift`
  - `Theme`, `Metrics`, `Format`, `RemoteImage(path:size:seed:contentMode:)`, `RemoteImage(url:seed:)` and `ProgressRing(progress:lineWidth:)`
- Produces the demo types: `DemoMode`, `DemoCatalog` (with static `movies` and `shows`), `DemoPutio` and `DemoProvider`.

- [ ] **Step 1: Kit tweak, test first.** Text-search transfers have no TMDB id and must not create library matches.

Add this test to `AMDBCore/Tests/AMDBKitTests/TransferMonitorTests.swift`:

```swift
    @Test func untitledTransfersAreNotRecordedInLibrary() async throws {
        let rig = Rig()
        let untitled = TransferTarget(tmdbID: 0, kind: .movie, title: "Some.Release", posterPath: nil, backdropPath: nil,
                                      season: nil, episode: nil)
        let tracked = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "x"), target: untitled)
        rig.monitor.stop()
        rig.putio.add(PutioFile(id: 700, name: "x.mkv", fileType: "VIDEO", size: 1), to: 0)
        rig.putio.setTransfer(PutioTransfer(id: tracked.id, status: "COMPLETED", fileId: 700))
        await rig.monitor.pollOnce()
        #expect(rig.monitor.tracked.first?.playableFile?.id == 700)
        #expect(rig.library.matching(tmdbID: 0).isEmpty)
    }
```

Run: `cd AMDBCore && swift test --filter TransferMonitorTests`. Expected: FAIL, because `matching(tmdbID: 0)` is not empty.

Then, in `TransferMonitor.settle`, wrap the library record call:

```swift
            if pending.tmdbID > 0 {
                await library?.record(file: file, match: LibraryMatch(
                    tmdbID: pending.tmdbID, mediaType: pending.kind, season: pending.season, episode: pending.episode,
                    confidence: 1, title: pending.title, posterPath: pending.posterPath, backdropPath: pending.backdropPath))
            }
```

Run it again. Expected: 8 tests pass.

- [ ] **Step 2: project.yml and shot script**

`project.yml`:

```yaml
name: AMDB
options:
  bundleIdPrefix: app.amdb
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: "1"
packages:
  AMDBCore:
    path: AMDBCore
targets:
  AMDB:
    type: application
    platform: iOS
    sources:
      - path: App/iOS
    dependencies:
      - package: AMDBCore
        product: AMDBCore
      - package: AMDBCore
        product: AMDBKit
    info:
      path: App/iOS/Info.plist
      properties:
        CFBundleDisplayName: AMDB
        UILaunchScreen:
          UIColorName: ""
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        CFBundleURLTypes:
          - CFBundleURLName: app.amdb.oauth
            CFBundleURLSchemes: [amdb]
        UIBackgroundModes: [fetch, audio]
        BGTaskSchedulerPermittedIdentifiers: [app.amdb.refresh]
        UIUserInterfaceStyle: Dark
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.amdb.ios
        TARGETED_DEVICE_FAMILY: "1,2"
        CODE_SIGN_STYLE: Automatic
        GENERATE_INFOPLIST_FILE: NO
```

`scripts/shot.sh` (make it executable with `chmod +x scripts/shot.sh`):

```bash
#!/bin/zsh
# usage: scripts/shot.sh "<simulator name>" <shot-name> [launch args...]
set -e
device=$1; name=$2; shift 2
app=build/Build/Products/Debug-iphonesimulator/AMDB.app
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl install "$device" "$app"
xcrun simctl terminate "$device" app.amdb.ios 2>/dev/null || true
xcrun simctl launch "$device" app.amdb.ios "$@" >/dev/null
sleep ${SHOT_DELAY:-6}
mkdir -p build/shots
xcrun simctl io "$device" screenshot "build/shots/$name.png" >/dev/null
echo "build/shots/$name.png"
```

- [ ] **Step 3: Support files**

`App/iOS/Support/Format.swift`:

```swift
import Foundation

enum Format {
    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func runtime(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func bytes(_ count: Int64?) -> String {
        guard let count, count > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Int64?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file) + "/s"
    }

    static func eta(_ seconds: Int64?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds < 60 { return "less than a minute left" }
        if seconds < 3600 { return "about \(seconds / 60) min left" }
        return "about \(seconds / 3600) h left"
    }
}
```

`App/iOS/Support/CallbackToken.swift`:

```swift
import Foundation

enum CallbackToken {
    /// Reads `name` from a URL's fragment (`#name=…`) or query (`?name=…`).
    static func value(named name: String, in url: URL) -> String? {
        for part in [url.fragment, URLComponents(url: url, resolvingAgainstBaseURL: false)?.query] {
            guard let part else { continue }
            var components = URLComponents()
            components.query = part
            if let value = components.queryItems?.first(where: { $0.name == name })?.value, !value.isEmpty { return value }
        }
        return nil
    }
}
```

`App/iOS/Support/Notifier.swift`:

```swift
import AMDBKit
import UserNotifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func ready(_ transfer: TrackedTransfer) {
        let content = UNMutableNotificationContent()
        content.title = "\(transfer.pending.title) is ready"
        content.body = "It's in your put.io. Tap to watch."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ready-\(transfer.id)", content: content, trigger: nil))
    }
}
```

`App/iOS/Support/BackgroundRefresh.swift`:

```swift
import AMDBKit
import BackgroundTasks

enum BackgroundRefresh {
    static let identifier = "app.amdb.refresh"

    @MainActor static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated {
                schedule()
                let work = Task { await model.transfers.pollOnce() }
                task.expirationHandler = { work.cancel() }
                Task {
                    await work.value
                    task.setTaskCompleted(success: true)
                }
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
```

- [ ] **Step 4: Theme files**

`App/iOS/Theme/Theme.swift`:

```swift
import SwiftUI

enum Theme {
    static let background = Color(red: 0.027, green: 0.027, blue: 0.043)
    static let sheet = Color(red: 0.075, green: 0.07, blue: 0.09)
    static let good = Color(red: 0.29, green: 0.87, blue: 0.5)
    static let okay = Color(red: 0.98, green: 0.8, blue: 0.08)
    static let poor = Color(red: 0.97, green: 0.44, blue: 0.44)

    static func seeders(_ count: Int?) -> Color {
        switch count ?? 0 {
        case 50...: good
        case 10..<50: okay
        default: poor
        }
    }
}

enum Metrics {
    static func poster(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat { sizeClass == .compact ? 112 : 150 }
    static func gutter(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat { sizeClass == .compact ? 16 : 32 }
    static func tabBarInset(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat { sizeClass == .compact ? 72 : 76 }
}

struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 20).padding(.vertical, 11)
            .foregroundStyle(.black)
            .background(.white, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct GlassPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .foregroundStyle(.white)
            .glassCapsule()
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct LiftStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryPillStyle { static var primaryPill: PrimaryPillStyle { PrimaryPillStyle() } }
extension ButtonStyle where Self == GlassPillStyle { static var glassPill: GlassPillStyle { GlassPillStyle() } }
extension ButtonStyle where Self == LiftStyle { static var lift: LiftStyle { LiftStyle() } }

extension View {
    @ViewBuilder func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        }
    }

    @ViewBuilder func glassRounded(_ radius: CGFloat = 18) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.14)))
        }
    }
}
```

`App/iOS/Theme/AmbientPalette.swift`:

```swift
import SwiftUI
import UIKit

struct RGB: Equatable, Sendable {
    var r: Double, g: Double, b: Double

    var color: Color { Color(red: r, green: g, blue: b) }

    /// Pushes saturation up and keeps brightness in a range that glows without washing out text.
    func vivid() -> RGB {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let out = UIColor(hue: h, saturation: min(1, s * 1.35 + 0.08), brightness: min(0.85, max(0.42, v * 1.25)), alpha: 1)
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0
        out.getRed(&rr, green: &gg, blue: &bb, alpha: &a)
        return RGB(r: rr, g: gg, b: bb)
    }
}

struct AmbientPalette: Equatable, Sendable {
    var primary: RGB
    var secondary: RGB

    static let neutral = AmbientPalette(primary: RGB(r: 0.23, g: 0.3, b: 0.55), secondary: RGB(r: 0.2, g: 0.12, b: 0.3))

    /// Stable colors for titles without artwork (and for demo mode).
    static func seeded(_ seed: String) -> AmbientPalette {
        let hue = Double(stableHash(seed) % 360) / 360
        let primary = UIColor(hue: hue, saturation: 0.7, brightness: 0.75, alpha: 1)
        let secondary = UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.45, alpha: 1)
        return AmbientPalette(primary: rgb(primary), secondary: rgb(secondary))
    }

    static func extract(from image: CGImage) -> AmbientPalette {
        let width = 24, height = 14
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return .neutral }
        func average(columns: Range<Int>, rows: Range<Int>) -> RGB {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in rows {
                for x in columns {
                    let i = (y * width + x) * 4
                    r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2]); n += 1
                }
            }
            return RGB(r: r / n / 255, g: g / n / 255, b: b / n / 255)
        }
        return AmbientPalette(primary: average(columns: width / 2..<width, rows: 0..<height / 2).vivid(),
                              secondary: average(columns: 0..<width / 2, rows: height / 2..<height).vivid())
    }

    private static func rgb(_ color: UIColor) -> RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(r: r, g: g, b: b)
    }
}

/// djb2; Swift's `hashValue` is randomized per launch.
func stableHash(_ text: String) -> Int {
    var hash = 5381
    for scalar in text.unicodeScalars { hash = ((hash << 5) &+ hash) &+ Int(scalar.value) }
    return abs(hash)
}
```

`App/iOS/Theme/ImagePipeline.swift`:

```swift
import UIKit

actor ImagePipeline {
    static let shared = ImagePipeline()

    private let cache = NSCache<NSURL, UIImage>()
    private var palettes: [URL: AmbientPalette] = [:]

    func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let image = UIImage(data: data) else { return nil }
        let prepared = await image.byPreparingForDisplay() ?? image
        cache.setObject(prepared, forKey: url as NSURL)
        return prepared
    }

    func palette(for url: URL) async -> AmbientPalette? {
        if let hit = palettes[url] { return hit }
        guard let cgImage = await image(for: url)?.cgImage else { return nil }
        let palette = AmbientPalette.extract(from: cgImage)
        palettes[url] = palette
        return palette
    }
}
```

`App/iOS/Theme/AmbientController.swift`:

```swift
import AMDBCore
import Observation
import SwiftUI

@Observable @MainActor
final class AmbientController {
    private(set) var palette = AmbientPalette.neutral
    @ObservationIgnored private var task: Task<Void, Never>?

    func focus(_ item: CatalogItem) {
        focus(path: item.backdropPath ?? item.posterPath, seed: item.title)
    }

    func focus(path: String?, seed: String) {
        task?.cancel()
        task = Task {
            var next = AmbientPalette.seeded(seed)
            if let url = CatalogClient.imageURL(path, size: "w300"), let extracted = await ImagePipeline.shared.palette(for: url) {
                next = extracted
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { palette = next }
        }
    }
}
```

`App/iOS/Theme/AmbientBackground.swift`:

```swift
import SwiftUI

struct AmbientBackground: View {
    let palette: AmbientPalette

    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [palette.primary.color.opacity(0.8), palette.primary.color.opacity(0.22), .clear],
                           center: UnitPoint(x: 0.8, y: 0.0), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [palette.secondary.color.opacity(0.35), .clear],
                           center: UnitPoint(x: 0.05, y: 1.0), startRadius: 0, endRadius: 700)
            LinearGradient(colors: [.clear, Theme.background.opacity(0.6)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: palette)
    }
}

private struct AmbientBackgroundModifier: ViewModifier {
    @Environment(AmbientController.self) private var ambient

    func body(content: Content) -> some View {
        content.background { AmbientBackground(palette: ambient.palette) }
    }
}

extension View {
    func ambientBackground() -> some View { modifier(AmbientBackgroundModifier()) }
}
```

`App/iOS/Theme/RemoteImage.swift`:

```swift
import AMDBCore
import SwiftUI

/// Remote artwork with a colored placeholder seeded from the title, so missing art still looks intentional.
struct RemoteImage: View {
    private let url: URL?
    private let seed: String
    private let contentMode: ContentMode
    @State private var image: UIImage?

    init(path: String?, size: String, seed: String, contentMode: ContentMode = .fill) {
        self.url = CatalogClient.imageURL(path, size: size)
        self.seed = seed
        self.contentMode = contentMode
    }

    init(url: URL?, seed: String) {
        self.url = url
        self.seed = seed
        self.contentMode = .fill
    }

    var body: some View {
        ZStack {
            if contentMode == .fill {
                let palette = AmbientPalette.seeded(seed)
                LinearGradient(colors: [palette.primary.color, palette.secondary.color], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await ImagePipeline.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
}
```

`App/iOS/Components/ProgressRing.swift`:

```swift
import SwiftUI

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 4
    var tint: Color = .white

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)
        }
    }
}
```

- [ ] **Step 5: Router, demo mode, app entry**

`App/iOS/Router.swift`:

```swift
import AMDBCore
import AMDBKit
import Observation
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home, movies, tv, search, library

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .tv: "TV"
        case .search: "Search"
        case .library: "Library"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .movies: "film"
        case .tv: "tv"
        case .search: "magnifyingglass"
        case .library: "square.stack.fill"
        }
    }
}

struct NextEpisode: Hashable {
    let query: MediaQuery?
    let target: TransferTarget
    let label: String
}

struct PlayerRequest: Identifiable {
    let file: PutioFile
    let title: String
    let resumeFrom: Int
    let played: PlayedTitle?
    let next: NextEpisode?
    var id: Int64 { file.id }
}

struct VersionsRequest: Identifiable {
    let id = UUID()
    let query: MediaQuery
    let target: TransferTarget?
    let playNow: [LibraryEntry]
}

enum Banner: Identifiable, Equatable {
    case ready(TrackedTransfer)
    case failed(TrackedTransfer)

    var transfer: TrackedTransfer {
        switch self {
        case let .ready(transfer), let .failed(transfer): transfer
        }
    }
    var id: Int64 { transfer.id }
}

@Observable @MainActor
final class Router {
    var tab: AppTab = .home
    var homePath: [CatalogItem] = []
    var moviesPath: [CatalogItem] = []
    var tvPath: [CatalogItem] = []
    var searchPath: [CatalogItem] = []
    var libraryPath: [CatalogItem] = []
    var versions: VersionsRequest?
    var player: PlayerRequest?
    var banner: Banner?
    var countdown: TrackedTransfer?
    var showSettings = false
    /// TMDB id of the title page on screen; a ready transfer for it counts down instead of showing a banner.
    var activeTitle: Int?

    func open(_ item: CatalogItem) {
        switch tab {
        case .home: homePath.append(item)
        case .movies: moviesPath.append(item)
        case .tv: tvPath.append(item)
        case .search: searchPath.append(item)
        case .library: libraryPath.append(item)
        }
    }

    func popToRoot(_ tab: AppTab) {
        switch tab {
        case .home: homePath = []
        case .movies: moviesPath = []
        case .tv: tvPath = []
        case .search: searchPath = []
        case .library: libraryPath = []
        }
    }

    func play(_ entry: LibraryEntry, resumeFrom: Int, next: NextEpisode? = nil) {
        let played = entry.match.map { PlayedTitle(tmdbID: $0.tmdbID, kind: $0.mediaType, title: $0.title) }
        player = PlayerRequest(file: entry.file, title: entry.displayTitle, resumeFrom: resumeFrom, played: played, next: next)
    }

    func play(_ transfer: TrackedTransfer) {
        guard let file = transfer.playableFile else { return }
        let pending = transfer.pending
        let played = pending.tmdbID > 0 ? PlayedTitle(tmdbID: pending.tmdbID, kind: pending.kind, title: pending.title) : nil
        player = PlayerRequest(file: file, title: pending.title, resumeFrom: 0, played: played, next: nil)
    }
}
```

`App/iOS/DemoMode.swift`:

```swift
import AMDBCore
import AMDBKit
import Foundation

/// `-demo` swaps in fake services so every screen can be exercised without credentials.
/// `-demoScreen title|show|versions|search|library|countdown` opens a screen at launch.
enum DemoMode {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-demoScreen"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    @MainActor static func makeModel() -> AppModel {
        let putio = DemoPutio()
        let factory = ServiceFactory(
            makePutio: { _ in putio },
            makeCatalog: { _ in DemoCatalog() },
            makeProvider: { config, _ in DemoProvider(id: config.id) })
        return AppModel(tokens: InMemoryTokenStore([.putio: "demo", .tmdb: "demo", .chill: "demo"]),
                        defaults: UserDefaults(suiteName: "amdb.demo") ?? .standard,
                        store: LocalStore(fileURL: nil), factory: factory)
    }

    @MainActor static func apply(to router: Router) {
        switch screen {
        case "title": router.homePath = [DemoCatalog.movies[0]]
        case "show": router.homePath = [DemoCatalog.shows[0]]
        case "versions":
            router.homePath = [DemoCatalog.movies[0]]
            router.versions = VersionsRequest(query: .movie(imdbID: "tt0", title: DemoCatalog.movies[0].title, year: 2024),
                                              target: nil, playNow: [])
        case "search": router.tab = .search
        case "library": router.tab = .library
        case "movies": router.tab = .movies
        default: break
        }
    }
}

struct DemoCatalog: CatalogService {
    static let movies: [CatalogItem] = [
        ("Furiosa: A Mad Max Saga", 2024, "As the world fell, young Furiosa is snatched from the Green Place of Many Mothers."),
        ("Dune: Part Two", 2024, "Paul Atreides unites with Chani and the Fremen while on a path of revenge."),
        ("Interstellar", 2014, "A team of explorers travel through a wormhole in space."),
        ("Past Lives", 2023, "Two childhood friends reunite in New York for one fateful week."),
        ("Oppenheimer", 2023, "The story of J. Robert Oppenheimer and the atomic bomb."),
        ("Blade Runner 2049", 2017, "A new blade runner unearths a long-buried secret."),
        ("Arrival", 2016, "A linguist works with the military to communicate with alien lifeforms."),
        ("Heat", 1995, "A group of high-end professional thieves start to feel the heat from the LAPD."),
        ("Parasite", 2019, "Greed and class discrimination threaten a newly formed symbiotic relationship."),
        ("Everything Everywhere All at Once", 2022, "A middle-aged immigrant is swept up in an insane adventure."),
    ].enumerated().map { index, entry in
        CatalogItem(tmdbID: 100 + index, mediaType: .movie, title: entry.0, overview: entry.2,
                    backdropPath: "/demo-\(100 + index).jpg", year: entry.1, voteAverage: 7.4 + Double(index % 5) / 5)
    }

    static let shows: [CatalogItem] = [
        ("Severance", 2022), ("Shōgun", 2024), ("The Bear", 2022), ("Andor", 2022), ("Slow Horses", 2022), ("The Last of Us", 2023),
    ].enumerated().map { index, entry in
        CatalogItem(tmdbID: 200 + index, mediaType: .tv, title: entry.0, overview: "A prestige series everyone keeps recommending.",
                    backdropPath: "/demo-\(200 + index).jpg", year: entry.1, voteAverage: 8.4)
    }

    private static var everything: [CatalogItem] { movies + shows }

    func validate() async throws {}
    func searchMulti(_ query: String) async throws -> [CatalogItem] {
        try await Task.sleep(for: .milliseconds(120))
        return Self.everything.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    func trending(_ kind: MediaKind?) async throws -> [CatalogItem] { Array(Self.movies.prefix(4)) + Array(Self.shows.prefix(3)) }
    func popular(_ kind: MediaKind) async throws -> [CatalogItem] { kind == .tv ? Self.shows : Self.movies }
    func topRated(_ kind: MediaKind) async throws -> [CatalogItem] { (kind == .tv ? Self.shows : Self.movies).reversed() }
    func discover(_ kind: MediaKind, genreID: Int) async throws -> [CatalogItem] {
        let pool = kind == .tv ? Self.shows : Self.movies
        let shift = genreID % pool.count
        return Array(pool[shift...] + pool[..<shift])
    }
    func detail(_ kind: MediaKind, id: Int) async throws -> TitleDetail {
        guard let item = Self.everything.first(where: { $0.tmdbID == id }) else { throw AppError.http(service: "tmdb", status: 404) }
        let cast = ["Anya Taylor-Joy", "Chris Hemsworth", "Tom Burke", "Alyla Browne", "George Shevtsov"].map {
            CastMember(name: $0, character: "Character", profilePath: nil)
        }
        let seasons = kind == .tv ? (1...2).map { SeasonSummary(number: $0, name: "Season \($0)", episodeCount: 8, posterPath: nil) } : []
        return TitleDetail(item: item, imdbID: "tt\(id)", runtimeMinutes: kind == .tv ? 55 : 148,
                           genres: kind == .tv ? ["Drama", "Mystery"] : ["Action", "Adventure", "Science Fiction"],
                           cast: cast, recommendations: Array(Self.movies.shuffled().prefix(8)), seasons: seasons)
    }
    func season(tvID: Int, number: Int) async throws -> [Episode] {
        (1...8).map { Episode(number: $0, name: "Episode \($0)", overview: "Things get complicated at Lumon.", runtimeMinutes: 50 + $0) }
    }
    func searchMovie(title: String, year: Int?) async throws -> [CatalogItem] {
        Self.movies.filter { LibraryMatcher.normalize($0.title) == LibraryMatcher.normalize(title) }
    }
    func searchTV(title: String, year: Int?) async throws -> [CatalogItem] {
        Self.shows.filter { LibraryMatcher.normalize($0.title) == LibraryMatcher.normalize(title) }
    }
}

final class DemoPutio: PutioService, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: Int64 = 9000
    private var transfersStarted: [Int64: Date] = [:]
    private var extraFiles: [Int64: PutioFile] = [:]

    private let rootFiles: [PutioFile] = [
        PutioFile(id: 1, name: "Interstellar.2014.1080p.BluRay.x264.mkv", fileType: "VIDEO", size: 9_000_000_000,
                  createdAt: "2026-10-10T10:00:00", updatedAt: "2026-10-12T21:00:00", startFrom: 4360),
        PutioFile(id: 2, name: "Severance.S02E04.1080p.WEB.H264-NTb.mkv", fileType: "VIDEO", size: 2_000_000_000,
                  createdAt: "2026-10-11T10:00:00", updatedAt: "2026-10-12T22:00:00", startFrom: 1250),
        PutioFile(id: 3, name: "Past.Lives.2023.1080p.WEB.mkv", fileType: "VIDEO", size: 3_000_000_000,
                  createdAt: "2026-10-09T10:00:00", startFrom: 0),
        PutioFile(id: 4, name: "Heat.1995.REMASTERED.1080p.BluRay.mkv", fileType: "VIDEO", size: 11_000_000_000,
                  createdAt: "2026-10-01T10:00:00", updatedAt: "2026-10-03T10:00:00", startFrom: 600),
        PutioFile(id: 5, name: "Home.Video.2019.mov", fileType: "VIDEO", size: 300_000_000, createdAt: "2026-09-01T10:00:00"),
    ]

    func accountInfo() async throws -> PutioAccount { PutioAccount(username: "demo") }

    func addTransfer(url: String, saveParentID: Int64?) async throws -> PutioTransfer {
        let id = lock.withLock { () -> Int64 in
            nextID += 1
            transfersStarted[nextID] = Date()
            return nextID
        }
        return try await transfer(id: id)
    }

    /// Demo transfers download for ~8 seconds, then complete into a new video file.
    func transfer(id: Int64) async throws -> PutioTransfer {
        guard let started = lock.withLock({ transfersStarted[id] }) else { throw AppError.http(service: "putio", status: 404) }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 8 {
            let percent = Int(elapsed / 8 * 100)
            return PutioTransfer(id: id, name: "Demo", status: "DOWNLOADING", percentDone: percent, downSpeed: 48_000_000,
                                 peersConnected: 112, estimatedTime: Int64(8 - elapsed), downloaded: Int64(percent) * 30_000_000)
        }
        let fileID = id + 100_000
        lock.withLock {
            extraFiles[fileID] = PutioFile(id: fileID, name: "Demo.Release.1080p.mkv", fileType: "VIDEO", size: 3_000_000_000,
                                           createdAt: "2026-10-13T10:00:00")
        }
        return PutioTransfer(id: id, name: "Demo", status: "COMPLETED", percentDone: 100, hash: nil, fileId: fileID)
    }

    func transfers() async throws -> [PutioTransfer] { [] }
    func cancelTransfers(ids: [Int64]) async throws { lock.withLock { ids.forEach { transfersStarted[$0] = nil } } }
    func retryTransfer(id: Int64) async throws -> PutioTransfer { try await transfer(id: id) }

    func listFiles(parentID: Int64) async throws -> PutioFileList {
        PutioFileList(parent: nil, files: parentID == 0 ? rootFiles : [])
    }

    func file(id: Int64) async throws -> PutioFile {
        if let file = rootFiles.first(where: { $0.id == id }) ?? lock.withLock({ extraFiles[id] }) { return file }
        return PutioFile(id: id, name: "Folder", fileType: "FOLDER")
    }

    func createFolder(name: String, parentID: Int64) async throws -> PutioFile {
        lock.withLock {
            nextID += 1
            return PutioFile(id: nextID, name: name, fileType: "FOLDER", parentId: parentID)
        }
    }

    func startFrom(fileID: Int64) async throws -> Int { 0 }
    func setStartFrom(fileID: Int64, seconds: Int) async throws {}
    func hlsURL(fileID: Int64) -> URL {
        URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!
    }
    func originalURL(fileID: Int64) async throws -> URL { hlsURL(fileID: fileID) }
}

struct DemoProvider: SourceProvider {
    let id: String

    func releases(for query: MediaQuery) async throws -> [Release] {
        try await Task.sleep(for: .milliseconds(300 + abs(stableHash(id)) % 900))
        let title = query.searchText.replacingOccurrences(of: " ", with: ".")
        let tag = id == "chill" ? SourceTag(.chill, "TPB") : SourceTag(.direct, id.uppercased())
        let variants: [(String, Int64, Int)] = [
            ("2160p.WEB-DL.DDP5.1.DV.HDR.H.265-FLUX", 18_200_000_000, 412),
            ("1080p.WEBRip.x264.AAC5.1", 2_900_000_000, 1200),
            ("1080p.BluRay.x264-SPARKS", 11_400_000_000, 88),
            ("720p.WEBRip.x264", 1_100_000_000, 6),
        ]
        return variants.enumerated().compactMap { index, variant in
            guard (stableHash(id) + index) % 3 != 0 || id == "chill" else { return nil }
            let hash = String(repeating: String(index), count: 40)
            return Release(name: "\(title).\(variant.0)", link: "magnet:?xt=urn:btih:\(hash)", sizeBytes: variant.1,
                           seeders: variant.2, sources: [tag])
        }
    }
}
```

`App/iOS/AMDBApp.swift`:

```swift
import AMDBKit
import AVFoundation
import SwiftUI

@main
struct AMDBApp: App {
    @State private var model: AppModel
    @State private var router = Router()
    @State private var ambient = AmbientController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let model = DemoMode.isEnabled
            ? DemoMode.makeModel()
            : AppModel(tokens: KeychainTokenStore(), store: LocalStore(fileURL: LocalStore.defaultURL()))
        _model = State(initialValue: model)
        BackgroundRefresh.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .environment(ambient)
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
```

- [ ] **Step 6: Root, onboarding, chill connect, settings, temporary main view**

`App/iOS/Shell/RootView.swift`:

```swift
import AMDBKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("amdb.onboarded") private var onboarded = false

    var body: some View {
        Group {
            if app.isReady && (onboarded || DemoMode.isEnabled) {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: app.isReady && onboarded)
    }
}
```

`App/iOS/Onboarding/OnboardingView.swift`:

```swift
import AMDBCore
import AMDBKit
import AuthenticationServices
import SwiftUI

enum PutioConfig {
    static let clientID = "9877"
    static let redirectURI = "amdb://oauth/putio"
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @AppStorage("amdb.onboarded") private var onboarded = false
    @State private var putioPaste = ""
    @State private var tmdbToken = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var showChill = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AMDB").font(.system(size: 56, weight: .ultraLight)).tracking(10)
                    Text("Find it. Send it to put.io. Watch it.").foregroundStyle(.white.opacity(0.7))
                }
                .padding(.bottom, 12)

                StepCard(number: 1, title: "Connect put.io", done: app.putio != nil) {
                    Button { Task { await connectPutio() } } label: { Label("Sign in with put.io", systemImage: "person.badge.key.fill") }
                        .buttonStyle(.primaryPill)
                    DisclosureGroup("Paste a token instead") {
                        HStack {
                            SecureField("put.io OAuth token", text: $putioPaste).textFieldStyle(.roundedBorder)
                            Button("Save") { app.setToken(putioPaste.trimmingCharacters(in: .whitespaces), for: .putio) }
                                .disabled(putioPaste.isEmpty)
                        }
                    }
                    .font(.footnote)
                }

                StepCard(number: 2, title: "Add your TMDB token", done: app.catalog != nil) {
                    Text("Free: themoviedb.org → Settings → API → **API Read Access Token**.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    HStack {
                        SecureField("eyJhbGciOi…", text: $tmdbToken).textFieldStyle(.roundedBorder)
                        Button { Task { await saveTMDB() } } label: { busy ? AnyView(ProgressView()) : AnyView(Text("Verify")) }
                            .buttonStyle(.glassPill)
                            .disabled(tmdbToken.isEmpty || busy)
                    }
                }

                StepCard(number: 3, title: "Connect chill (optional)", done: app.hasChill) {
                    Text("Adds chill's eight indexers to every search. You can do this later in Settings.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    Button("Connect chill") { showChill = true }.buttonStyle(.glassPill)
                }

                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(Theme.poor)
                }

                Button {
                    Notifier.requestAuthorization()
                    onboarded = true
                } label: {
                    Text("Start watching").frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryPill)
                .disabled(!app.isReady)
                .opacity(app.isReady ? 1 : 0.4)
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .ambientBackground()
        .sheet(isPresented: $showChill) { ChillConnectView() }
    }

    private func connectPutio() async {
        errorText = nil
        do {
            let callback = try await webAuthenticationSession.authenticate(
                using: PutioClient.authorizeURL(clientID: PutioConfig.clientID, redirectURI: PutioConfig.redirectURI),
                callbackURLScheme: "amdb")
            guard let token = PutioClient.token(fromCallback: callback) else {
                errorText = "put.io didn't send a token back. Try again."
                return
            }
            app.setToken(token, for: .putio)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveTMDB() async {
        busy = true
        defer { busy = false }
        let token = tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await app.validateTMDB(token)
            app.setToken(token, for: .tmdb)
            errorText = nil
        } catch {
            errorText = "TMDB rejected that token. Copy the long “API Read Access Token”, not the short API key."
        }
    }
}

private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(done ? Theme.good : .white.opacity(0.15)).frame(width: 28, height: 28)
                    if done { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black) } else { Text("\(number)").font(.caption.bold()) }
                }
                Text(title).font(.headline)
            }
            if !done { content }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRounded()
    }
}
```

`App/iOS/Onboarding/ChillConnectView.swift`:

```swift
import AMDBKit
import SwiftUI
import WebKit

struct ChillConnectView: View {
    static let startURL = URL(string: "https://api.chill.institute/auth/putio/start?success_url=https%3A%2F%2Fchill.institute%2Fauth%2Fsuccess")!

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ChillWebView(startURL: Self.startURL) { token in
                    app.setToken(token, for: .chill)
                    dismiss()
                }
                HStack {
                    SecureField("…or paste your chilly token", text: $pasted).textFieldStyle(.roundedBorder)
                    Button("Save") {
                        app.setToken(pasted.trimmingCharacters(in: .whitespacesAndNewlines), for: .chill)
                        dismiss()
                    }
                    .disabled(pasted.isEmpty)
                }
                .padding()
                .background(Theme.sheet)
            }
            .navigationTitle("Connect chill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct ChillWebView: UIViewRepresentable {
    let startURL: URL
    let onToken: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        private let onToken: @MainActor (String) -> Void
        private var delivered = false

        init(onToken: @escaping @MainActor (String) -> Void) { self.onToken = onToken }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url, capture(url) { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url { _ = capture(url) }
        }

        private func capture(_ url: URL) -> Bool {
            guard !delivered, let token = CallbackToken.value(named: "auth_token", in: url) else { return false }
            delivered = true
            onToken(token)
            return true
        }
    }
}
```

`App/iOS/Settings/SettingsView.swift`:

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("amdb.onboarded") private var onboarded = false
    @State private var username: String?
    @State private var draft = AppSettings.defaults
    @State private var showChill = false
    @State private var tmdbDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts") {
                    LabeledContent("put.io", value: username ?? (app.putio == nil ? "Not connected" : "Connected"))
                    Button("Sign out of put.io", role: .destructive) {
                        app.setToken(nil, for: .putio)
                        onboarded = false
                        dismiss()
                    }
                    LabeledContent("TMDB", value: app.catalog == nil ? "Not connected" : "Connected")
                    HStack {
                        SecureField("Replace TMDB token", text: $tmdbDraft)
                        Button("Save") {
                            Task {
                                let token = tmdbDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                if (try? await app.validateTMDB(token)) != nil { app.setToken(token, for: .tmdb); tmdbDraft = "" }
                            }
                        }
                        .disabled(tmdbDraft.isEmpty)
                    }
                    if app.hasChill {
                        Button("Disconnect chill", role: .destructive) { app.setToken(nil, for: .chill) }
                    } else {
                        Button("Connect chill") { showChill = true }
                    }
                }

                Section {
                    ForEach($draft.sources) { $source in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(source.name, isOn: $source.enabled)
                            TextField("Base URL", text: $source.baseURL)
                                .font(.caption.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Sites move. If one stops answering, update its address here. chill needs a connected account.")
                }

                Section("Playback") {
                    Picker("Default quality", selection: $draft.defaultResolution) {
                        Text("All").tag(Int?.none)
                        Text("4K").tag(Int?.some(2160))
                        Text("1080p").tag(Int?.some(1080))
                        Text("720p").tag(Int?.some(720))
                    }
                    Toggle("Auto-play when ready", isOn: $draft.autoPlayCountdown)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sheet)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        app.updateSettings(draft)
                        dismiss()
                    }
                }
            }
            .task {
                draft = app.settings
                username = try? await app.putio?.accountInfo().username
            }
            .sheet(isPresented: $showChill) { ChillConnectView() }
        }
    }
}
```

Temporary `App/iOS/Shell/MainView.swift` (Task 2 replaces it):

```swift
import AMDBKit
import SwiftUI

struct MainView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 16) {
            Text("AMDB").font(.system(size: 48, weight: .ultraLight)).tracking(8)
            Button("Settings") { router.showSettings = true }.buttonStyle(.glassPill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ambientBackground()
        .sheet(isPresented: $router.showSettings) { SettingsView() }
    }
}
```

- [ ] **Step 7: Build and screenshot onboarding**

```bash
printf 'AMDB.xcodeproj/\nbuild/\n' >> .gitignore
xcodegen generate --quiet && xcodebuild -project AMDB.xcodeproj -scheme AMDB -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath build -quiet build
scripts/shot.sh "iPad Pro 13-inch (M5)" onboarding-ipad
scripts/shot.sh "iPad Pro 13-inch (M5)" demo-shell -demo
```

Expected: the build succeeds with no errors. `onboarding-ipad.png` shows the AMDB wordmark and three glass step cards over the dark blue ambient glow. `demo-shell.png` shows the temporary main view. Open both PNGs and check them visually.

- [ ] **Step 8: Commit**

```bash
git add .gitignore project.yml scripts App AMDBCore && git commit -m "feat(ios): project, theme, onboarding, settings, demo mode"
```

---

### Task 2: Shell, tab bar, banner, Home and Browse

**Files:**
- Replace: `App/iOS/Shell/MainView.swift`
- Create: `App/iOS/Shell/GlassTabBar.swift`, `App/iOS/Shell/ReadyBanner.swift`
- Create: `App/iOS/Components/PosterCard.swift`, `App/iOS/Components/CatalogRowView.swift`
- Create: `App/iOS/Home/HomeView.swift`, `App/iOS/Home/HeroCarousel.swift`, `App/iOS/Home/BrowseView.swift`
- Create these stubs so the shell compiles: `App/iOS/Title/TitleView.swift`, `App/iOS/Search/SearchView.swift`, `App/iOS/Library/LibraryView.swift`, `App/iOS/Versions/VersionsSheet.swift`, `App/iOS/Player/PlayerScreen.swift`. Each stub is a small real view, shown below. Tasks 3–5 replace them.

**Interfaces:**
- Consumes: Task 1 types, `HomeModel`, `BrowseModel`, `LibraryIndex`
- Produces:
  - `PosterCard(item:width:)`, `LibraryPoster(entry:width:resumeSeconds:)`
  - `CatalogRowView(row:)`, `EntryRowView(title:entries:)`
  - `MetaLine(item:detail:)`

- [ ] **Step 1: Write MainView.swift (replace)**

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var visited: Set<AppTab> = [.home]

    var body: some View {
        @Bindable var router = router
        ZStack(alignment: sizeClass == .compact ? .bottom : .top) {
            ForEach(AppTab.allCases) { tab in
                if visited.contains(tab) {
                    TabStack(tab: tab, path: path(for: tab, router: $router))
                        .opacity(router.tab == tab ? 1 : 0)
                        .allowsHitTesting(router.tab == tab)
                }
            }
            GlassTabBar()
                .padding(.horizontal, 12)
                .padding(sizeClass == .compact ? .bottom : .top, 6)
        }
        .overlay(alignment: .top) { ReadyBanner() }
        .onChange(of: router.tab, initial: true) { _, tab in visited.insert(tab) }
        .sheet(item: $router.versions) { VersionsSheet(request: $0) }
        .fullScreenCover(item: $router.player) { PlayerScreen(request: $0) }
        .sheet(isPresented: $router.showSettings) { SettingsView() }
        .task {
            wireEvents()
            DemoMode.apply(to: router)
            await app.transfers.restore()
            await app.library.refresh()
        }
    }

    private func path(for tab: AppTab, router: Bindable<Router>) -> Binding<[CatalogItem]> {
        switch tab {
        case .home: router.homePath
        case .movies: router.moviesPath
        case .tv: router.tvPath
        case .search: router.searchPath
        case .library: router.libraryPath
        }
    }

    private func wireEvents() {
        app.transfers.onEvent = { [router, app] event in
            let active = UIApplication.shared.applicationState == .active
            switch event {
            case let .ready(transfer):
                if active, router.activeTitle == transfer.pending.tmdbID, app.settings.autoPlayCountdown {
                    router.countdown = transfer
                } else {
                    withAnimation(.snappy) { router.banner = .ready(transfer) }
                }
                if !active { Notifier.ready(transfer) }
            case let .failed(transfer):
                withAnimation(.snappy) { router.banner = .failed(transfer) }
            }
        }
    }
}

private struct TabStack: View {
    let tab: AppTab
    @Binding var path: [CatalogItem]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack(path: $path) {
            root
                // Keeps content clear of the floating tab bar; full-bleed screens ignore it on purpose.
                .safeAreaInset(edge: sizeClass == .compact ? .bottom : .top, spacing: 0) {
                    Color.clear.frame(height: Metrics.tabBarInset(sizeClass))
                }
                .navigationDestination(for: CatalogItem.self) { TitleView(item: $0) }
        }
    }

    @ViewBuilder private var root: some View {
        switch tab {
        case .home: HomeView()
        case .movies: BrowseView(kind: .movie)
        case .tv: BrowseView(kind: .tv)
        case .search: SearchView()
        case .library: LibraryView()
        }
    }
}
```

- [ ] **Step 2: GlassTabBar.swift and ReadyBanner.swift**

```swift
import AMDBKit
import SwiftUI

struct GlassTabBar: View {
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                let selected = router.tab == tab
                Button {
                    if selected { router.popToRoot(tab) } else { router.tab = tab }
                } label: {
                    Group {
                        if sizeClass == .compact {
                            Image(systemName: tab.symbol).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 36)
                        } else {
                            Text(tab.title).font(.subheadline.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                        }
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(0.6))
                    .background { if selected { Capsule().fill(.white.opacity(0.16)) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
            TransferPill()
            Button { router.showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36).foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(5)
        .glassCapsule()
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

private struct TransferPill: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        let active = app.transfers.tracked.filter { !$0.notified }
        if !active.isEmpty {
            let percent = active.map(\.percent).reduce(0, +) / active.count
            Button { router.tab = .library } label: {
                HStack(spacing: 6) {
                    ProgressRing(progress: Double(percent) / 100, lineWidth: 2.5).frame(width: 16, height: 16)
                    Text("\(percent)%").font(.caption.monospacedDigit().weight(.semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("\(active.count) transfers, \(percent) percent")
        }
    }
}
```

`App/iOS/Shell/ReadyBanner.swift`:

```swift
import AMDBKit
import SwiftUI

struct ReadyBanner: View {
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if let banner = router.banner {
            let transfer = banner.transfer
            HStack(spacing: 12) {
                RemoteImage(path: transfer.pending.posterPath, size: "w185", seed: transfer.pending.title)
                    .frame(width: 36, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.pending.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    switch banner {
                    case .ready: Text("Ready to watch").font(.caption).foregroundStyle(.white.opacity(0.7))
                    case .failed: Text(failureText(transfer)).font(.caption).foregroundStyle(Theme.poor).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if case .ready = banner {
                    Button {
                        router.play(transfer)
                        router.banner = nil
                    } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.primaryPill)
                }
                Button { withAnimation { router.banner = nil } } label: {
                    Image(systemName: "xmark").font(.caption.bold()).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .glassRounded(20)
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.top, sizeClass == .compact ? 8 : 72)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: banner.id) {
                try? await Task.sleep(for: .seconds(8))
                if router.banner?.id == banner.id { withAnimation { router.banner = nil } }
            }
        }
    }

    private func failureText(_ transfer: TrackedTransfer) -> String {
        if case let .failed(message) = transfer.phase { return message }
        return "Transfer failed"
    }
}
```

- [ ] **Step 3: PosterCard.swift and CatalogRowView.swift**

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct PosterCard: View {
    let item: CatalogItem
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(path: item.posterPath, size: "w342", seed: item.title)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottomLeading) {
                    if item.posterPath == nil {
                        Text(item.title).font(.caption.weight(.bold)).padding(8).shadow(radius: 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
            Text(item.title).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1).frame(width: width, alignment: .leading)
        }
        .hoverEffect(.lift)
    }
}

struct LibraryPoster: View {
    let entry: LibraryEntry
    let width: CGFloat
    var resumeSeconds: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(path: entry.match?.posterPath, size: "w342", seed: entry.displayTitle)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        if entry.match?.posterPath == nil {
                            Text(entry.displayTitle).font(.caption.weight(.bold)).lineLimit(3)
                        }
                        if resumeSeconds >= 30 {
                            Label(Format.clock(resumeSeconds), systemImage: "play.fill")
                                .font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                        }
                    }
                    .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1).frame(width: width, alignment: .leading)
        }
        .hoverEffect(.lift)
    }

    private var subtitle: String {
        if let match = entry.match, match.mediaType == .tv, let season = match.season {
            return "\(match.title) · S\(season)\(match.episode.map { " E\($0)" } ?? "")"
        }
        return entry.displayTitle
    }
}
```

`App/iOS/Components/CatalogRowView.swift`:

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct CatalogRowView: View {
    let row: CatalogRow
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title).font(.title3.weight(.semibold)).padding(.horizontal, Metrics.gutter(sizeClass))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items) { item in
                        Button { router.open(item) } label: { PosterCard(item: item, width: Metrics.poster(sizeClass)) }
                            .buttonStyle(.lift)
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}

struct EntryRowView: View {
    let title: String
    let entries: [LibraryEntry]
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, Metrics.gutter(sizeClass))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(entries) { entry in
                        let resume = app.library.resumeSeconds(for: entry)
                        Button { router.play(entry, resumeFrom: resume) } label: {
                            LibraryPoster(entry: entry, width: Metrics.poster(sizeClass), resumeSeconds: resume)
                        }
                        .buttonStyle(.lift)
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}
```

- [ ] **Step 4: HeroCarousel.swift**

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct HeroCarousel: View {
    let items: [CatalogItem]
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var index = 0

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                HeroPage(item: item, rank: offset + 1).tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: sizeClass == .compact ? 520 : 640)
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { dot in
                    Capsule().fill(.white.opacity(dot == index ? 1 : 0.35)).frame(width: dot == index ? 14 : 5, height: 4)
                }
            }
            .padding(.trailing, Metrics.gutter(sizeClass)).padding(.bottom, 18)
            .animation(.snappy, value: index)
        }
        .onChange(of: index, initial: true) { _, current in
            if items.indices.contains(current) { ambient.focus(items[current]) }
        }
        .task(id: items.count) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, !items.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
            }
        }
    }
}

private struct HeroPage: View {
    let item: CatalogItem
    let rank: Int
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let regular = sizeClass != .compact
        ZStack(alignment: .bottomLeading) {
            ZStack {
                RemoteImage(path: item.backdropPath, size: "w1280", seed: item.title)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                LinearGradient(colors: [Theme.background.opacity(regular ? 0.8 : 0.35), .clear], startPoint: .leading, endPoint: .trailing)
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 10) {
                Text("#\(rank) TRENDING · \(item.mediaType == .tv ? "SERIES" : "FILM")")
                    .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.white.opacity(0.7))
                Text(item.title.uppercased())
                    .font(.system(size: regular ? 58 : 34, weight: .ultraLight))
                    .tracking(regular ? 5 : 2)
                    .lineLimit(2).minimumScaleFactor(0.6)
                MetaLine(item: item, detail: nil)
                if !item.overview.isEmpty {
                    Text(item.overview).font(.callout).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
                        .frame(maxWidth: 520, alignment: .leading)
                }
                HStack(spacing: 10) {
                    primaryButton
                    Button { router.open(item) } label: { Label("More Info", systemImage: "info.circle") }
                        .buttonStyle(.glassPill)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, 44)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if item.mediaType == .movie, let entry = app.library.matching(tmdbID: item.tmdbID).first {
            let resume = app.library.resumeSeconds(for: entry)
            Button { router.play(entry, resumeFrom: resume) } label: {
                Label(resume >= 30 ? "Resume \(Format.clock(resume))" : "Play", systemImage: "play.fill")
            }
            .buttonStyle(.primaryPill)
        } else {
            Button { router.open(item) } label: { Label("Get & Watch", systemImage: "play.fill") }
                .buttonStyle(.primaryPill)
        }
    }
}

struct MetaLine: View {
    let item: CatalogItem
    let detail: TitleDetail?

    var body: some View {
        HStack(spacing: 8) {
            if let year = item.year { Text(String(year)) }
            if let runtime = Format.runtime(detail?.runtimeMinutes) { Text("·"); Text(runtime) }
            if let rating = item.voteAverage, rating > 0 {
                Text("·")
                Label(String(format: "%.1f", rating), systemImage: "star.fill").labelStyle(.titleAndIcon)
            }
            if app.library.matching(tmdbID: item.tmdbID).isEmpty == false {
                Text("·")
                Label("In put.io", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white.opacity(0.75))
    }

    @Environment(AppModel.self) private var app
}
```

- [ ] **Step 5: HomeView.swift and BrowseView.swift**

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var model: HomeModel?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                if let model, !model.hero.isEmpty {
                    HeroCarousel(items: model.hero)
                } else {
                    Color.clear.frame(height: 160)
                }
                if !app.library.continueWatching.isEmpty {
                    EntryRowView(title: "Continue Watching", entries: app.library.continueWatching)
                }
                if !app.library.recentlyAdded.isEmpty {
                    EntryRowView(title: "Recently Added to put.io", entries: app.library.recentlyAdded)
                }
                ForEach(model?.rows ?? []) { CatalogRowView(row: $0) }
                if let error = model?.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Couldn't load the catalog").font(.headline)
                        Text(String(describing: error)).font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { Task { await model?.load() } }.buttonStyle(.glassPill)
                    }
                    .padding(20).glassRounded().padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 120)
        }
        .ignoresSafeArea(edges: .top)
        .ignoresSafeArea(.keyboard)
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            await model?.load()
            await app.library.refresh()
        }
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let home = HomeModel(catalog: catalog, store: app.store)
            model = home
            await home.load()
        }
    }
}
```

`App/iOS/Home/BrowseView.swift`:

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct BrowseView: View {
    let kind: MediaKind
    @Environment(AppModel.self) private var app
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: BrowseModel?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                Text(kind == .tv ? "TV Shows" : "Movies")
                    .font(.system(size: sizeClass == .compact ? 34 : 48, weight: .ultraLight)).tracking(3)
                    .padding(.horizontal, Metrics.gutter(sizeClass))
                    .padding(.top, 12)
                if model?.isLoading == true && model?.rows.isEmpty == true {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(model?.rows ?? []) { CatalogRowView(row: $0) }
            }
            .padding(.bottom, 120)
        }
        .ignoresSafeArea(.keyboard)
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let browse = BrowseModel(kind: kind, catalog: catalog)
            model = browse
            await browse.load()
            if let first = browse.rows.first?.items.first { ambient.focus(first) }
        }
    }
}
```

- [ ] **Step 6: Stubs for screens built in later tasks**

`App/iOS/Title/TitleView.swift`:

```swift
import AMDBCore
import SwiftUI

struct TitleView: View {
    let item: CatalogItem
    var body: some View { Text(item.title).font(.largeTitle).ambientBackground() }
}
```

`App/iOS/Search/SearchView.swift`:

```swift
import SwiftUI

struct SearchView: View {
    var body: some View { Text("Search").font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity).ambientBackground() }
}
```

`App/iOS/Library/LibraryView.swift`:

```swift
import SwiftUI

struct LibraryView: View {
    var body: some View { Text("Library").font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity).ambientBackground() }
}
```

`App/iOS/Versions/VersionsSheet.swift`:

```swift
import SwiftUI

struct VersionsSheet: View {
    let request: VersionsRequest
    var body: some View { Text("Versions") }
}
```

`App/iOS/Player/PlayerScreen.swift`:

```swift
import SwiftUI

struct PlayerScreen: View {
    let request: PlayerRequest
    var body: some View { Text(request.title) }
}
```

- [ ] **Step 7: Build and screenshot**

```bash
xcodegen generate --quiet && xcodebuild -project AMDB.xcodeproj -scheme AMDB -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath build -quiet build
xcodebuild -project AMDB.xcodeproj -scheme AMDB -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build -quiet build
scripts/shot.sh "iPad Pro 13-inch (M5)" home-ipad -demo
scripts/shot.sh "iPhone 18 Pro" home-iphone -demo
scripts/shot.sh "iPad Pro 13-inch (M5)" movies-ipad -demo -demoScreen movies
```

Expected:
- **iPad:** the glass tab bar floats at the top, and the hero fills the top with a thin uppercase title and a white Play pill. Below it come "Continue Watching" (Interstellar with resume 1:12:40, then Severance), "Recently Added to put.io", and the catalog rows.
- **iPhone:** the tab bar is icon-only at the bottom.

Open each PNG and check it visually. Fix any clipping or overlap before committing.

- [ ] **Step 8: Commit**

```bash
git add App && git commit -m "feat(ios): cinematic shell, glass tab bar, home and browse"
```

---

### Task 3: Title page, Versions sheet, countdown

**Files:**
- Replace: `App/iOS/Title/TitleView.swift`, `App/iOS/Versions/VersionsSheet.swift`
- Create: `App/iOS/Title/ActionViews.swift`, `App/iOS/Title/EpisodeList.swift`, `App/iOS/Title/CountdownOverlay.swift`

**Interfaces:**
- Consumes: `TitleModel`, `TitleAction`, `VersionsModel`, `TransferMonitor.send`, `Router`
- Produces: `PrimaryActions(model:season:episode:)`, `DownloadStatus(transfer:large:)`, `EpisodeActionButton(model:season:episode:next:)` and `CountdownOverlay(transfer:)`

- [ ] **Step 1: TitleView.swift (replace)**

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct TitleView: View {
    let item: CatalogItem
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(AmbientController.self) private var ambient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: TitleModel?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                TitleHeader(item: item, model: model)
                if item.mediaType == .tv, let model { EpisodeList(model: model) }
                if let cast = model?.detail?.cast, !cast.isEmpty { CastRow(cast: cast) }
                if let recommendations = model?.detail?.recommendations, !recommendations.isEmpty {
                    CatalogRowView(row: CatalogRow(id: "more-\(item.id)", title: "More Like This", items: recommendations))
                }
            }
            .padding(.bottom, 120)
        }
        .ignoresSafeArea(edges: .top)
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton() }
        .overlay {
            if let transfer = router.countdown, transfer.pending.tmdbID == item.tmdbID {
                CountdownOverlay(transfer: transfer)
            }
        }
        .onAppear {
            router.activeTitle = item.tmdbID
            ambient.focus(item)
        }
        .onDisappear { if router.activeTitle == item.tmdbID { router.activeTitle = nil } }
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let title = TitleModel(item: item, catalog: catalog, library: app.library, transfers: app.transfers)
            model = title
            await title.load()
        }
    }
}

private struct TitleHeader: View {
    let item: CatalogItem
    let model: TitleModel?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let regular = sizeClass != .compact
        let detail = model?.detail
        ZStack(alignment: .bottomLeading) {
            ZStack {
                RemoteImage(path: item.backdropPath, size: "w1280", seed: item.title)
                    .frame(height: regular ? 620 : 460)
                    .frame(maxWidth: .infinity)
                    .clipped()
                LinearGradient(colors: [Theme.background.opacity(regular ? 0.8 : 0.3), .clear], startPoint: .leading, endPoint: .trailing)
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 12) {
                if let logo = detail?.logoPath {
                    RemoteImage(path: logo, size: "w500", seed: item.title, contentMode: .fit)
                        .frame(maxWidth: regular ? 420 : 260, maxHeight: regular ? 150 : 90, alignment: .leading)
                } else {
                    Text(item.title.uppercased())
                        .font(.system(size: regular ? 54 : 32, weight: .ultraLight)).tracking(regular ? 4 : 2)
                        .lineLimit(3).minimumScaleFactor(0.6)
                }
                MetaLine(item: item, detail: detail)
                Text(detail?.item.overview.isEmpty == false ? detail!.item.overview : item.overview)
                    .font(.callout).foregroundStyle(.white.opacity(0.82)).lineLimit(4)
                if let genres = detail?.genres, !genres.isEmpty {
                    Text(genres.joined(separator: " · ")).font(.caption).foregroundStyle(.white.opacity(0.55))
                }
                if let model, item.mediaType == .movie {
                    PrimaryActions(model: model, season: nil, episode: nil).padding(.top, 6)
                } else if model?.error != nil {
                    Text("Couldn't load details.").font(.footnote).foregroundStyle(Theme.poor)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.bottom, 24)
        }
    }
}

struct BackButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left").font(.headline).frame(width: 40, height: 40).glassCapsule()
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.top, 8)
        .accessibilityLabel("Back")
    }
}

private struct CastRow: View {
    let cast: [CastMember]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast").font(.title3.weight(.semibold)).padding(.horizontal, Metrics.gutter(sizeClass))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(cast, id: \.self) { member in
                        VStack(spacing: 6) {
                            RemoteImage(path: member.profilePath, size: "w185", seed: member.name)
                                .frame(width: 72, height: 72).clipShape(Circle())
                            Text(member.name).font(.caption.weight(.semibold)).lineLimit(1)
                            if let character = member.character {
                                Text(character).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 92)
                    }
                }
                .padding(.horizontal, Metrics.gutter(sizeClass))
            }
        }
    }
}
```

- [ ] **Step 2: ActionViews.swift**

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct PrimaryActions: View {
    let model: TitleModel
    let season: Int?
    let episode: Int?
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 10) {
            switch model.action(season: season, episode: episode) {
            case .get:
                Button { openVersions() } label: { Label("Get & Watch", systemImage: "play.fill") }
                    .buttonStyle(.primaryPill)
            case let .play(entry):
                Button { router.play(entry, resumeFrom: 0) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.primaryPill)
                versionsButton
            case let .resume(entry, seconds):
                Button { router.play(entry, resumeFrom: seconds) } label: {
                    Label("Resume \(Format.clock(seconds))", systemImage: "play.fill")
                }
                .buttonStyle(.primaryPill)
                versionsButton
            case let .downloading(transfer):
                DownloadStatus(transfer: transfer, large: true)
            case let .failed(transfer):
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure(transfer)).font(.footnote).foregroundStyle(Theme.poor)
                    Button {
                        app.transfers.dismiss(transfer.id)
                        openVersions()
                    } label: { Label("Try another version", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.primaryPill)
                }
            }
        }
    }

    private var versionsButton: some View {
        Button { openVersions() } label: { Label("Versions", systemImage: "square.stack.3d.up") }
            .buttonStyle(.glassPill)
    }

    private func openVersions() {
        guard let query = model.query(season: season, episode: episode) else { return }
        router.versions = VersionsRequest(query: query, target: model.target(season: season, episode: episode),
                                          playNow: app.library.matching(tmdbID: model.item.tmdbID, season: season, episode: episode))
    }

    private func failure(_ transfer: TrackedTransfer) -> String {
        if case let .failed(message) = transfer.phase { return message }
        return "Transfer failed"
    }
}

struct DownloadStatus: View {
    let transfer: TrackedTransfer
    var large = false
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: Double(transfer.percent) / 100, lineWidth: large ? 5 : 3,
                             tint: transfer.isStalled ? Theme.okay : .white)
                Text("\(transfer.percent)%").font((large ? Font.callout : .caption2).monospacedDigit().weight(.semibold))
            }
            .frame(width: large ? 64 : 34, height: large ? 64 : 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(large ? .headline : .caption.weight(.semibold))
                Text(details).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                if large {
                    Button("Cancel", role: .destructive) { Task { try? await app.transfers.cancel(transfer.id) } }
                        .font(.caption.weight(.semibold)).padding(.top, 2)
                }
            }
        }
    }

    private var headline: String {
        switch transfer.phase {
        case .queued: "Waiting for put.io"
        case .finishing: "Finishing up"
        case .completed: "Preparing to play"
        default: transfer.isStalled ? "Stalled: no peers" : "put.io is downloading"
        }
    }

    private var details: String {
        guard let live = transfer.transfer else { return "Starting…" }
        let parts = [Format.speed(live.downSpeed), live.peersConnected.map { "\($0) peers" }, Format.eta(live.estimatedTime)]
        let joined = parts.compactMap { $0 }.joined(separator: " · ")
        return transfer.isStalled ? "Try another version if this doesn't move." : (joined.isEmpty ? "Working…" : joined)
    }
}

struct EpisodeActionButton: View {
    let model: TitleModel
    let season: Int
    let episode: Int
    let next: NextEpisode?
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        switch model.action(season: season, episode: episode) {
        case .get:
            iconButton("arrow.down.circle", label: "Get episode") { openVersions() }
        case let .play(entry):
            iconButton("play.circle.fill", label: "Play episode") { router.play(entry, resumeFrom: 0, next: next) }
        case let .resume(entry, seconds):
            iconButton("play.circle.fill", label: "Resume episode") { router.play(entry, resumeFrom: seconds, next: next) }
        case let .downloading(transfer):
            DownloadStatus(transfer: transfer).frame(width: 34)
        case .failed:
            iconButton("exclamationmark.arrow.circlepath", label: "Retry episode") { openVersions() }
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 30, weight: .light)) }
            .buttonStyle(.lift)
            .accessibilityLabel(label)
    }

    private func openVersions() {
        guard let query = model.query(season: season, episode: episode) else { return }
        router.versions = VersionsRequest(query: query, target: model.target(season: season, episode: episode),
                                          playNow: app.library.matching(tmdbID: model.item.tmdbID, season: season, episode: episode))
    }
}
```

- [ ] **Step 3: EpisodeList.swift**

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct EpisodeList: View {
    let model: TitleModel
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let seasons = model.detail?.seasons ?? []
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Menu {
                    ForEach(seasons, id: \.number) { season in
                        Button(season.name) { Task { await model.selectSeason(season.number) } }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(seasons.first { $0.number == model.selectedSeason }?.name ?? "Season").font(.title3.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption.bold())
                    }
                    .foregroundStyle(.white)
                }
                Spacer()
                if let season = model.selectedSeason {
                    seasonButton(season)
                }
            }
            ForEach(model.episodes) { episode in
                if let season = model.selectedSeason {
                    EpisodeRow(model: model, season: season, episode: episode, next: nextEpisode(after: episode.number, in: season))
                }
            }
        }
        .padding(.horizontal, Metrics.gutter(sizeClass))
    }

    @ViewBuilder private func seasonButton(_ season: Int) -> some View {
        switch model.action(season: season, episode: nil) {
        case let .downloading(transfer):
            DownloadStatus(transfer: transfer)
        default:
            Button {
                guard let query = model.query(season: season) else { return }
                router.versions = VersionsRequest(query: query, target: model.target(season: season), playNow: [])
            } label: { Label("Get season", systemImage: "square.stack.3d.down.right") }
            .buttonStyle(.glassPill)
        }
    }

    private func nextEpisode(after number: Int, in season: Int) -> NextEpisode? {
        guard model.episodes.contains(where: { $0.number == number + 1 }) else { return nil }
        return NextEpisode(query: model.query(season: season, episode: number + 1),
                           target: model.target(season: season, episode: number + 1),
                           label: "S\(season) · E\(number + 1)")
    }
}

private struct EpisodeRow: View {
    let model: TitleModel
    let season: Int
    let episode: Episode
    let next: NextEpisode?
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let regular = sizeClass != .compact
        let resume = app.library.matching(tmdbID: model.item.tmdbID, season: season, episode: episode.number)
            .map { app.library.resumeSeconds(for: $0) }.max() ?? 0
        HStack(alignment: .center, spacing: 14) {
            RemoteImage(path: episode.stillPath, size: "w300", seed: "\(model.item.title) \(episode.number)")
                .frame(width: regular ? 220 : 128, height: regular ? 124 : 72)
                .overlay(alignment: .bottomLeading) {
                    if resume >= 30 {
                        Label(Format.clock(resume), systemImage: "play.fill").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.6), in: Capsule()).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.number). \(episode.name)").font(.headline).lineLimit(1)
                if let runtime = Format.runtime(episode.runtimeMinutes) {
                    Text(runtime).font(.caption).foregroundStyle(.white.opacity(0.55))
                }
                if regular, !episode.overview.isEmpty {
                    Text(episode.overview).font(.footnote).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            EpisodeActionButton(model: model, season: season, episode: episode.number, next: next)
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}
```

- [ ] **Step 4: CountdownOverlay.swift**

```swift
import AMDBKit
import SwiftUI

struct CountdownOverlay: View {
    let transfer: TrackedTransfer
    @Environment(Router.self) private var router
    @State private var remaining = 5

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    ProgressRing(progress: Double(5 - remaining) / 5, lineWidth: 5)
                    Text("\(remaining)").font(.system(size: 34, weight: .ultraLight)).monospacedDigit()
                }
                .frame(width: 88, height: 88)
                Text("\(transfer.pending.title) is ready").font(.title3.weight(.semibold))
                Text("Starting…").foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 12) {
                    Button { start() } label: { Label("Play Now", systemImage: "play.fill") }.buttonStyle(.primaryPill)
                    Button("Cancel") { router.countdown = nil }.buttonStyle(.glassPill)
                }
            }
            .padding(32)
            .glassRounded(28)
        }
        .transition(.opacity)
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, router.countdown?.id == transfer.id else { return }
                remaining -= 1
            }
            start()
        }
    }

    private func start() {
        guard router.countdown?.id == transfer.id else { return }
        router.countdown = nil
        router.play(transfer)
    }
}
```

- [ ] **Step 5: VersionsSheet.swift (replace)**

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct VersionsSheet: View {
    let request: VersionsRequest
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: VersionsModel?
    @State private var sendingID: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !request.playNow.isEmpty {
                        Text("Already in your put.io").font(.headline)
                        ForEach(request.playNow) { entry in
                            Button {
                                dismiss()
                                router.play(entry, resumeFrom: app.library.resumeSeconds(for: entry))
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Theme.good)
                                    Text(entry.file.name).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer()
                                    Text("Play now").font(.caption.weight(.bold))
                                }
                                .padding(12)
                                .background(Theme.good.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.bottom, 8)
                    }
                    if let model {
                        FilterBar(model: model)
                        ForEach(model.failures, id: \.providerID) { failure in
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.okay)
                                Text("\(failure.providerID) didn't answer").font(.caption)
                                Spacer()
                                Button("Retry") { model.start() }.font(.caption.weight(.bold))
                            }
                            .padding(10)
                            .background(Theme.okay.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        }
                        ForEach(model.rows) { release in
                            Button { send(release) } label: {
                                ReleaseRow(release: release, inPutio: model.isInPutio(release), sending: sendingID == release.id)
                            }
                            .buttonStyle(.plain)
                            .disabled(sendingID != nil)
                        }
                        if model.isLoading {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Searching \(model.snapshot.pendingProviders.count) sources…").font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                        } else if model.rows.isEmpty {
                            VStack(spacing: 8) {
                                Text("No versions found").font(.headline)
                                Text("Try again, turn on more sources in Settings, or use a VPN if some sites are blocked where you are.")
                                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Search again") { model.start() }.buttonStyle(.glassPill)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                }
                .padding(Metrics.gutter(sizeClass) / 2 + 8)
            }
            .background(Theme.sheet)
            .navigationTitle("Choose a version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if let model {
                    ToolbarItem(placement: .primaryAction) { SortMenu(model: model) }
                }
            }
            .alert("Couldn't send to put.io", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
        .presentationDetents(sizeClass == .compact ? [.medium, .large] : [.large])
        .presentationBackground(Theme.sheet)
        .task {
            guard model == nil else { return }
            let hashes = await app.completedHashes()
            let versions = VersionsModel(query: request.query, searcher: app.releaseSearcher, playNow: request.playNow,
                                         completedHashes: hashes,
                                         defaultResolution: app.settings.defaultResolution.flatMap(Resolution.init(rawValue:)))
            model = versions
            versions.start()
        }
        .onDisappear { model?.cancel() }
    }

    private func send(_ release: Release) {
        guard sendingID == nil else { return }
        sendingID = release.id
        let target = request.target ?? TransferTarget(
            tmdbID: 0, kind: release.parsed.season == nil ? .movie : .tv,
            title: release.parsed.title.isEmpty ? release.name : release.parsed.title,
            posterPath: nil, backdropPath: nil, season: release.parsed.season, episode: release.parsed.episode)
        Task {
            do {
                try await app.transfers.send(release, target: target)
                dismiss()
            } catch {
                errorText = String(describing: error)
                sendingID = nil
            }
        }
    }
}

private struct FilterBar: View {
    @Bindable var model: VersionsModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: model.resolution == nil) { model.resolution = nil }
                ForEach(model.availableResolutions, id: \.self) { resolution in
                    chip(resolution == .uhd2160 ? "4K" : resolution.label, selected: model.resolution == resolution) {
                        model.resolution = resolution
                    }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(selected ? .black : .white)
                .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SortMenu: View {
    @Bindable var model: VersionsModel

    var body: some View {
        Menu {
            Picker("Sort", selection: $model.sort) {
                Text("Seeders").tag(ReleaseSort.seeders)
                Text("Size").tag(ReleaseSort.size)
                Text("Quality").tag(ReleaseSort.quality)
            }
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
    }
}

struct ReleaseRow: View {
    let release: Release
    let inPutio: Bool
    let sending: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(release.parsed.resolution == .unknown ? "?" : (release.parsed.resolution == .uhd2160 ? "4K" : release.parsed.resolution.label))
                .font(.caption.monospaced().weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.45)))
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(release.name).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                FlowLayout(spacing: 5) {
                    ForEach(release.sources.sorted(), id: \.self) { tag in
                        Text(tag.label).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((tag.kind == .chill ? Color.red : Color.blue).opacity(0.22), in: Capsule())
                    }
                    ForEach(release.parsed.hdr, id: \.self) { flag in
                        Text(flag).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    if inPutio {
                        Text("IN PUT.IO").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.good.opacity(0.25), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Format.bytes(release.sizeBytes)).font(.caption.monospacedDigit())
                HStack(spacing: 4) {
                    Circle().fill(Theme.seeders(release.seeders)).frame(width: 7, height: 7)
                    Text(release.seeders.map(String.init) ?? "?").font(.caption.monospacedDigit())
                }
            }
            if sending { ProgressView().padding(.leading, 4) }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 6: Build and screenshot**

```bash
xcodegen generate --quiet && xcodebuild -project AMDB.xcodeproj -scheme AMDB -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath build -quiet build
scripts/shot.sh "iPad Pro 13-inch (M5)" title-ipad -demo -demoScreen title
scripts/shot.sh "iPad Pro 13-inch (M5)" show-ipad -demo -demoScreen show
SHOT_DELAY=8 scripts/shot.sh "iPad Pro 13-inch (M5)" versions-ipad -demo -demoScreen versions
```

Expected:
- **Title:** a big title over the seeded backdrop, metadata, a "Get & Watch" pill, cast circles, and "More Like This".
- **Show:** a season menu, "Get season", and episode rows with download icons.
- **Versions:** a sheet with filter chips, rows carrying quality badges, source tags in chill red and direct blue, sizes, and colored seeder dots.

Open each PNG and check it visually.

- [ ] **Step 7: Commit**

```bash
git add App && git commit -m "feat(ios): title page, episode list, versions sheet, countdown"
```

---

### Task 4: Search and Library

**Files:**
- Replace: `App/iOS/Search/SearchView.swift`, `App/iOS/Library/LibraryView.swift`

**Interfaces:**
- Consumes: `SearchModel`, `LibraryCard`, `LibraryFilter`, `TransferMonitor`, `DownloadStatus`

- [ ] **Step 1: SearchView.swift (replace)**

```swift
import AMDBCore
import AMDBKit
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SearchModel?
    @State private var trending: [CatalogItem] = []

    var body: some View {
        Group {
            if let model { SearchContent(model: model, trending: trending) } else { Color.clear }
        }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard model == nil, let catalog = app.catalog else { return }
            let search = SearchModel(catalog: catalog, store: app.store)
            model = search
            await search.loadRecent()
            trending = ((try? await catalog.trending(nil)) ?? []).filter { $0.mediaType != .person }
        }
    }
}

private struct SearchContent: View {
    @Bindable var model: SearchModel
    let trending: [CatalogItem]
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var focused: Bool

    var body: some View {
        let compact = sizeClass == .compact
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                    TextField("Movies, shows, people", text: $model.query)
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await model.commit() } }
                        .font(.title3)
                    if model.isSearching { ProgressView() }
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .glassRounded(22)

                if let releaseQuery = model.releaseQuery {
                    Button {
                        Task { await model.commit() }
                        router.versions = VersionsRequest(query: releaseQuery, target: nil, playNow: [])
                    } label: {
                        Label("Search releases for “\(model.query.trimmingCharacters(in: .whitespaces))”", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassPill)

                    if compact {
                        suggestions
                        grid(model.grid)
                    } else {
                        HStack(alignment: .top, spacing: 28) {
                            suggestions.frame(width: 260)
                            grid(model.grid)
                        }
                    }
                    if model.results.isEmpty && !model.isSearching {
                        Text("No titles match. Try “Search releases” for anything TMDB doesn't know.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    if !model.recent.isEmpty {
                        Text("Recent").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.recent, id: \.self) { recent in
                                    Button(recent) { model.query = recent }
                                        .font(.subheadline)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(.white.opacity(0.1), in: Capsule())
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !trending.isEmpty {
                        Text("Popular searches").font(.headline)
                        grid(trending)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focused = true }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top suggestions").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(model.suggestions) { item in
                Button { open(item) } label: {
                    HStack(spacing: 10) {
                        RemoteImage(path: item.posterPath, size: "w92", seed: item.title)
                            .frame(width: 30, height: 45).clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text([item.year.map(String.init), item.mediaType == .tv ? "Series" : "Film"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func grid(_ items: [CatalogItem]) -> some View {
        let width = Metrics.poster(sizeClass)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 30), spacing: 12, alignment: .top)],
                         alignment: .leading, spacing: 18) {
            ForEach(items) { item in
                Button { open(item) } label: { PosterCard(item: item, width: width) }
                    .buttonStyle(.lift)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.snappy(duration: 0.25), value: items.map(\.id))
    }

    private func open(_ item: CatalogItem) {
        Task { await model.commit() }
        router.open(item)
    }
}
```

- [ ] **Step 2: LibraryView.swift (replace)**

```swift
import AMDBCore
import AMDBKit
import SwiftUI

extension LibraryFilter {
    var title: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .tv: "TV"
        case .other: "Other"
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var filter: LibraryFilter = .all

    var body: some View {
        let cards = LibraryCard.cards(from: app.library.entries, filter: filter)
        let width = Metrics.poster(sizeClass)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Text("Library").font(.system(size: sizeClass == .compact ? 34 : 48, weight: .ultraLight)).tracking(3)
                if !app.transfers.tracked.isEmpty {
                    Text("Transfers").font(.title3.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) { ForEach(app.transfers.tracked) { TransferCard(transfer: $0) } }
                    }
                }
                Picker("Filter", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                if cards.isEmpty {
                    if app.library.isRefreshing {
                        ProgressView("Reading your put.io…").frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        Text(app.library.lastError == nil ? "Nothing here yet." : "Couldn't read your put.io files. Pull to retry.")
                            .foregroundStyle(.secondary).padding(.top, 40)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 30), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(cards) { LibraryCardView(card: $0, width: width) }
                }
            }
            .padding(.horizontal, Metrics.gutter(sizeClass))
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .refreshable { await app.library.refresh() }
        .ambientBackground()
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct LibraryCardView: View {
    let card: LibraryCard
    let width: CGFloat
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        switch card {
        case let .movie(entry), let .file(entry):
            let resume = app.library.resumeSeconds(for: entry)
            Button { router.play(entry, resumeFrom: resume) } label: {
                LibraryPoster(entry: entry, width: width, resumeSeconds: resume)
            }
            .buttonStyle(.lift)
        case let .show(tmdbID, title, posterPath, episodes):
            Button {
                router.open(CatalogItem(tmdbID: tmdbID, mediaType: .tv, title: title, posterPath: posterPath,
                                        backdropPath: episodes.first?.match?.backdropPath))
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    RemoteImage(path: posterPath, size: "w342", seed: title)
                        .frame(width: width, height: width * 1.5)
                        .overlay(alignment: .topTrailing) {
                            Text("\(episodes.count)").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: Capsule()).padding(6)
                        }
                        .overlay(alignment: .bottomLeading) {
                            if posterPath == nil { Text(title).font(.caption.weight(.bold)).padding(8) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(title).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1).frame(width: width, alignment: .leading)
                }
                .hoverEffect(.lift)
            }
            .buttonStyle(.lift)
        }
    }
}

private struct TransferCard: View {
    let transfer: TrackedTransfer
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(path: transfer.pending.posterPath, size: "w185", seed: transfer.pending.title)
                .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(transfer.pending.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if transfer.playableFile != nil {
                    Button { router.play(transfer) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.primaryPill)
                } else {
                    DownloadStatus(transfer: transfer)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if transfer.notified {
                    Button("Dismiss") { app.transfers.dismiss(transfer.id) }
                } else {
                    Button("Cancel transfer", role: .destructive) { Task { try? await app.transfers.cancel(transfer.id) } }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
        }
        .padding(12)
        .frame(width: 320)
        .glassRounded(16)
    }
}
```

- [ ] **Step 3: Build and screenshot**

```bash
xcodegen generate --quiet && xcodebuild -project AMDB.xcodeproj -scheme AMDB -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath build -quiet build
scripts/shot.sh "iPad Pro 13-inch (M5)" search-ipad -demo -demoScreen search
scripts/shot.sh "iPad Pro 13-inch (M5)" library-ipad -demo -demoScreen library
```

Expected:
- **Search:** a glass search field, recent chips (empty on first run), and the "Popular searches" grid.
- **Library:** the thin "Library" title, the segmented filter, posters for Interstellar, Past Lives and Heat, a Severance show card with a count badge, and the "Home Video" file card.

Open the PNGs and check them visually.

- [ ] **Step 4: Commit**

```bash
git add App && git commit -m "feat(ios): live search and put.io library"
```

---

### Task 5: Player

**Files:**
- Replace: `App/iOS/Player/PlayerScreen.swift`

**Interfaces:**
- Consumes: `PlaybackSession`, `PlayerRequest`, `NextEpisode`, `AppModel.notePlayed`, `PutioService.originalURL`

- [ ] **Step 1: PlayerScreen.swift (replace)**

```swift
import AMDBCore
import AMDBKit
import AVKit
import SwiftUI

struct PlayerScreen: View {
    let request: PlayerRequest
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var session: PlaybackSession?
    @State private var askingResume = false
    @State private var ready = false
    @State private var remaining = Double.infinity
    @State private var failure: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayerController(player: player).ignoresSafeArea()
            if !ready && failure == nil && !askingResume {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("put.io is preparing this video…").font(.footnote).foregroundStyle(.white.opacity(0.7))
                }
            }
            if askingResume {
                VStack(spacing: 14) {
                    Text(request.title).font(.headline)
                    Button { begin(at: Double(request.resumeFrom)) } label: {
                        Label("Resume from \(Format.clock(request.resumeFrom))", systemImage: "play.fill")
                    }
                    .buttonStyle(.primaryPill)
                    Button("Start over") { begin(at: 0) }.buttonStyle(.glassPill)
                }
                .padding(28)
                .glassRounded(24)
            }
            if let failure {
                VStack(spacing: 14) {
                    Text(failure).multilineTextAlignment(.center)
                    Link("Open in put.io", destination: URL(string: "https://app.put.io/files/\(request.file.id)")!)
                        .buttonStyle(.glassPill)
                }
                .padding(28)
                .glassRounded(24)
                .padding(40)
            }
            if let next = request.next, remaining < 30 {
                Button { advance(to: next) } label: { Label("Next: \(next.label)", systemImage: "forward.end.fill") }
                    .buttonStyle(.primaryPill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 40).padding(.bottom, 110)
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40).glassCapsule()
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Close player")
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await setUp() }
        .task { await trackProgress() }
        .onDisappear { finish() }
    }

    private func setUp() async {
        guard let putio = app.putio else { return }
        let playback = PlaybackSession(fileID: request.file.id, resumeFrom: request.resumeFrom, putio: putio, library: app.library)
        session = playback
        if let played = request.played { await app.notePlayed(played) }
        player.replaceCurrentItem(with: AVPlayerItem(url: playback.streamURL))
        if playback.shouldOfferResume { askingResume = true } else { begin(at: 0) }

        for _ in 0..<60 {
            switch player.currentItem?.status {
            case .readyToPlay:
                ready = true
                return
            case .failed:
                break
            default:
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            break
        }
        if request.file.contentType == "video/mp4", let original = try? await putio.originalURL(fileID: request.file.id) {
            player.replaceCurrentItem(with: AVPlayerItem(url: original))
            if !askingResume { begin(at: Double(request.resumeFrom)) }
            ready = true
        } else {
            failure = "put.io couldn't stream this file yet. It may still be converting. Try again in a few minutes."
        }
    }

    private func begin(at seconds: Double) {
        askingResume = false
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        player.play()
    }

    private func trackProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let position = player.currentTime().seconds
            guard position.isFinite, position > 0 else { continue }
            let duration = player.currentItem?.duration.seconds ?? 0
            let total = duration.isFinite ? duration : 0
            remaining = total > 0 ? total - position : .infinity
            await session?.tick(seconds: position, duration: total)
        }
    }

    private func finish() {
        player.pause()
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        guard let session, position.isFinite, position > 0 else { return }
        Task { await session.finish(seconds: position, duration: duration.isFinite ? duration : 0) }
    }

    private func advance(to next: NextEpisode) {
        dismiss()
        let library = app.library
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if let entry = library.matching(tmdbID: next.target.tmdbID, season: next.target.season, episode: next.target.episode).first {
                router.play(entry, resumeFrom: library.resumeSeconds(for: entry))
            } else if let query = next.query {
                router.versions = VersionsRequest(query: query, target: next.target, playNow: [])
            }
        }
    }
}

private struct VideoPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
```

- [ ] **Step 2: Build, then screenshot the player through the demo countdown flow**

```bash
xcodegen generate --quiet && xcodebuild -project AMDB.xcodeproj -scheme AMDB -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath build -quiet build
SHOT_DELAY=8 scripts/shot.sh "iPad Pro 13-inch (M5)" library-again -demo -demoScreen library
```

Expected: the build succeeds. Playback itself is verified manually in the simulator:
1. Launch with `-demo`.
2. Tap Interstellar in Continue Watching. Expect the "Resume from 1:12:40 / Start over" prompt, then the Apple bipbop test stream playing.
3. Open a title, tap Get & Watch, and pick a version. Expect the progress ring for about 8 s, then the 5-second countdown, then the player.

- [ ] **Step 3: Commit**

```bash
git add App && git commit -m "feat(ios): native player with resume, put.io progress sync, next episode"
```

---

### Task 6: iPhone pass and run instructions

**Files:**
- Create: `README.md`
- Modify: any view whose iPhone screenshot shows clipping, following the checklist below.

- [ ] **Step 1: iPhone screenshots**

```bash
xcodebuild -project AMDB.xcodeproj -scheme AMDB -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build -quiet build
for screen in home title show search library; do
  scripts/shot.sh "iPhone 18 Pro" "iphone-$screen" -demo -demoScreen $screen
done
SHOT_DELAY=8 scripts/shot.sh "iPhone 18 Pro" iphone-versions -demo -demoScreen versions
```

Check each PNG against this list:
- The tab bar sits at the bottom and is icon-only.
- The hero title doesn't clip.
- Episode rows fit, with a 128 pt still.
- The Versions sheet opens at the medium detent.
- The search suggestions stack above the grid.

Fix any deviation in the relevant view, keeping the iPad layout unchanged. Rebuild, then re-shoot both the iPad and iPhone versions of that screen.

- [ ] **Step 2: README.md**

````markdown
# AMDB

Personal iPad, iPhone and (soon) Apple TV app: browse with TMDB, find releases across chill and direct sources, send them to put.io, and watch with progress synced to put.io.

## Run

```bash
brew install xcodegen          # once
xcodegen generate              # after every pull
open AMDB.xcodeproj            # pick an iPad or iPhone simulator, ⌘R
```

First launch asks for:
1. **put.io**: "Sign in with put.io" (OAuth app "AMDB", client 9877).
2. **TMDB**: an API Read Access Token from themoviedb.org → Settings → API.
3. **chill** (optional): sign in through chill's own page, or paste a chilly token.

### Demo mode

Launch with `-demo` (Xcode: Product → Scheme → Edit Scheme → Arguments) to use built-in sample data without accounts.
Add `-demoScreen title|show|versions|search|library|movies` to open a screen directly.

## Layout

- `AMDBCore/`: Swift package with `AMDBCore` (clients, sources, parser) and `AMDBKit` (app state, view models). Run `swift test` there.
- `App/iOS/`: SwiftUI app.
- `docs/superpowers/`: design spec and implementation plans.
````

- [ ] **Step 3: Full verification**

```bash
(cd AMDBCore && swift test 2>&1 | grep -E "Test run with")
xcodegen generate --quiet && xcodebuild -project AMDB.xcodeproj -scheme AMDB -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath build build 2>&1 | grep -cE "warning:|error:"
```

Expected: both test runs pass, and the warning/error count is `0`. Any warning has to be fixed before the commit.

- [ ] **Step 4: Commit**

```bash
git add README.md App && git commit -m "docs: run instructions; fix(ios): compact layout pass"
```
