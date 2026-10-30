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
│ TitleModel · HomeModel · LatestFeed · …      │  (@Observable, @MainActor)
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
| `Providers/` | Release sources (YTS, EZTV, apibay, Knaben, Torrents.csv, TorrentGalaxy), MyMoviz's latest lists |
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
| `LibraryIndex` | Walks put.io (what `LibraryScope` covers), matches files to TMDB, caches the result, tracks progress and Continue Watching |
| `TransferMonitor` | Sends releases to put.io, polls transfers, reports ready / failed events |
| `TitleModel` | A title page: details, ratings, seasons, episode ratings, and which action to show |
| `HomeModel`, `BrowseModel`, `SearchModel`, `ChartModel`, `ComingUpModel` | Screen models |
| `CuratedLists` | TMDB discover filters for New on Netflix, Returning This Week, … |
| `NewReleases` | New to Stream (movies out on digital or disc in the device's region, last 45 days) and New Episodes This Week, from TMDB |
| `LatestFeed` | Latest Movies / Shows: MyMoviz's newest, matched to TMDB, cached |
| `RetiredData` | Deletes what removed features left behind (an old Keychain item and cache file), once |
| `SurpriseModel`, `AskSearch` | Surprise Me and Ask Chill |
| `SubtitleFinder` | put.io tracks + OpenSubtitles, timing, per-file choice |
| `PlaybackSession` | Progress sync to put.io while playing |
| `LibraryOrganizer`, `PutioPaths` | Folder layout (`DefaultFolders`: Movies, TV Series) and Organize library |
| `LibraryScope` | What the library reads: Movies, TV Series, picked folders, loose top-level videos |
| `FolderMergePlanner`, `OldFolderMerge` | One-time merge of the old AMDB/Movies and AMDB/TV folders (pure plan, then put.io calls) |
| `DownloadsIndex`, `AutoCleaner` | Offline download records and auto-clean |
| `LocalStore`, `LibraryCache`, `RatingsCache` | On-disk state |
| `DeepLink`, `SleepTimer`, `StorageLocation` | Small shared pieces |

### Apps

- `App/iOS`: iPhone and iPad. `MainView` hosts one `NavigationStack` per tab; `Router` owns tab, paths and modal
  state. Player is UIKit (`PlayerViewController`) with SwiftUI controls on top; the picture comes from a
  `PlayerBackend` in `App/PlayerCore`: Apple's player (`AVPlayerBackend`) or the built-in one (`AetherBackend`).
- `App/tvOS`: Apple TV. `TVRootView` hosts a `TabView`; `TVRouter` owns navigation. Player is `AVPlayerViewController`
  with custom transport-bar menus, or `TVBuiltInPlayerController` (our transport bar and swipe-down menus) when the
  built-in player plays the video.
- `App/PlayerCore`: shared by both apps. `PlayerEngine` publishes playback state for our controls whichever player
  plays; `AetherBackend` wraps AetherEngine (FFmpeg) for videos Apple's player can't play. Not in the Mac app
  (AetherEngine's FFmpeg build has no Mac Catalyst slice).
- `App/SharedUI`: artwork loading (`RemoteImage`, `ImagePipeline`), theme, ratings badges, demo mode.
- `App/Widgets`: Continue Watching widget, transfer Live Activity, Surprise Me control.
- `App/TopShelf` + `App/TVShared`: Apple TV Top Shelf.

## Services and testability

Every external service sits behind a protocol in AMDBKit (`PutioService`, `CatalogService`, `ChartsService`,
`RatingsService`, `SubtitleService`, `LatestTitlesSource`, …). `ServiceFactory.live` builds the
real clients; tests and demo mode pass fakes. Network clients take an `HTTPTransport`, so tests replay canned
responses with `StubTransport`.

## Data flow examples

**Opening the app**
1. `LibraryIndex.loadCached()` shows the saved library immediately.
2. `mergeOldFoldersIfNeeded()` merges AMDB/Movies and AMDB/TV into Movies and TV Series (once per account).
3. `refreshLibraryIfDue()` re-walks put.io if the cache is older than the user's interval (or was read with another
   `LibraryScope`).
4. New files are matched to TMDB (six at a time) and appear once matched.
5. `LatestFeed` refreshes Latest Movies / Shows; screen models load TMDB rows (New to Stream / New Episodes This Week
   included).

**Get & Watch**
1. `TitleModel` builds a query (IMDb id, title, year, season/episode).
2. `ReleaseAggregator` asks every enabled source in parallel and ranks the results.
3. `AppModel.smartGet` picks a release by the Smart Get rule; `TransferMonitor.send` adds it to put.io in the right
   folder.
4. `TransferMonitor` polls until put.io has a playable file, then emits `.ready`; the UI offers Play.

**Playing**
1. `PlaybackPlan` (AMDBKit) picks the player: Apple's on put.io's HLS stream by default; the built-in player on the
   original file (`files/{id}/url`) when it worked for that file before, or when put.io says the file needs converting
   and its codecs (`files/{id}?codecs=1&media_info=1`) are ones Apple's player can't decode. If Apple's player fails
   (an error, a video it can open but not decode, or no start within 20 s when put.io says it needs converting), the
   built-in player takes over at the same position; put.io's MP4 conversion is the last resort after that. Downloaded
   copies play directly.
2. `PlaybackSession` saves progress locally and to put.io (`start_from`), so resume works on every device.
3. `SubtitleFinder` restores the file's subtitle choice and draws it in the chosen style.

## Caching and refresh

| Data | Stored | Refreshed |
|---|---|---|
| put.io library + matches + folder tree | `library.json`, `state.json` | At launch / return if older than the Settings interval (default 1 h); Update Now; iPhone checks every minute while open |
| Latest Movies / Shows | `latest-feed.json` (rows, matches) | Every time the app opens; otherwise at most every 6 h |
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

- iOS deployment target 18 (the built-in player needs it; the Mac app stays on macOS 14); newer features are
  availability-gated: Liquid Glass and Ask Chill (iOS 26).
- Offline downloads use `AVAssetDownloadURLSession` (HLS). A video Apple's player can't play is downloaded as the
  original file instead (`OriginalFileDownloader`, a background `URLSession` that resumes) and plays in the built-in
  player. Paths are stored relative to the app container and resolved at use, because the container moves between
  app updates.
- On Apple TV the stream has no embedded subtitles; the app draws put.io and OpenSubtitles text itself so style and
  timing apply to all of them.
