# Architecture

Putio & Chill is one Swift package holding all the logic, and thin, platform-native SwiftUI apps on top of it.

```
┌──────────────── App targets ────────────────┐
│ Putio & Chill (iOS/iPadOS)   AMDBTV (tvOS)            │  SwiftUI views, navigation, players,
│ AMDBWidgets         AMDBTopShelf             │  system integrations
│ App/SharedUI (used by both apps)             │
└──────────────────────┬──────────────────────┘
                       │
┌──────────────── AMDBKit ────────────────────┐
│ AppModel · LibraryIndex · TransferMonitor    │  App state and view models
│ TitleModel · HomeModel · ChillFeed · …       │  (@Observable, @MainActor)
└──────────────────────┬──────────────────────┘
                       │
┌──────────────── AMDBCore ───────────────────┐
│ PutioClient · CatalogClient (TMDB)           │  Networking, API clients,
│ TraktClient · RatingsClient · OpenSubtitles  │  release sources, parsing
│ Release providers · ReleaseNameParser        │  (Sendable structs and actors)
└─────────────────────────────────────────────┘
```

- **Swift 6** with strict concurrency throughout. View models are `@Observable @MainActor`; clients are `Sendable`
  structs or actors; disk stores are actors.
- **XcodeGen**: `project.yml` describes every target; `AMDB.xcodeproj` and the targets' `Info.plist` files are generated
  (and gitignored), so build settings live in one reviewable file.

## Modules

### AMDBCore (`AMDBCore/Sources/AMDBCore`)

| Folder | What's in it |
|---|---|
| `Networking/` | `HTTPTransport` (URLSession), `HTTPRequester` with typed errors (`AppError`) |
| `Putio/` | put.io API: files, transfers, streaming URLs (HLS), subtitles, account, OAuth device codes |
| `Catalog/` | TMDB: search, details, seasons, people, collections, discover, now playing / upcoming, keywords, images |
| `Charts/` | Trakt: IMDb Top 250 lists and the weekend box office; IMDb trailers |
| `Ratings/` | MDBList ratings; IMDb per-episode ratings |
| `Providers/` | Release sources (chill, YTS, EZTV, apibay, Knaben, Torrents.csv, TorrentGalaxy), chill's catalog lists, MyMoviz |
| `Search/` | `LiveSearchEngine`: debounced, cancellable catalog search |
| `Parsing/` | `ReleaseNameParser`: title, year, season/episode, resolution, codec from release and file names |
| `Library/` | `LibraryMatcher`: matches put.io file names to TMDB titles with a confidence score |
| `Subtitles/` | OpenSubtitles client, SRT/VTT parsing, the OpenSubtitles file hash |
| `Transfers/` | Transfer phases and stall detection |

### AMDBKit (`AMDBCore/Sources/AMDBKit`)

| Type | Role |
|---|---|
| `AppModel` | Root object: settings, tokens, services (built by `ServiceFactory`), and the long-lived models below |
| `ReleaseAggregator` | Asks every enabled release source in parallel and merges the results into one ranked list |
| `LibraryIndex` | Walks put.io, matches files to TMDB, caches the result, tracks progress and Continue Watching |
| `TransferMonitor` | Sends releases to put.io, polls transfers, reports ready / failed events |
| `TitleModel` | A title page: details, ratings, seasons, episode ratings, and which action to show |
| `HomeModel`, `BrowseModel`, `SearchModel`, `ChartModel`, `ComingUpModel` | Screen models |
| `CuratedLists` | TMDB discover filters for New on Netflix, Returning This Week, … |
| `ChillFeed` | Latest Movies / Shows: chill + MyMoviz, merged, matched, cached |
| `SurpriseModel`, `AskSearch` | Surprise Me and Ask Chill |
| `SubtitleFinder` | put.io tracks + OpenSubtitles, timing, per-file choice |
| `PlaybackSession` | Progress sync to put.io while playing |
| `LibraryOrganizer`, `PutioPaths` | Folder layout and Organize library |
| `DownloadsIndex`, `AutoCleaner` | Offline download records and auto-clean |
| `LocalStore`, `LibraryCache`, `RatingsCache` | On-disk state |
| `DeepLink`, `SleepTimer`, `StorageLocation` | Small shared pieces |

### Apps

- `App/iOS`: iPhone and iPad. `MainView` hosts one `NavigationStack` per tab; `Router` owns tab, paths and modal
  state. Player is UIKit (`PlayerViewController` + `AVPlayerLayer`) with SwiftUI controls on top.
- `App/tvOS`: Apple TV. `TVRootView` hosts a `TabView`; `TVRouter` owns navigation. Player is `AVPlayerViewController`
  with custom transport-bar menus.
- `App/SharedUI`: artwork loading (`RemoteImage`, `ImagePipeline`), theme, ratings badges, demo mode.
- `App/Widgets`: Continue Watching widget, transfer Live Activity, Surprise Me control.
- `App/TopShelf` + `App/TVShared`: Apple TV Top Shelf.

## Services and testability

Every external service sits behind a protocol in AMDBKit (`PutioService`, `CatalogService`, `ChartsService`,
`RatingsService`, `SubtitleService`, `ChillCatalogService`, `LatestTitlesSource`, …). `ServiceFactory.live` builds the
real clients; tests and demo mode pass fakes. Network clients take an `HTTPTransport`, so tests replay canned
responses with `StubTransport`.

## Data flow examples

**Opening the app**
1. `LibraryIndex.loadCached()` shows the saved library immediately.
2. `refreshLibraryIfDue()` re-walks put.io if the cache is older than the user's interval.
3. New files are matched to TMDB (six at a time) and appear once matched.
4. `ChillFeed` refreshes Latest Movies / Shows; screen models load TMDB rows.

**Get & Watch**
1. `TitleModel` builds a query (IMDb id, title, year, season/episode).
2. `ReleaseAggregator` asks every enabled source in parallel and ranks the results.
3. `AppModel.smartGet` picks a release by the Smart Get rule; `TransferMonitor.send` adds it to put.io in the right
   folder.
4. `TransferMonitor` polls until put.io has a playable file, then emits `.ready`; the UI offers Play.

**Playing**
1. The player streams put.io's HLS URL (or plays a downloaded copy).
2. `PlaybackSession` saves progress locally and to put.io (`start_from`), so resume works on every device.
3. `SubtitleFinder` restores the file's subtitle choice and draws it in the chosen style.

## Caching and refresh

| Data | Stored | Refreshed |
|---|---|---|
| put.io library + matches + folder tree | `library.json`, `state.json` | At launch / return if older than the Settings interval (default 1 h); Update Now; iPhone checks every minute while open |
| Latest Movies / Shows | `chill-feed.json` (lists, matches) | Every time the app opens; chill's settings-switch fallback at most every 6 h |
| Ratings | `ratings-v2.json` | After 7 days |
| Subtitles | `Subtitles/` | Kept (re-watching never spends another download) |
| TMDB rows, Coming Up, Top 250 | memory | When the app starts |
| Artwork | URL cache | System-managed |

**Where files live** (`StorageLocation`): Application Support on iPhone/iPad. On Apple TV, apps may only write to
Caches, so tvOS uses Caches; because tvOS can clear Caches when space runs low, **My List** is also backed up in a
UserDefaults suite (`app.amdb.backup`).

## App Group and extensions

The iOS app, widgets and the Apple TV app/Top Shelf share the App Group **`group.app.amdb`**:

- Continue Watching items and artwork for the widget.
- `topshelf.json`, written by the TV app and read by the Top Shelf extension.
- A pending deep link handed from the Control Center control to the app.

## Platform notes

- iOS deployment target 17; newer features are availability-gated: Control Center control and Spotlight indexing
  (iOS 18), Liquid Glass and Ask Chill (iOS 26).
- Offline downloads use `AVAssetDownloadURLSession` (HLS). Paths are stored relative to the app container and
  resolved at use, because the container moves between app updates.
- On Apple TV the stream has no embedded subtitles; the app draws put.io and OpenSubtitles text itself so style and
  timing apply to all of them.
