# AMDB: iPad app design

Date: 2026-10-13 · Status: approved in brainstorm, awaiting spec review

## Goal

A personal, sideloaded iPad app that lets one user find a movie or episode,
send it to their put.io account, wait for the transfer, and watch it. The
experience should feel at least as polished as Netflix. Watch progress
already saved in put.io must carry over.

## Decisions

| Topic | Decision |
|---|---|
| Distribution | Personal sideload from Xcode (or TestFlight later). No App Store constraints. |
| Stack | Native SwiftUI, iPadOS 17+, Swift 6, Observation, SwiftData. No third-party dependencies in v1. |
| Accounts | put.io required (OAuth token flow). TMDB API key required. chill optional. |
| Browsing | TMDB powers all catalog, artwork, and live search. |
| Releases | Merged from chill (if connected) and in-app adapters (YTS, EZTV, apibay, Knaben), deduped by infohash, each row tagged with its sources. |
| Release choice | The Versions sheet always opens; there is no auto-pick. |
| Watch state | put.io `start_from` per file is the source of truth. chill stores no watch state. |
| Visual direction | "Cinematic Ambient": the background glows with the focused title's colors; floating glass tab bar; focused poster scales up; hero shows live put.io state. |
| Transfer wait | On the title page: progress ring, then a 5 s countdown, then auto-play. Elsewhere: tab-bar progress pill and a "ready" banner (local notification when backgrounded, best effort). |
| v1 scope | Movies, TV (episodes and season packs), live search, put.io library, Continue Watching. |

Out of scope for v1: VLCKit fallback, App Store build, iPhone or tvOS layouts,
downloads for offline viewing, multiple put.io accounts, watchlist sync to TMDB.

## Accounts and secrets

- **put.io:** OAuth app "AMDB", client ID `9877`, callback `amdb://oauth/putio`.
  Sign-in opens
  `https://api.put.io/v2/oauth2/authenticate?client_id=9877&response_type=token&redirect_uri=amdb://oauth/putio`
  in `ASWebAuthenticationSession` and reads `access_token` from the callback
  fragment. The client secret is never used or stored.
- **TMDB:** user pastes a v4 read access token in onboarding. It is validated
  with `GET /3/configuration` before saving.
- **chill (optional):** "Connect chill" in Settings. First try
  `ASWebAuthenticationSession` on
  `https://api.chill.institute/auth/putio/start?success_url=amdb://oauth/chill`.
  If the backend rejects that success URL, load the same start URL in a
  `WKWebView` and capture `auth_token` from the fragment of the final
  `chill.institute/auth/success#auth_token=…` navigation. Last resort: paste
  the token from chill.institute's "chilly token" page.
- All tokens and keys live in the Keychain. Nothing secret is logged.
  Signed stream URLs are never persisted.

## Architecture

```
┌──────────────────────────── AMDB (SwiftUI) ────────────────────────────┐
│ UI: Home · Movies · TV · Search · Library · Title · Versions · Player   │
│      │                │                   │                  │          │
│ CatalogClient   ReleaseAggregator    LibraryIndex     TransferMonitor   │
│   (TMDB)          │ SourceProvider×N    │                  │            │
│                   │                     └──── PutioClient ─┘            │
│                   ├ ChillProvider ─────────── api.chill.institute       │
│                   ├ YTSProvider / EZTVProvider / ApibayProvider /       │
│                   │ KnabenProvider ─────────── each site's JSON API     │
│ PlayerController ── PutioClient (HLS, start_from)                       │
│ AmbientTheme (pure, image → palette)                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

### Modules

**`PutioClient`.** A thin, typed wrapper over `https://api.put.io/v2`, with
the `Authorization: Bearer <token>` header.

| Need | Endpoint |
|---|---|
| Account | `GET /account/info` |
| Add transfer | `POST /transfers/add` (`url`, `save_parent_id`) |
| Transfer status | `GET /transfers/{id}`, `GET /transfers/list` |
| Cancel / retry | `POST /transfers/cancel` (`transfer_ids`), `POST /transfers/retry` (`id`) |
| Files | `GET /files/list?parent_id=`, `GET /files/{id}`, `POST /files/create-folder` |
| Stream | `https://api.put.io/v2/files/{id}/hls/media.m3u8?subtitle_key=all&oauth_token=<token>` |
| Original file | `GET /files/{id}/url` (redirect URL), used as a fallback for MP4 files |
| Resume | `GET /files/{id}/start-from`, `POST /files/{id}/start-from/set` (`time`) |
| Subtitles | `GET /files/{id}/subtitles` |

Transfers save into `AMDB/Movies` and `AMDB/TV/<Show>`. The app creates these
folders on first use, under the account's default download folder.

**`CatalogClient`.** Calls TMDB v3: `search/multi`, `trending/{all,movie,tv}/week`,
`movie/popular`, `discover/{movie,tv}?with_genres=`, `movie/{id}` and `tv/{id}`
with `append_to_response=videos,credits,images,external_ids,recommendations`,
`tv/{id}/season/{n}`, and `find/{imdb_id}?external_source=imdb_id`. Images come
from `image.tmdb.org/t/p/{w342,w780,original}`. Responses are cached in memory
per session and use `URLCache` for images.

**`SourceProvider` (protocol).**

```swift
enum MediaQuery { case movie(imdbID: String, title: String, year: Int?)
                  case episode(imdbID: String, title: String, season: Int, episode: Int)
                  case season(imdbID: String, title: String, season: Int)
                  case text(String) }

protocol SourceProvider: Sendable {
    var id: String { get }          // "chill", "yts", …
    func releases(for query: MediaQuery) async throws -> [Release]
}

struct Release: Hashable, Sendable {
    let name: String
    let link: String                // magnet or .torrent URL handed to put.io
    let infoHash: String?           // lowercased btih, nil if unknown
    let sizeBytes: Int64?
    let seeders: Int?
    let sources: Set<SourceTag>     // e.g. chill·TPB, direct·YTS
    let parsed: ParsedRelease       // resolution, codec, hdr, season/episode…
}
```

| Provider | Request | Notes |
|---|---|---|
| `ChillProvider` | `POST https://api.chill.institute/v4/chill.v4.UserService/<Method>` with JSON, `Content-Type: application/json`, `Authorization: Bearer <chill token>` | Movies and text: `GetIndexers` once, then `Search {query, indexerId}` per enabled indexer. Episodes: `GetTVShowEpisodeDownload {imdbId, seasonNumber, episodeNumber}`. Seasons: `GetTVShowSeasonDownloads {imdbId, seasonNumber}`. Uses chill's `releaseInfo` when present. Tag: `chill·<indexer>`. |
| `YTSProvider` | `GET {base}/api/v2/list_movies.json?query_term=<imdbID>` | Movies only. Builds magnets from `hash` plus standard trackers. Default base `https://yts.mx`. |
| `EZTVProvider` | `GET {base}/api/get-torrents?imdb_id=<digits>&limit=100&page=n` | TV only. Filters by season and episode. Default base `https://eztvx.to`. |
| `ApibayProvider` | `GET {base}/q.php?q=<query>&cat=0` | A single `id:"0"` row means no results. Default base `https://apibay.org`. |
| `KnabenProvider` | `POST {base}/v1` JSON `{search_type:"100%", search_field:"title", query, size:50, hide_unsafe:true, hide_xxx:true}` | Default base `https://api.knaben.org`. |

Every base URL can be edited in Settings. Each provider has a 12 s timeout.
The movie query string for text-search providers is `"<title> <year>"`. For
episodes it is `"<title> S01E02"`; for seasons, `"<title> S01"`.

**`ReleaseAggregator`.** Runs the enabled providers in a task group and
publishes results as each provider returns, so rows stream in. It merges rows
by `infoHash`. Without a hash, it uses chill's `id + link`, or else the
normalized name plus size. The merge unions source tags and keeps the maximum
seeders. It records per-provider failures for the UI chips. It sorts by
seeders by default; sort options are seeders, size, and quality. A row is pinned to the top as **Play now** when its `infoHash` matches the
`hash` of a completed put.io transfer. Separately, when `LibraryIndex` already
has a file matched to the same TMDB title (and episode), that file appears as
a **Play now** row even with no hash match. Files in put.io carry no infohash,
so this second check matches by title.

**`ReleaseNameParser`.** A pure function that turns a name into
`ParsedRelease`: title, year, season, episode, episode range, resolution
(2160p/1080p/720p/480p), source (WEB-DL/WEBRip/BluRay/HDTV…), codec
(x264/x265/H.264/HEVC/AV1), HDR flags (HDR/HDR10+/DV), audio (DDP5.1, Atmos…),
group, and flags (proper/repack/extended/complete). Chill's `releaseInfo`
overrides the parser when both exist.

**`LibraryIndex`.** Walks the put.io folder tree on demand: the root, the
AMDB folders, and the account's default download folder. It parses each video
file or folder name, matches it to a TMDB id, and stores the result in SwiftData
as `LibraryMatch {putioFileID, tmdbID, mediaType, season?, episode?, confidence}`.
A transfer started from AMDB records its TMDB id at send time
(`PendingTransfer {transferID, tmdbID, mediaType, season?, episode?}`), so it
always matches exactly. Continue Watching lists matched video files with
`start_from > 0` and not within the last 5 % of their duration, ordered by the
last time they were updated.

**`TransferMonitor`.** Tracks active `PendingTransfer`s.
- In the foreground it polls `GET /transfers/{id}` every 2 s while any are
  active.
- In the background it schedules a `BGAppRefreshTask`, best effort, and posts
  a local notification when a transfer finishes.
- When a transfer completes it resolves `file_id`. If that is a folder, it
  picks the largest video file inside.
- It publishes the state that drives the progress ring, the tab-bar pill, and
  the banner.
- It marks a transfer **stalled** when the status is downloading, peers are 0,
  and there has been no progress for 3 min.

**`PlayerController`.** Wraps `AVPlayerViewController` for native controls,
Picture-in-Picture, AirPlay, and the subtitle and audio menus.
- It plays the HLS URL and seeks to `start_from`.
- If `start_from > 30 s` it offers "Resume from 1:12:40 / Start over".
- It saves the position every 10 s, on pause, and on exit.
- For episodes it shows a "Next episode" overlay in the last 30 s, linking to
  the next episode's play or get state.
- The audio session is `.playback`, so audio keeps playing with the screen
  locked and PiP works.

**`AmbientTheme`.** A pure function: backdrop image → `Palette {primary,
secondary, isDark}`, using a downsampled `CIAreaAverage` plus a two-cluster
pass. The palette is cached per TMDB id. The UI animates the glow behind the
content with a 0.6 s ease.

### Screens

- **Shell.** A floating glass tab bar: Home · Movies · TV · Search · Library.
  It shows a transfer pill while anything is active. Settings is behind the
  avatar.
- **Home.** A hero carousel of trending titles whose button reflects put.io
  state. Rows: Continue Watching, Recently Added to put.io, Trending, Popular
  Movies, Popular TV, and "Because you watched X" (TMDB recommendations of the
  most recently played title).
- **Movies / TV.** Genre rows, Top Rated, and New. "See all" opens a grid.
- **Search (live).**
  - Each keystroke, after a 250 ms debounce, queries TMDB `search/multi` and
    cancels the in-flight task. Results are cached per query string for the
    session.
  - Layout: a "Top suggestions" list (6 items) on the left and an animated
    poster grid on the right. Person results expand to their known-for titles.
  - If there are zero results, it retries once without the last word.
  - The empty state shows recent searches (local) and trending titles.
  - A "Search releases for '…'" row (or Return) runs `.text` across all
    providers and opens the Versions sheet in raw mode.
- **Title page (movie).** Backdrop, logo or thin title, badges, plot, cast,
  trailer (YouTube link), and More like this. The primary button follows
  put.io state: **Get & Watch** / **Play** / **Resume h:mm:ss** /
  **Downloading n%**.
- **Title page (TV).** Season picker and episode list with per-episode state
  and progress, **Get** per episode, and **Get season**.
- **Versions sheet.** Filter chips (All/4K/1080p/720p), sort menu, and rows
  showing quality badge, name, source tags, size, and a color-coded seeders
  count (≥50 green, 10–49 yellow, <10 red). It also shows provider-failure
  chips with Retry, and Play now rows pinned to the top.
- **Waiting.** The title-page hero turns into a progress ring with speed,
  peers, and ETA, then a 5 s "Starting…" countdown (cancelable), then the
  Player. Leaving the page hands off to the tab-bar pill and banner.
- **Library.** Transfers section (active, with cancel and retry), then a poster
  grid of matched put.io items filtered by Movies / TV / Other. Unmatched items
  appear as file cards that are still playable.
- **Settings.** Accounts (put.io, TMDB, chill), Sources (toggle and base URL
  per provider), default quality filter, the auto-play countdown on/off, and
  Sign out.
- **Onboarding.** Connect put.io, then paste the TMDB token, then optionally
  connect chill.

## Error handling

| Situation | Behavior |
|---|---|
| One provider fails | The other providers' rows still show, plus a chip "<Source> unreachable · Retry". |
| Every provider fails or returns nothing | "No versions found." with Retry, Edit sources, and a VPN hint. |
| put.io 401 | A "Reconnect put.io" banner. After re-auth the pending action replays. |
| chill 401 | Chill is dropped from the merge silently, and Settings shows "Reconnect chill". |
| Transfer error or stalled | The ring turns red with put.io's `error_message`, and buttons **Try another version** (reopens the sheet) and **Cancel**. |
| HLS not ready | "put.io is preparing this video…", retrying for up to 60 s with backoff. Then the original URL plays if the file is MP4; otherwise "Open in put.io". |
| Offline | A full-screen offline state. Cached rows and images still render. |
| TMDB token invalid | Onboarding or Settings shows an inline validation error. |

## Testing

- **Unit tests (XCTest):**
  - `ReleaseNameParser` table tests (about 60 real names).
  - Magnet and infohash extraction.
  - Aggregator merge, dedupe, sort, and filter.
  - `LibraryIndex` matching.
  - Search debounce and cancellation (with an injected clock).
  - Stalled detection.
- **Provider tests:** each provider decodes recorded JSON fixtures under
  `Tests/Fixtures/<provider>/`. Network access goes through a `URLProtocol`
  stub, so tests never touch the real network.
- **Client tests:** `PutioClient` and `ChillProvider` request shape (method,
  path, headers, body) and the mapping from errors to `AppError`.
- **Previews:** every screen in its loading, empty, error, downloading, and
  ready states, with fake services.
- **Manual device checklist:**
  1. Onboard.
  2. Live-search a title.
  3. Get a version and see the transfer complete.
  4. Auto-play starts.
  5. Exit midway; put.io web resumes at the same position.
  6. Connect chill; chill-tagged rows appear.
  7. Revoke the put.io token; the reconnect flow works.

## First implementation step: verification spike

Before any UI work, a small command-line test target hits the live services
with real credentials. The credentials come from environment variables and
are never committed. The spike confirms:

1. The put.io OAuth callback to `amdb://oauth/putio` returns `access_token`.
2. HLS playback of an MKV file works in `AVPlayer`.
3. Which file endpoints expose `start_from`. If only the per-file endpoint
   does, Continue Watching fetches it for at most 40 recent video files.
4. Chill Connect-JSON calls succeed. Record whether `success_url=amdb://…`
   is accepted. Record whether `ResolvePlayback` and `GetTransfer` exist
   (informational only).
5. Each provider's default base URL responds from the user's network.

Findings update this spec before the plan continues.
